$LOAD_PATH << '..'
require 'musikbot'
require 'nokogiri'
require 'uri'

module CopyPatrol
  PAGE_ASSESSMENTS_PROJECTS = ['en.wikipedia']

  def self.run
    @mb = MusikBot::Session.new(inspect)
    # credentials option is by default :replica, we have our copypatrol-specific
    #   credentials for the s51306__copyright_p database in application.yml under the :copypatrol hash
    @client = @mb.repl_client(credentials: :copypatrol, log: false)

    # double accepted REXML response size to handle *really* large talk pages
    REXML::Document.entity_expansion_text_limit = 20_480

    # this ID represents the id of the last record we processed in copyright_diffs
    disk_cache = @mb.local_storage
    last_id = disk_cache[@mb.opts[:project]]

    # get the all the CopyPatrol records since the last run
    records = fetch_records(last_id)

    # loop through and fetch WikiProjects as needed
    records.each do |record|
      page_title = record['page_title'].force_encoding('utf-8')
      # don't re-fetch WikiProjects - for now, that is
      next if wikiprojects?(page_title)

      wikiprojects = fetch_wikiprojects(page_title)

      # save to database
      write_wikiprojects(wikiprojects, record) if wikiprojects.any?
    end

    # update the ID of the last run
    disk_cache[@mb.opts[:project]] = records.last['id']
    @mb.local_storage(disk_cache) if records.any?
  rescue => e
    # gets logged to User:MusikBot/CopyPatrol/Error_log
    @mb.report_error('Fatal error', e)
  end

  def self.fetch_records(last_id)
    query("SELECT id, page_title FROM copyright_diffs WHERE lang = '#{@mb.lang}' AND id > ?", last_id).to_a
  end

  # Are there any wikiprojects for this title?
  def self.wikiprojects?(page_title)
    query("SELECT COUNT(*) AS count FROM wikiprojects " \
      "WHERE wp_lang = '#{@mb.lang}' AND wp_page_title = ?", page_title).to_a.first['count'] > 0
  end

  def self.write_wikiprojects(wikiprojects, record)
    wikiprojects.each do |wikiproject|
      # use underscores instead of spaces, to be consistent
      query("INSERT INTO wikiprojects VALUES(NULL, ?, ?, ?)",
        record['page_title'], wikiproject.tr(' ', '_'), @mb.lang.to_s
      )
    end
  end

  def self.fetch_wikiprojects(page_title)
    # Use page assessments API if available for this project
    if PAGE_ASSESSMENTS_PROJECTS.include?(@mb.opts[:project])
      assessments = @mb.gateway.custom_query(
        prop: 'pageassessments',
        titles: page_title
      ).elements['pages'].first.elements['pageassessments'] || []

      return assessments.collect { |pa| pa.attributes['project'] }
    end

    # mw:API:Revisions, and convert to Nokogiri markup
    talk_markup = Nokogiri::HTML(
      # Talk: namespace is always normalized to whatever it is for the given wiki
      @mb.get("Talk:#{page_title}",
        rvsection: 0,
        rvparse: true
      )
    )

    # Parses the talk page of the given article to find WikiProjects.
    # Uses XML query selectors to identify the WikiProject links, removing any sub-wikiprojects
    #   and the Wikipedia: prefix
    case @mb.opts[:project]
      when 'fr.wikipedia'
        talk_markup.css('td b a')
          .collect { |link| URI.decode(link.attributes['href'].value.sub('/wiki/', '')) }
          .select { |link| link =~ /^Projet:/ && !link.include?('/') && !link.include?('#') }
          .map { |link| link.sub(/^Projet:/, '') }
    end
  end

  def self.query(sql, *values)
    statement = @client.prepare(sql)
    statement.execute(*values)
  end
end

CopyPatrol.run
