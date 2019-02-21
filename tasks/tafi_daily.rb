$LOAD_PATH << '..'
require 'musikbot'

module TAFIDaily
  def self.run
    @mb = MusikBot::Session.new(inspect)

    last_run = @mb.parse_date(
      @mb.local_storage['last_run'] || (@mb.now - 1).to_s
    )
    rotation_expired = @mb.now > last_run + Rational(23, 24) || @mb.env == :test

    process_nomination_board

    if @mb.config[:run][:rotate_nominations] && rotation_expired
      rotate_nominations
      @mb.local_storage('last_run' => @mb.now.to_s)
    end
  rescue => e
    @mb.report_error("Fatal error: #{e.message}")
  end

  def self.rotate_nominations(throttle = 0)
    text = @mb.get_page_props(nominations_board_page_name, rvsection: @mb.config[:config][:nominations_section]).chomp('').chomp('{{/TOC}}')
    genres = []

    sections = text.split(/^==([^=].*?[^=])==\s*\n/)
    intro = sections.delete_at(0).chomp('')

    error_summaries = []

    sections.each_slice(2).each_with_index do |genre, index|
      name = genre[0]
      genre_without_header = genre[1].sub(/<!-- .*? -->\n*/, '')
      nominations = genre[1].split(/^===([^=].*?[^=])===\s*\n/)
      nominations = nominations.drop(1) unless nominations[0] =~ /^===.*?===\s*\n/
      header = '<!-- Place new entries directly below this line, at the top of the list. -->'

      if nominations.empty? && genre_without_header =~ /{{\s*TAFI nom|\d\d:\d\d.*\d{4} \(UTC\)/
        error_summaries << "unable to parse section [[##{name}|#{name}]], content detected but no subheading; possible malformed nomination"
        genres << "==#{name}==\n#{header}\n\n#{genre_without_header}".chomp('')
        next
      end

      new_nominations = []
      nominations.each_slice(2).each { |nn| new_nominations << "===#{nn[0]}===\n#{nn[1].chomp('').gsub(/^\n/, '')}\n\n" }
      header += "\n{{empty section|section=#{index + 2}|date=#{@mb.today.strftime('%B %Y')}}}" if nominations.empty?
      genres << "==#{name}==\n#{header}\n\n#{new_nominations.rotate.join}".chomp('')
    end

    @mb.edit(nominations_board_page_name,
      content: ([intro] + genres.rotate).join("\n\n") + "\n\n\n{{/TOC}}",
      summary: "Rotating nominations; #{error_summaries.join(';')}".chomp('; '),
      conflicts: true,
      section: @mb.config[:config][:nominations_section]
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
    unapproved_entires_count = 0
    archive_entries = []
    text.split("\n===").each do |entry|
      section = "\n===#{entry}"
      article, assessment = entry.scan(/{{\s*TAFI nom\s*\|\s*article\s*=(.*?)\s*(?:\||}})(?:class\s*=\s*(\w+))?/i).flatten

      next unless article

      section.gsub!(/\n==[^=].*/m, '')

      timestamps = section.scan(/(?<!&lt;!-- mbdate --&gt; )\d\d:\d\d.*\d{4} \(UTC\)/)
      newest_timestamp = @mb.parse_date(timestamps.min { |a, b| @mb.parse_date(b) <=> @mb.parse_date(a) })
      next unless newest_timestamp

      should_archive = newest_timestamp + Rational(@mb.config[:config][:archive_offset], 24) < @mb.now

      if newest_timestamp < @mb.today - @mb.config[:config][:auto_unapprove_offset]
        unapproved_entires_count += 1
        text.gsub!(section, '')
        archive_entries << section.chomp('') + "\n{{unapproved}} (automated closure) No further input after 21 days ~~~~"
      elsif entry =~ /{{\s*approved\s*}}/i
        approved_entries << "# {{icon|#{assessment || 'unknown'}}} [[#{article}]]"
        text.gsub!(section, '')
        archive_entries << section if should_archive
      elsif entry =~ /{{\s*(not\s*approved|unapproved)\s*}}/i
        unapproved_entires_count += 1
        text.gsub!(section, '')
        archive_entries << section if should_archive
      end
    end

    return unless archive_entries.any?

    if @mb.config[:run][:update_afi_page] && approved_entries.any?
      add_afti_entries(approved_entries)
    end

    if @mb.config[:run][:archive_nominations]
      approved_count = approved_entries.length
      unapproved_count = unapproved_entires_count
      archive_nominations(archive_entries, approved_count, unapproved_count)

      summaries = []
      summaries << "#{approved_count} approved" if approved_count > 0
      summaries << "#{unapproved_count} unapproved" if unapproved_count > 0

      @mb.edit(nominations_board_page_name,
        content: text,
        summary: "[[#{archive_page_name}|Archiving]] #{archive_entries.length} nominations (#{summaries.join(', ')})"
      )
    end
  end

  def self.add_afti_entries(entries)
    page = 'Wikipedia:Articles for improvement/List'
    text = @mb.get(page)
    text.sub!(/\<!--.*?--\>\n*\z/, '')
    comment = '<!-- This page is automatically updated by MusikBot. There is no need to edit directly -->'
    new_entries = entries.select { |entry| !text.include?(entry.scan(/(\[\[.*?\]\])/).flatten[0].to_s) }
    new_text = "#{text.chomp('')}\n#{new_entries.join("\n")}".chomp('')
    @mb.edit(page,
      content: "#{new_text}\n#{comment}",
      summary: "Adding #{new_entries.length} newly approved article#{'s' if new_entries.length > 1} for improvement"
    )
  end

  def self.archive_nominations(entries, approved, unapproved)
    content = @mb.get(archive_page_name)
    new_month = content.nil?
    @mb.edit(archive_page_name,
      content: "#{content}\n#{entries.join("\n")}",
      summary: "Archiving #{entries.length} nominations (#{approved} approved, #{unapproved} unapproved)"
    )

    # create links on archives index
    if new_month
      index_page = "Wikipedia:Today's articles for improvement/Nominations/Archives"
      index_content = @mb.get(index_page, rvsection: 1)
      year_line = index_content.scan(/\n'''#{@mb.today.year}''':.*?$/).flatten.first || "\n'''#{@mb.today.year}''': "
      index_content.sub!(year_line, '')
      index_content.sub!(/<!-- mb-break.*? -->/,
        "<!-- mb-break (do not remove comment) -->#{year_line}#{' &middot; ' if year_line.include?('[[')}" \
        "[[/#{@mb.today.year}/#{@mb.today.month}|#{@mb.today.strftime('%b')}]]\n"
      )
      @mb.edit(index_page,
        content: index_content,
        section: 1,
        summary: "Adding archiving entry for [[/#{@mb.today.year}/#{@mb.today.month}]]"
      )
    end
  end

  def self.nominations_board_page_name
    @mb.config[:config][:nominations_board_page_name]
  end

  def self.archive_page_name
    "Wikipedia:Today's articles for improvement/Nominations/Archives/#{@mb.today.year}/#{@mb.today.month}"
  end
end

TAFIDaily.run
