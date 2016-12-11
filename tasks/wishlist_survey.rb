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
      'total_editors' => 0,
      'total_support_votes' => 0,
      'total_votes' => 0
    }.merge(@mb.local_storage['counts'] || {})

    # rotate the proposals every N hours (as specified by rotation_rate in config)
    last_rotation = @mb.local_storage['last_rotation']
    rotation_needed = @mb.parse_date(last_rotation) < @mb.now - (@mb.config[:rotation_rate].to_f / 24)

    total_proposals = 0
    total_votes = 0
    total_support_votes = 0
    all_editors = []
    all_votes = {}

    categories.each do |category|
      editors = get_editors(category)
      total_proposals += proposals = num_proposals(category)
      all_editors += editors

      # get votes for this category
      category_votes = parse_category(category)

      # sort proposals by number of support votes
      category_votes = category_votes.sort_by {|_k, v| -v[:support]}.to_h

      # store votes in the category's hash
      all_votes[category] = category_votes

      # total votes for this category
      support_votes = category_votes.values.map { |v| v[:support] }.inject(:+)
      neutral_votes = category_votes.values.map { |v| v[:neutral] }.inject(:+)
      oppose_votes = category_votes.values.map { |v| v[:oppose] }.inject(:+)
      total_votes += support_votes + neutral_votes + oppose_votes
      total_support_votes += support_votes

      # get counts for this category from previous run, with defaults if they haven't been set yet
      cached_counts[category] = {
        'proposals' => 0,
        'editors' => 0,
        'votes' => 0
      }.merge(cached_counts[category] || {})

      # only attempt to edit if there's a change in the counts
      if cached_counts[category]['votes'] != support_votes
        @mb.edit("#{category}/Votes",
          content: support_votes,
          summary: "Updating support vote count"
        )
        cached_counts[category]['votes'] = support_votes
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
    end
    if cached_counts['total_support_votes'] != total_support_votes
      @mb.edit("#{@survey_root}/Total votes",
        content: total_support_votes,
        summary: "Updating total support vote count"
      )
      cached_counts['total_votes'] = total_support_votes
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

  def self.categories
    @mb.config[:categories].collect { |cat| "#{@category_root}/#{cat}" }
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

  def self.parse_category(category)
    content = get_page(category)
    proposals = content.split(/\n==[^=]/)

    proposals.delete_at(0) # remove intro

    votes = {}

    proposals.each do |proposal|
      proposer = proposal.scan(/\n\*\s*'''Proposer'''\s*:.*?\[\[.*?(?:User(?: talk)?:|Special:Contributions\/)(.*?)(?:\]\]|\|)/i).flatten.first
      voting_section = proposal.scan(/\n===\s*Voting.*?\n(.*)/m).flatten.first
      lines = voting_section.scan(/^#[^:](.*?)\n/).flatten

      supports = proposal.downcase.scan(/\{\{\s*(#{@mb.config[:support_templates]})\s*\}\}/).flatten.length
      neutrals = proposal.downcase.scan(/\{\{\s*(#{@mb.config[:neutral_templates]})\s*\}\}/).flatten.length
      opposes = proposal.downcase.scan(/\{\{\s*(#{@mb.config[:oppose_templates]})\s*\}\}/).flatten.length
      title = proposal.scan(/^(.*?)==\n/).flatten.first.strip

      proposer_sig = /\{\{\s*(#{@mb.config[:support_templates]})\s*\}\}.*?\[\[.*?(?:User(?: talk)?:|Special:Contributions\/)#{proposer}(?:\]\]|\|).*?\b\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/

      # binding.pry if proposal.include?('Global settings')

      statement, discussion = proposal.split(/<h3>\s*Community discussion\s*<\/h3>/)
      phabs = statement.scan(/\[\[:?phab(?:ricator)?:(T\d+)|.*?phabricator\.wikimedia\.org\/(T\d+)/).flatten.compact
      related_phabs = discussion.scan(/\[\[:?phab(?:ricator)?:(T\d+)|.*?phabricator\.wikimedia\.org\/(T\d+)/).flatten.compact - phabs

      if proposer_voted = lines.select { |l| l =~ proposer_sig }.length == 1
        supports -= 1
      end

      votes[title] = {
        support: supports,
        neutral: neutrals,
        oppose: opposes,
        proposer: proposer,
        proposer_voted: proposer_voted,
        phabs: phabs.uniq,
        related_phabs: related_phabs.uniq
      }
    end

    votes
  end

  def self.create_vote_report(categories)
    content = "{| class='wikitable sortable'\n!Rank\n!Proposal\n!Category\n!Proposer\n![[File:Symbol support vote.svg|15px]]\n![[File:Symbol neutral vote.svg|15px]]\n![[File:Symbol oppose vote.svg|15px]]\n!Phabs\n"

    # build array of proposal/category/votes for the report
    rows = []
    categories.each do |category, proposals|
      proposals.each do |proposal, count|
        rows << [proposal, category] + count.values
      end
    end

    # sort all rows by count, descending
    rows = rows.sort_by { |_cat, _prop, count| -count }

    rank = 0

    # build markup
    rows.each do |proposal, category, supports, neutrals, opposes, proposer, proposer_voted, phabs, related_phabs|
      rank += 1

      # strip out links and nowiki tags from section title
      proposal = proposal.gsub(/\<nowiki\>|\<\/nowiki\>|\[|\]/, '')
      # change spaces to underscores, then URI encode for link
      proposal_target = URI.encode(proposal.score)

      proposer_str = proposer ? "[[User:#{proposer}|#{proposer}]]" : 'Unparsable'

      phabs = phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join(', ')

      if related_phabs.any?
        phabs += "<br/><small>Related: #{related_phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join(', ')}</small>"
      end

      content += %Q{
        |-
        | #{rank}
        | [[#{category}##{proposal_target}|<nowiki>#{proposal}</nowiki>]]
        | [[#{category}|#{category.split('/').last}]]
        | #{proposer_str}
        | #{supports}
        | #{neutrals}
        | #{opposes}
        | #{phabs}
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
