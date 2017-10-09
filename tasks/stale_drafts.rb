$LOAD_PATH << '..'
require 'musikbot'

module StaleDrafts
  def self.run
    @mb = MusikBot::Session.new(inspect)

    process_nonredirects
    # process_redirects
  end

  def self.process_nonredirects
    pages = fetch_drafts

    inner_content = ''
    afc_count = 0
    non_afc_count = 0

    pages.each_with_index do |page, index|
      begin
        title = page['page_title'].descore
        date = Date.parse(page['rev_timestamp']).strftime('%Y-%m-%d')
        api_data = get_api_data(page['page_title'])

        puts "#{index} of #{pages.length}: #{title}" if @env == :test

        is_afc = api_data['categories'].to_a.select { |c| c.attributes['title'] && c.attributes['title'].include?('AfC submissions') }.any?

        if is_afc
          afc_count += 1
          templated = 'Yes'
        else
          non_afc_count += 1
          templated = api_data['categories'].to_a.map { |c| c.attributes['title'] }.include?('Category:Draft articles') ? 'Yes' : 'No'
        end

        links = api_data['linkshere'].elements.to_a.reject { |lh| lh.attributes['pageid'] == '48418678' }.length rescue 0
        revisions = api_data['revisions'].to_a.length
        revisions = revisions >= 50 ? '50+' : revisions
        hist_link = "{{ plainlink | url={{fullurl:Draft:#{page['page_title']}|action=history}} | name=#{revisions} }}"

        inner_content += "| [[:Draft:#{title}]] \n| #{page['page_len']}\n| #{hist_link}\n| #{date}\n" \
          "| [[Special:Whatlinkshere/Draft:#{page['page_title']}|#{links}]]\n| #{templated}\n| #{is_afc ? 'Yes' : 'No'}\n" \
          "| [[:#{title}]]\n|-\n"
      rescue => e
        puts "Error checking page #{page}: #{e.message}"
      end
    end

    content = "<div style='font-size:24px'>Stale drafts as of #{@mb.today.strftime('%-d %B %Y')}</div>\n" \
      "{{formatnum:#{afc_count + non_afc_count}}} unedited pages ({{formatnum:#{afc_count}}} AfC, {{formatnum:#{non_afc_count}}} " \
      "non-AfC) since #{@mb.wiki_date(end_date)}\n\n" \
      "{| class='wikitable sortable'\n! Page\n! Length\n! Revisions\n! style='min-width:75px' | Last edit\n!" \
      " Links\n! Tagged\n! AfC?\n! Mainspace \n|-\n" + inner_content.chomp("|-\n") + "|}\n"
    @mb.edit('User:MusikBot/StaleDrafts/Report',
      content: content,
      summary: "Reporting #{afc_count + non_afc_count} stale drafts",
      bot: false
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
    ).elements['pages'][0].elements rescue {}
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
      ).elements['pages'][0].elements

      links = api_data['linkshere'].elements.to_a.reject { |lh| lh.attributes['pageid'] == '48447733' }.length rescue 0
      next if links > 0

      date = Date.parse(page['rev_timestamp']).strftime('%Y-%m-%d')
      title = page['page_title'].descore
      hist_link = "{{ plainlink | url={{fullurl:Draft:#{page['page_title']}|action=history}} | name=hist }}"

      puts title if @env == :test

      inner_content += "| [[:Draft:#{title}]] (#{hist_link}) | [[Special:Whatlinkshere/Draft:#{page['page_title']}|#{links}]])\n| #{date}\n|-\n"
    end

    content = "== Redirects ==\n#{pages.length} redirects with 0 backlinks since #{@mb.wiki_date(end_date)}\n\n" \
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

  def self.fetch_drafts(redirects = false)
    query = 'SELECT DISTINCT page_title, page_len, rev_timestamp FROM enwiki_p.page ' \
      "JOIN enwiki_p.revision WHERE page_namespace = 118 AND page_is_redirect = #{redirects ? 1 : 0} " \
      "AND rev_id = page_latest AND rev_timestamp < '#{end_date}';"

    @mb.repl_client.query(query).to_a
  end

  # Utility
  def self.end_date
    @mb.db_date(Date.today << 6)
  end
end

StaleDrafts.run
