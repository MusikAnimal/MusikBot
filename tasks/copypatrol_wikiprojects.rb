$LOAD_PATH << '..'
require 'musikbot'
require 'nokogiri'

module CopyPatrolWikiProjects
  def self.run
    @mb = MusikBot::Session.new(inspect)

    # this ID represents the id of the last record we processed in copyright_diffs
    last_id = @mb.local_storage('CopyPatrol_lastid', 'r').read.to_i

    un, pw, host, db, port = Auth.copyright_p_credentials
    @client = Mysql2::Client.new(
      host: host,
      username: un,
      password: pw,
      database: db,
      port: port
    )

    # get the all the CopyPatrol records since the last run
    records = fetch_records(last_id)

    # loop through and fetch WikiProjects as needed
    records.each do |record|
      # don't re-fetch WikiProjects - for now, that is
      next if wikiprojects?(record['page_title'])

      wikiprojects = parse_wikiprojects(record['page_title'])

      # save to database
      write_wikiprojects(wikiprojects, record)
    end

    # update the ID of the last run
    if records.any?
      run_file = @mb.local_storage('CopyPatrol_lastid', 'r+')
      run_file.write(records.last['id'])
      run_file.close
    end
  rescue => e
    # gets logged to User:MusikBot/CopyPatrolWikiProjects/Error_log
    @mb.report_error('Fatal error', e)
  end

  def self.fetch_records(last_id)
    query('SELECT id, page_title FROM copyright_diffs WHERE id > ?', last_id).to_a
  end

  def self.wikiprojects?(page_title)
    query('SELECT COUNT(*) AS count FROM wikiprojects WHERE wp_page_title = ?', page_title).to_a.first['count'] > 0
  end

  def self.write_wikiprojects(wikiprojects, record)
    wikiprojects.each do |wikiproject|
      # use underscores instead of spaces, to be consistent
      query('INSERT INTO wikiprojects VALUES(NULL, ?, ?)',
        record['page_title'], wikiproject.tr(' ', '_')
      )
    end
  end

  def self.parse_wikiprojects(page_title)
    # mw:API:Revisions
    talk_text = @mb.get("Talk:#{page_title}",
      rvsection: 0,
      rvparse: true
    )

    # Uses XML query selectors to identify the WikiProject links, removing any sub-wikiprojects
    wp_links = Nokogiri::HTML(talk_text).css('.wpb-header a, .mbox-text b a')
      .collect { |a| a.attributes['href'].value.sub('/wiki/', '') }.uniq
      .select { |link| !link.include?('/') }

    Nokogiri::HTML(talk_text).css('.wpb-header a').collect(&:content).select { |text| text =~ /^WikiProject/ }
  end

  def self.query(sql, *values)
    puts sql
    statement = @client.prepare(sql)
    statement.execute(*values)
  end
end

CopyPatrolWikiProjects.run
