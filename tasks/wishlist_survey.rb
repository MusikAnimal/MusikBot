$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'

# WishlistSurvey task
# boot with:
#   ruby wishlist_survey.rb --edition 3 --project meta.wikimedia --lang en --nobot
# --edition 3 instructs to use the 3 set of credentials, in this case for Community_Tech_bot
# --nobot is necessary unless the account has the bot flag
module WishlistSurvey
  SURVEY_ROOT = '2016 Community Wishlist Survey/Sandbox'
  CATEGORY_ROOT = "#{SURVEY_ROOT}/Categories"

  def self.run
    # pass in true to ignore on-wiki run page: User:Community_Tech_bot/WishlistSurvey/Run
    @mb = MusikBot::Session.new(inspect, true)

    total_proposals = 0
    all_editors = []

    categories.each do |category|
      editors = get_editors(category)
      total_proposals += proposals = num_proposals(category)
      all_editors += editors
      @mb.edit("#{CATEGORY_ROOT}/#{category}/Proposals", content: proposals)
      @mb.edit("#{CATEGORY_ROOT}/#{category}/Editors", content: editors.length)
    end

    @mb.edit("#{SURVEY_ROOT}/Total proposals", content: total_proposals)
    @mb.edit("#{SURVEY_ROOT}/Total editors", content: all_editors.uniq.length)
  end

  # get direct child subpages of CATEGORY_ROOT (and not the /Count pages, etc.)
  def self.categories
    api_root = @mb.gateway.wiki_url

    # mediawiki-gateway framework does not support anything outside action=query, so use HTTParty.
    # Opensearch has a weird response, what we want is always the second element in the returned array.
    # profile=strict ensures we get results that precisely match CATEGORY_ROOT.
    @categories ||= # cache in instance variable
      HTTParty.get("#{api_root}?action=opensearch&search=#{CATEGORY_ROOT}/&profile=strict&redirects=resolve&limit=100")[1]
        .select { |page| !page.sub(CATEGORY_ROOT + '/', '').include?('/') }
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
