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

    total_proposals = 0
    all_editors = []

    categories.each do |category|
      editors = get_editors(category)
      total_proposals += proposals = num_proposals(category)
      all_editors += editors

      @mb.edit("#{category}/Proposals",
        content: proposals,
        summary: "Updating proposal count"
      )
      @mb.edit("#{category}/Editors",
        content: editors.length,
        summary: "Updating editor count"
      )
    end

    @mb.edit("#{@survey_root}/Total proposals",
      content: total_proposals,
      summary: "Updating total proposal count"
    )
    @mb.edit("#{@survey_root}/Total editors",
      content: all_editors.uniq.length,
      summary: "Updating total editor count"
    )
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
      srredirects: false,
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
