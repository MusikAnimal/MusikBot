$LOAD_PATH << '.'
require 'musikbot'

module TAFIDaily
  LIST_PAGE = 'Wikipedia:Articles for improvement/List'

  def self.run
    @mb = MusikBot::Session.new(inspect)

    last_run = @mb.parse_date(File.open('TAFIDaily_lastrun', 'r').read) rescue DateTime.new
    rotation_expired = @mb.env == :test ? true : @mb.now > last_run + Rational(23, 24)

    process_nomination_board
    rotate_nominations if @mb.config['run']['rotate_nominations'] && rotation_expired

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
      header = '<!-- Place new entries directly below this line, at the top of the list. -->'
      genres << "==#{name}==\n#{header}\n\n#{new_nominations.rotate.join}".chomp('')
    end

    @mb.edit(nominations_board_page_name,
      content: ([intro] + genres.rotate).join("\n\n") + "\n\n\n{{/TOC}}",
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
    @board_text = @mb.get(nominations_board_page_name)
    @board_edit_summaries = []
    approved_entries = []
    archive_entries = []
    @board_text.split("\n===").each do |entry|
      @section = "\n===#{entry}"
      article, assessment = entry.scan(/{{\s*TAFI nom\s*\|\s*article\s*=(.*?)\s*(?:\||}})(?:class\s*=\s*(\w+))?/i).flatten

      next unless article

      @section.gsub!(/\n==[^=].*/m, '')
      timestamps = @section.scan(/(?<!&lt;!-- mbdate --&gt; )\d\d:\d\d.*\d{4} \(UTC\)/)
      newest_timestamp = @mb.parse_date(timestamps.min { |a, b| @mb.parse_date(b) <=> @mb.parse_date(a) })
      should_archive = newest_timestamp + Rational(@mb.config['config']['archive_offset'], 24) < @mb.now

      if entry =~ /{{\s*((?:not\s*)?approved|unapproved)\s*}}/i
        if entry =~ /{{\s*approved\s*}}/i
          approved_entries << "# {{icon|#{assessment || 'unknown'}}} [[#{article}]]"
        end
        @board_text.gsub!(@section, '')
        archive_entries << @section if should_archive
        next
      end

      comment_if_duplicate_nomination(article) if @mb.config['run']['comment_on_duplicate_nominations']
    end

    if @mb.config['run']['update_afi_page'] && approved_entries.any?
      add_afti_entries(approved_entries)
    end

    if @mb.config['run']['archive_nominations'] && archive_entries.any?
      archive_nominations(archive_entries)
    end

    if @board_edit_summaries
      @mb.edit(nominations_board_page_name,
        content: @board_text,
        summary: "Bot clerking: #{@board_edit_summaries.join(', ')}"
      )
    end
  end

  def self.add_afti_entries(entries)
    entries.delete_if { |entry| afi_list.include?(entry.scan(/(\[\[.*?\]\])/).flatten[0].to_s) }
    @mb.edit(LIST_PAGE,
      content: "#{afi_list}\n#{entries.join("\n")}",
      summary: "Adding #{entries.length} newly approved article#{'s' if entries.length > 1} for improvement"
    )
  end

  def self.comment_if_duplicate_nomination(article)
    return unless afi_list =~ /\[\[(#{article.gsub('_', ' ')}|#{article.gsub(' ', '_')})\]\]/

    dup_comment = '* {{comment|Automated comment}} This article appears to have already ' \
      "been chosen as an [[#{LIST_PAGE}|article for improvement]]. Please verify. ~~~~"

    matches = @section.scan(/({{\s*TAFI nom.*?}})\n+(?:\*(.*?)\n)?/m).flatten
    break_point = matches[1] || matches[0]
    @board_text.sub!(break_point, "#{break_point}\n#{dup_comment}")
    @board_edit_summaries << "duplicate nomination found ([[#{article}]])"
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

    @board_edit_summaries << "archiving #{entries.length} nominations"
  end

  def self.nominations_board_page_name
    @mb.config['config']['nominations_board_page_name']
  end

  def self.afi_list
    @afi_list ||= @mb.get(LIST_PAGE)
  end
end

TAFIDaily.run
