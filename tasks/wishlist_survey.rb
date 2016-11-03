$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'

# WishlistSurvey task
# boot with:
#   ruby wishlist_survey.rb --edition 3 --project meta.wikimedia --lang en --nobot
# --edition 3 instructs to use the 3 set of credentials, in this case for Community_Tech_bot
# --nobot is necessary unless the account has the bot flag
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
    }.merge(@mb.local_storage || {})

    total_proposals = 0
    all_editors = []

    categories.each do |category|
      # skip if the page is a redirect
      next if redirect?(category)

      editors = get_editors(category)
      total_proposals += proposals = num_proposals(category)
      all_editors += editors

      # get counts for this category from previous run, with defaults if they haven't been set yet
      cached_counts[category] = {
        'proposals' => 0,
        'editors' => 0
      }.merge(cached_counts[category] || {})

      # only attempt to edit if there's a change in the counts
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
    end

    total_editors = all_editors.uniq.length

    # only attempt to edit if there's a change in the counts
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

    # cache counts for use on the next run
    @mb.local_storage(cached_counts)
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
    @mb.get(category).scan(/\n==[^=]/).size
  end

  # get page ID for given page title, necessary to query revision table
  def self.page_id(title)
    @mb.gateway.custom_query(
      titles: title,
      prop: 'info'
    ).elements['pages'].first.attributes['pageid']
  end
end

WishlistSurvey.run
