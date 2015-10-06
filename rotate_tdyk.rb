$LOAD_PATH << '.'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

module RotateTDYK
  def self.run
    @mw = MediaWiki::Gateway.new('https://en.wikipedia.org/w/api.php', bot: true)
    Auth.login(@mw)

    env = eval(File.open('env').read)

    exit 1 unless @mw.get('User:MusikBot/RotateTDYK/Run') == 'true' || env == :test

    @num_days = @mw.get('User:MusikBot/RotateTDYK/Offset').to_i

    set_page_props
    process_page
  rescue => e
    report_error(e.message)
  end

  def self.process_page
    new_content = @old_content
    page_parts = new_content.split(/\=\=\s*Current\s+nominations\s*\=\=/i)
    current_nominations = page_parts[1]

    date_headings = current_nominations.scan(/\=\=\=\s*Articles\s+created\/expanded\s+on\s+(\w+\s+\d+)\s*\=\=\=/i).flatten
    oldest_day = Date.parse("#{date_headings.first} #{today.year}")
    newest_day = Date.parse("#{date_headings.last} #{today.year}")

    unless oldest_day == today - 7
      current_nom_heading = "==Current nominations==\n"
      new_oldest_day_heading = current_nominations.scan(/\=\=\=\s*Articles\s+created\/expanded\s+on\s+#{date_headings[1]}\s*\=\=\=/i).flatten[0]
      new_content.gsub(new_oldest_day_heading, current_nom_heading + new_oldest_day_heading)
    end

    unless newest_day == today
      holding_area = current_nominations.scan(/\n==\s*Special occasion holding area\s*==/).flatten[0]
      todays_heading = "\n===Articles created/expanded on #{today.strftime('%B %-d')}===\n" \
        '&lt;!-- After you have created your nomination page, please add it (e.g., {{Did you know nominations/YOUR ARTICLE TITLE}}) ' \
        "to the TOP of this section (after this comment).--&gt;\n"
      new_content.gsub(holding_area, todays_heading + holding_area)
    end

    edit_page(new_content)
  end

  def self.edit_page(content, throttle = 0)
    return false if throttle > 5

    begin
      sleep throttle * 5
      @mw.edit(page, CGI.unescapeHTML(content),
        base_timestamp: @base_timestamp,
        contentformat: 'text/x-wiki',
        starttimestamp: @start_timestamp,
        summary: "Rotating date headings for #{Date.today.month} #{Date.today.day}",
        text: content
      )
    rescue MediaWiki::APIError => e
      if e.code.to_s == 'editconflict'
        return process_page
      else
        return edit_page(content, throttle + 1)
      end
    end

    true
  end

  def self.set_page_props(throttle = 0)
    return false if throttle > 5
    sleep throttle * 5

    page_obj = @mw.custom_query(
      prop: 'info|revisions',
      rvprop: 'timestamp|content',
      titles: 'Template talk:Did you know'
    ).elements['pages'][0]

    @base_timestamp = page_obj.elements['revisions'][0].attributes['timestamp']
    @old_content = page_obj.elements['revisions'][0][0].to_s
  rescue MediaWiki::APIError
    set_page_props(throttle + 1)
  end

  def self.report_error(message, throttle = 0)
    return if throttle > 5
    sleep throttle * 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: 'Reporting RotateTDYK errors',
      text: message + ' ~~~~~'
    }

    @mw.edit('User:MusikBot/RotateTDYK/Error log', message, opts)
  rescue MediaWiki::APIError
    report_error(message, throttle + 1)
  end

  # utilities
  def self.today
    DateTime.now.new_offset(0).to_date
  end
end

RotateTDYK.run
