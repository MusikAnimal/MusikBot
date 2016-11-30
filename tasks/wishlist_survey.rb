$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'

# WishlistSurvey task
# boot with:
#   ruby wishlist_survey.rb --edition 3 --project meta.wikimedia --lang en
# --edition 3 instructs to use the 3 set of credentials, in this case for Community_Tech_bot
module WishlistSurvey
  def self.run
    @mb = MusikBot::Session.new(inspect)

    # fetches from User:Community_Tech_bot/WishlistSurvey/config
    @survey_root = @mb.config[:survey_root]

    @category_root = "#{@survey_root}/Categories"

    # get counts from previous run, with defaults if they haven't been set yet
    cached_counts = {
      'total_proposals' => 0,
      'total_editors' => 0
    }.merge(@mb.local_storage['counts'] || {})

    # rotate the proposals every 6 hours
    last_rotation = @mb.local_storage['last_rotation']
    rotation_needed = @mb.parse_date(last_rotation) < @mb.now - (@mb.config[:rotation_rate].to_f / 24)

    total_proposals = 0
    total_votes = 0
    all_editors = []
    all_votes = {}

    categories.each do |category|
      # skip if the page is a redirect
      next if redirect?(category)

      editors = get_editors(category)
      total_proposals += proposals = num_proposals(category)
      all_editors += editors

      category_votes = get_vote_counts(category)                # get votes for this category
      category_votes = category_votes.sort_by {|_k, v| -v}.to_h # sort proposals by number of votes
      all_votes[category] = category_votes                      # store votes in the category's hash
      votes = category_votes.values.inject(:+)                  # total votes for this category
      total_votes += votes

      # get counts for this category from previous run, with defaults if they haven't been set yet
      cached_counts[category] = {
        'proposals' => 0,
        'editors' => 0,
        'votes' => 0
      }.merge(cached_counts[category] || {})

      # only attempt to edit if there's a change in the counts
      if cached_counts[category]['votes'] != votes
        @mb.edit("#{category}/Votes",
          content: votes,
          summary: "Updating vote count"
        )
        cached_counts[category]['votes'] = votes
      end
      if cached_counts[category]['proposals'] != proposals
        @mb.edit("#{category}/Proposals",
          content: proposals,
          summary: "Updating proposal count"
        )
        cached_counts[category]['proposals'] = proposals
      end
      if cached_counts[category]['editors'] != editors.length
        @mb.edit("#{category}/Editors",
          content: editors.length,
          summary: "Updating editor count"
        )
        cached_counts[category]['editors'] = editors.length
      end

      rotate_proposals(category) if rotation_needed
    end

    total_editors = all_editors.uniq.length

    # only attempt to edit if there's a change in the counts
    if cached_counts['total_votes'] != total_votes
      create_vote_report(all_votes)
      @mb.edit("#{@survey_root}/Total votes",
        content: total_votes,
        summary: "Updating total vote count"
      )
      cached_counts['total_votes'] = total_votes
    end
    if cached_counts['total_proposals'] != total_proposals
      @mb.edit("#{@survey_root}/Total proposals",
        content: total_proposals,
        summary: "Updating total proposal count"
      )
      cached_counts['total_proposals'] = total_proposals
    end
    if cached_counts['total_editors'] != total_editors
      @mb.edit("#{@survey_root}/Total editors",
        content: total_editors,
        summary: "Updating total editor count"
      )
      cached_counts['total_editors'] = total_editors
    end

    @mb.local_storage(
      'counts' => cached_counts,
      'last_rotation' => rotation_needed ? @mb.now.to_s : last_rotation.to_s
    )
  end

  def self.redirect?(category)
    !@mb.gateway.custom_query(
      action: 'query',
      titles: category,
      prop: 'info',
      formatversion: 2
    ).elements['pages'].first.attributes['redirect'].nil?
  end

  # get direct child subpages of @category_root (and not the /Count pages, etc.)
  def self.categories
    # Opensearch evidently is severely lagged, so using plain ole list=search instead
    # The caveat is it returns all sorts of unrelated crap, but we should be OK
    #   with fetching 50 results and filtering accordingly
    @categories ||= @mb.gateway.custom_query(
      list: 'search',
      srlimit: 50,
      srprop: 'title',
      srsearch: @category_root + '/'
    ).elements['search']
      .collect do |result|
        # matches @category_root plus the first subpage following it, or nil if there's no match
        result.attributes['title'].scan(/^(#{@category_root}\/.*?)(?:\/|$)/).flatten[0]
      end
      .compact # remove nils
      .uniq
  end

  # get usernames of editors to given category page
  def self.get_editors(category)
    sql = 'SELECT DISTINCT(rev_user_text) AS editor ' \
        "FROM metawiki_p.revision WHERE rev_page = #{page_id(category)}"
    @mb.repl.query(sql).to_a.collect { |row| row['editor'] }
  end

  # get number of proposals to given category page
  def self.num_proposals(category)
    # considers any level 2 heading as a proposal
    get_page(category).scan(/\n==[^=]/).size
  end

  # rotate proposals by moving the top section to the bottom of the page
  def self.rotate_proposals(category, throttle = 0)
    content = get_page(category)
    proposals = content.split(/\n==[^=]/)

    intro = proposals.delete_at(0)
    first_proposal = proposals.delete_at(0)

    # move first proposal to the end
    proposals << first_proposal

    # rebuild the list, stripping out whitespace and extraneous new lines
    new_content = intro.strip.chomp('') + "\n\n" + proposals.map { |p| '== ' + p.strip.chomp('') }.join("\n\n")

    @mb.edit(category,
      content: new_content,
      summary: "Rotating proposals to ensure fair visibility (happens every #{@mb.config[:rotation_rate]} hours)",
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      rotate_proposals(category, throttle + 1)
    else
      raise
    end
  end

  def self.get_vote_counts(category)
    content = get_page(category)
    proposals = content.split(/\n==[^=]/)

    proposals.delete_at(0) # remove intro

    votes = {}

    proposals.each do |proposal|
      count = proposal.downcase.scan(/\{\{(#{@mb.config[:support_templates]})\}\}/).flatten.length
      title = proposal.scan(/^(.*?)==\n/).flatten.first.strip
      votes[title] = count
    end

    votes
  end

  def self.create_vote_report(categories)
    content = "{| class='wikitable sortable'\n!Proposal\n!Category\n!Support votes\n"

    # build array of proposal/category/votes for the report
    rows = []
    categories.each do |category, proposals|
      proposals.each do |proposal, count|
        rows << [proposal, category, count]
      end
    end

    # sort all rows by count, descending
    rows = rows.sort_by { |_cat, _prop, count| -count }

    # build markup
    rows.each do |proposal, category, votes|
      # strip out links and nowiki tags from section title
      proposal = proposal.gsub(/\<nowiki\>|\<\/nowiki\>|\[|\]/, '')
      # change spaces to underscores, then URI encode for link
      proposal_target = URI.encode(proposal.score)

      content += %Q{
        |-
        | [[#{category}##{proposal_target}|<nowiki>#{proposal}</nowiki>]]
        | [[#{category}|#{category.split('/').last}]]
        | #{votes}
      }
    end

    content += "|}"

    @mb.edit("User:Community Tech bot/WishlistSurvey/Votes",
      content: content,
      summary: 'Updating voting results'
    )
  end

  # get page ID for given page title, necessary to query revision table
  def self.page_id(title)
    @mb.gateway.custom_query(
      titles: title,
      prop: 'info'
    ).elements['pages'].first.attributes['pageid']
  end

  # Get contents of a page and cache it for this run
  # This is called when looping through the proposal pages
  def self.get_page(page)
    @page_cache ||= {}

    # get_page_props will set @start_timestamp and @base_timestamp
    #   so edit conflicts can be handled when editing
    @page_cache[page] ||= @mb.get_page_props(page)
  end
end

WishlistSurvey.run
