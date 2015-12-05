$LOAD_PATH << '.'
require 'musikbot'

module TAFIDaily
  def self.run
    @mb = MusikBot::Session.new(inspect)

    last_run = @mb.parse_date(File.open('TAFIDaily_lastrun', 'r').read) rescue DateTime.new

    process_nomination_board
    rotate_nominations if @mb.config['run']['rotate_nominations'] && @mb.now > last_run + Rational(23, 24)

    run_file = File.open('TAFIDaily_lastrun', 'r+')
    run_file.write(DateTime.now.to_s)
    run_file.close
  rescue => e
    @mb.report_error("Fatal error: #{e.message}")
  end

  def self.rotate_nominations(throttle = 0)
    text = @mb.get_page_props(nominations_board_page_name, rvsection: @mb.config['config']['nominations_section']).chomp('').chomp('{{/TOC}}')
    genres = []

    sections = text.split(/^==([^=].*?[^=])==\s*\n/)
    intro = sections.delete_at(0).chomp('')

    sections.each_slice(2).each do |genre|
      name = genre[0]
      nominations = genre[1].split(/^===([^=].*?[^=])===\s*\n/)
      nominations = nominations.drop(1) unless nominations[0] =~ /^===.*?===\s*\n/
      new_nominations = []
      nominations.each_slice(2).each { |nn| new_nominations << "===#{nn[0]}===\n#{nn[1].chomp('').gsub(/^\n/, '')}\n\n" }
      header = '&lt;!-- Place new entries directly below this line, at the top of the list. --&gt;'
      genres << "==#{name}==\n#{header}\n\n#{new_nominations.rotate.join}".chomp('')
    end

    @mb.edit(nominations_board_page_name,
      content: ([intro] + genres.rotate).join("\n\n") + "\n{{/TOC}}",
      summary: 'Rotating nominations',
      conflicts: true,
      section: @mb.config['config']['nominations_section']
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      rotate_nominations(throttle + 1)
    else
      raise
    end
  end

  def self.process_nomination_board
    text = @mb.get(nominations_board_page_name)
    approved_entries = []
    archive_entries = []
    text.split("\n===").each do |entry|
      section = "\n===#{entry}"
      article, assessment = entry.scan(/{{\s*TAFI nom\s*\|\s*article\s*=(.*?)\s*(?:\||}})(?:class\s*=\s*(\w+))?/i).flatten

      next unless article

      section.gsub!(/\n==[^=].*/m, '')

      timestamps = section.scan(/(?<!&lt;!-- mbdate --&gt; )\d\d:\d\d.*\d{4} \(UTC\)/)
      newest_timestamp = @mb.parse_date(timestamps.min { |a, b| @mb.parse_date(b) <=> @mb.parse_date(a) })
      should_archive = newest_timestamp + Rational(@mb.config['config']['archive_offset'], 24) < @mb.now

      if entry =~ /{{\s*approved\s*}}/i
        approved_entries << "# {{icon|#{assessment || 'unknown'}}} [[#{article}]]"
        text.gsub!(section, '')
        archive_entries << section if should_archive
      end
      if entry =~ /{{\s*(not\s*approved|unapproved)\s*}}/i
        text.gsub!(section, '')
        archive_entries << section if should_archive
      end
    end

    return unless archive_entries.any?

    if @mb.config['run']['update_afi_page'] && approved_entries.present?
      add_afti_entries(approved_entries)
    end

    if @mb.config['run']['archive_nominations']
      archive_nominations(archive_entries)
      @mb.edit(nominations_board_page_name,
        content: text,
        summary: "Archiving #{archive_entries.length} nominations"
      )
    end
  end

  def self.add_afti_entries(entries)
    page = 'Wikipedia:Articles for improvement/List'
    text = @mb.get(page)
    entries.delete_if { |entry| text.include?(entry.scan(/(\[\[.*?\]\])/).flatten[0].to_s) }
    @mb.edit(page,
      content: "#{text}\n#{entries.join("\n")}",
      summary: "Adding #{entries.length} newly approved article#{'s' if entries.length > 1} for improvement"
    )
  end

  def self.archive_nominations(entries)
    page = "Wikipedia:Today's articles for improvement/Nominations/Archives/#{@mb.today.year}/#{@mb.today.month}"
    content = @mb.get(page)
    new_month = content.nil?
    @mb.edit(page,
      content: "#{content}\n#{entries.join("\n")}",
      summary: "Archiving #{entries.length} nominations"
    )

    # create links on archives index
    if new_month
      index_page = "Wikipedia:Today's articles for improvement/Nominations/Archives"
      index_content = @mb.get(index_page, rvsection: 1)
      year_line = index_content.scan(/\n'''#{@mb.today.year}''':.*?$/).flatten.first || "\n'''#{@mb.today.year}''': "
      index_content.sub!(year_line, '')
      index_content.sub!(/<!-- mb-break.*? -->/,
        "<!-- mb-break (do not remove comment) -->#{year_line}#{' &middot; ' if year_line.include?('[[')}" \
        "[[/#{@mb.today.year}/#{@mb.today.month}|#{@mb.today.strftime('%b')}]]"
      )
      @mb.edit(index_page,
        content: index_content,
        section: 1,
        summary: "Adding archiving entry for [[/#{@mb.today.year}/#{@mb.today.month}]]"
      )
    end
  end

  def self.nominations_board_page_name
    @mb.config['config']['nominations_board_page_name']
  end
end

TAFIDaily.run
