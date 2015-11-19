$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'musikbot'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

module StaleDrafts
  def self.run
    @mb = MusikBot::Session.new(inspect)

    process_nonredirects
    # process_redirects
  end

  def self.process_nonredirects
    pages = fetch_drafts

    content = "<div style='font-size:24px'>Stale non-AFC drafts as of #{Date.today.strftime('%-d %B %Y')}</div>\n" \
      "== Non-redirects ==\n#{pages.length} unedited pages since #{format_date(end_date)}\n\n" \
      "{| class='wikitable sortable'\n! Page\n! Length\n! Revisions\n! style='min-width:75px' | Last edit\n! Links\n! Tagged\n! Mainspace \n|-\n"

    pages.each_with_index do |page, index|
      begin
        title = page['page_title'].gsub(/_/, ' ')
        date = Date.parse(page['rev_timestamp']).strftime('%Y-%m-%d')
        api_data = get_api_data(page['page_title'])

        puts "#{index} of #{pages.length}: #{title}" if @env == :test

        next if api_data['categories'].to_a.select { |c| c.attributes['title'].include?('AfC submissions') }.any?

        links = api_data['linkshere'].elements.to_a.reject { |lh| lh.attributes['pageid'] == '48418678' }.length rescue 0
        templated = api_data['categories'].to_a.map { |c| c.attributes['title'] }.include?('Category:Draft articles') ? 'Yes' : 'No'
        revisions = api_data['revisions'].to_a.length
        revisions = revisions >= 50 ? '50+' : revisions
        hist_link = "{{ plainlink | url={{fullurl:Draft:#{page['page_title']}|action=history}} | name=#{revisions} }}"

        content += "| [[Draft:#{title}]] \n| #{page['page_len']}\n| #{hist_link}\n| #{date}\n" \
          "| [[Special:Whatlinkshere/Draft:#{page['page_title']}|#{links}]]\n| #{templated}\n| [[#{title}]]\n|-\n"
      rescue => e
        puts "Error checking page #{page}: #{e.message}"
      end
    end

    content = content.chomp("|-\n") + "|}\n\n" # "\n{{/Redirects}}"
    @mb.edit('User:MusikBot/StaleDrafts/Report',
      content: content,
      summary: "Reporting #{pages.length} stale non-AfC drafts"
    )
  end

  def self.get_api_data(title)
    @mb.gateway.custom_query(
      titles: 'Draft:' + title,
      prop: 'linkshere|categories|revisions',
      lhprop: 'pageid',
      rvprop: 'ids',
      lhlimit: 50,
      rvlimit: 50
    ).elements['pages'][0].elements rescue nil
  end

  def self.process_redirects
    pages = fetch_drafts(true)
    inner_content = ''

    pages.each do |page|
      api_data = @mb.gateway.custom_query(
        titles: 'Draft:' + page['page_title'],
        prop: 'linkshere',
        lhprop: 'pageid',
        lhlimit: 50
      ).elements['pages'][0].elements rescue nil

      links = api_data['linkshere'].elements.to_a.reject { |lh| lh.attributes['pageid'] == '48447733' }.length rescue 0
      next if links > 0

      date = Date.parse(page['rev_timestamp']).strftime('%Y-%m-%d')
      title = page['page_title'].gsub(/_/, ' ')
      hist_link = "{{ plainlink | url={{fullurl:Draft:#{page['page_title']}|action=history}} | name=hist }}"

      puts title if @env == :test

      inner_content += "| [[Draft:#{title}]] (#{hist_link}) | [[Special:Whatlinkshere/Draft:#{page['page_title']}|#{links}]])\n| #{date}\n|-\n"
    end

    content = "== Redirects ==\n#{pages.length} redirects with 0 backlinks since #{format_date(end_date)}\n\n" \
      "{| class='wikitable sortable'\n! Page\n! Links\n! Last edit\n|-\n" + inner_content
    content = content.chomp("|-\n") + "|}\n\n"

    @mb.edit('User:MusikBot/StaleDrafts/Report/Redirects',
      content: content,
      summary: "Reporting #{pages.length} stale non-AfC drafts"
    )
  end

  # Repl-related
  def self.fetch_drafts(redirects = false)
    query = 'SELECT DISTINCT page_title, page_len, rev_timestamp FROM enwiki_p.page ' \
      "JOIN enwiki_p.revision WHERE page_namespace = 118 AND page_is_redirect = #{redirects ? 1 : 0} " \
      "AND rev_id = page_latest AND rev_timestamp < '#{end_date}';"

    @mb.repl_client.query(query).to_a
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
