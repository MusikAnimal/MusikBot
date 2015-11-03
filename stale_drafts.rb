$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'repl'
require 'httparty'
require 'auth.rb'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

module StaleDrafts
  def self.run
    @mw = MediaWiki::Gateway.new('https://en.wikipedia.org/w/api.php', bot: true)
    Auth.login(@mw)

    @env = eval(File.open('env').read)

    exit 1 unless get_page('User:MusikBot/StaleDrafts/Run') == 'true' || @env == :test

    un, pw, host, db, port = Auth.db_credentials(@env)
    @repl_client = Repl::Session.new(un, pw, host, db, port)
    @getter = HTTParty

    process_nonredirects
    # process_redirects
  end

  def self.process_nonredirects
    pages = fetch_drafts

    content = "<div style='font-size:24px'>Stale non-AFC drafts as of #{Date.today.strftime('%-d %B %Y')}</div>\n" \
      "== Non-redirects ==\n#{pages.length} unedited pages since #{format_date(end_date)}\n\n" \
      "{| class='wikitable sortable'\n! Page\n! Length\n! Revisions\n! style='min-width:75px' | Last edit\n! Links\n! Tagged\n! Mainspace \n|-\n"

    pages.each do |page|
      title = page['page_title'].gsub(/_/, ' ')
      date = Date.parse(page['rev_timestamp']).strftime('%Y-%m-%d')
      api_data = @mw.custom_query(
        titles: 'Draft:' + page['page_title'],
        prop: 'linkshere|categories|revisions',
        lhprop: 'pageid',
        rvprop: 'ids',
        lhlimit: 50,
        rvlimit: 50
      ).elements['pages'][0].elements rescue nil

      puts title if @env == :test

      links = api_data['linkshere'].elements.to_a.reject { |lh| lh.attributes['pageid'] == '48418678' }.length rescue 0
      templated = api_data['categories'].to_a.map { |c| c.attributes['title'] }.include?('Category:Draft articles') ? 'Yes' : 'No'
      revisions = api_data['revisions'].to_a.length
      revisions = revisions >= 50 ? '50+' : revisions
      hist_link = "{{ plainlink | url=//en.wikipedia.org/w/index.php?title=Draft:#{page['page_title']}&action=history | name=#{revisions} }}"

      content += "| [[Draft:#{title}]] \n| #{page['page_len']}\n| #{hist_link}\n| #{date}\n" \
        "| [[Special:Whatlinkshere/Draft:#{page['page_title']}|#{links}]]\n| #{templated}\n| [[#{title}]]\n|-\n"
    end

    content = content.chomp("|-\n") + "|}\n\n" # "\n{{/Redirects}}"
    edit_page('User:MusikBot/StaleDrafts/Report', content, "Reporting #{pages.length} stale non-AfC drafts")
  end

  def self.process_redirects
    pages = fetch_drafts(true)
    inner_content = ''

    pages.each do |page|
      api_data = @mw.custom_query(
        titles: 'Draft:' + page['page_title'],
        prop: 'linkshere',
        lhprop: 'pageid',
        lhlimit: 50
      ).elements['pages'][0].elements rescue nil

      links = api_data['linkshere'].elements.to_a.reject { |lh| lh.attributes['pageid'] == '48447733' }.length rescue 0
      next if links > 0

      date = Date.parse(page['rev_timestamp']).strftime('%Y-%m-%d')
      title = page['page_title'].gsub(/_/, ' ')
      hist_link = "{{ plainlink | url=//en.wikipedia.org/w/index.php?title=Draft:#{page['page_title']}&action=history | name=hist }}"

      puts title if @env == :test

      inner_content += "| [[Draft:#{title}]] (#{hist_link}) | [[Special:Whatlinkshere/Draft:#{page['page_title']}|#{links}]])\n| #{date}\n|-\n"
    end

    content = "== Redirects ==\n#{pages.length} redirects with 0 backlinks since #{format_date(end_date)}\n\n" \
      "{| class='wikitable sortable'\n! Page\n! Links\n! Last edit\n|-\n" + inner_content

    content = content.chomp("|-\n") + "|}\n\n"
    edit_page('User:MusikBot/StaleDrafts/Report/Redirects', content, "Reporting #{pages.length} stale non-AfC drafts")
  end

  # Repl-related
  def self.fetch_drafts(redirects = false)
    query = 'SELECT DISTINCT page_title, page_len, rev_timestamp FROM enwiki_p.page ' \
      'JOIN enwiki_p.categorylinks JOIN enwiki_p.revision ' \
      'WHERE page_namespace = 118 ' \
      "AND page_is_redirect = #{redirects ? '1' : '0'} " \
      "AND rev_id = page_latest AND rev_timestamp < '#{end_date}' " \
      "AND cl_from = page_id AND cl_to NOT RLIKE 'AfC_submissions';"

    @repl_client.query(query).to_a
  end

  # API-related
  def self.get_page(page, throttle = 0)
    sleep throttle * 5
    @mw.get(page)
  rescue MediaWiki::APIError => e
    raise e and return false if throttle > 5
    get_page(page, throttle + 1)
  end

  def self.edit_page(page, content, summary, throttle = 0)
    sleep throttle * 5
    opts = {
      contentformat: 'text/x-wiki',
      summary: summary
    }
    @mw.edit(page, CGI.unescapeHTML(content), opts)
    return true
  rescue MediaWiki::APIError => e
    raise e and return false if throttle > 5
    edit_page(page, content, summary, throttle + 1)
  end

  # Utility
  def self.format_date(date)
    DateTime.parse(date.to_s).strftime('%k:%M, %-d %B %Y (UTC)')
  end

  def self.db_format_date(date)
    Date.parse(date.to_s).strftime('%Y%m%d000000')
  end

  def self.end_date
    db_format_date(Date.today << 6)
  end
end

StaleDrafts.run
