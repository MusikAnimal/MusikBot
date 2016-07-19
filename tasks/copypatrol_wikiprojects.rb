$LOAD_PATH << '..'
require 'musikbot'
require 'nokogiri'

module CopyPatrolWikiProjects
  def self.run
    @mb = MusikBot::Session.new(inspect)

    last_id = @mb.local_storage('CopyPatrol_lastid', 'r').read.to_i

    un, pw, host, db, port = Auth.copyright_p_credentials
    @client = Mysql2::Client.new(
      host: host,
      username: un,
      password: pw,
      database: db,
      port: port
    )

    records = fetch_records(last_id)
    records.each do |record|
      next if wikiprojects?(record['page_title'])
      wikiprojects = parse_wikiprojects(record['page_title'])
      write_wikiprojects(wikiprojects, record)
    end

    if records.any?
      run_file = @mb.local_storage('CopyPatrol_lastid', 'r+')
      run_file.write(records.last['id'])
      run_file.close
    end
  rescue => e
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
      normalized_wp = wikiproject.sub(/^WikiProject_/, '').tr(' ', '_')
      query('INSERT INTO wikiprojects VALUES(NULL, ?, ?)',
        record['page_title'], normalized_wp
      )
    end
  end

  def self.parse_wikiprojects(page_title)
    talk_text = @mb.get("Talk:#{page_title}",
      rvsection: 0,
      rvparse: true
    )
    Nokogiri::HTML(talk_text).css('.wpb-header a').collect(&:content).select { |text| text =~ /^WikiProject/ }
  end

  def self.query(sql, *values)
    puts sql
    statement = @client.prepare(sql)
    statement.execute(*values)
  end
end

CopyPatrolWikiProjects.run
