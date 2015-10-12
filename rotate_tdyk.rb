$LOAD_PATH << '.'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

module RotateTDYK
  TEMPLATE_PAGE = 'Template talk:Did you know'

  def self.run(throttle = 0)
    sleep throttle * 180
    env = eval(File.open('env').read)

    @mw = MediaWiki::Gateway.new("https://#{env == :production ? 'en' : 'test'}.wikipedia.org/w/api.php", bot: true)
    Auth.login(@mw)

    exit 1 unless @mw.get('User:MusikBot/RotateTDYK/Run') == 'true' || env == :test

    @num_days = @mw.get('User:MusikBot/RotateTDYK/Offset').to_i rescue 7

    process_page
  rescue => e
    if env == :production
      report_error(e.message)
      if throttle < 5
        run(throttle + 1)
      else
        report_error('FAILURE: 5 attempts made at processing page, aborting')
      end
    else
      raise e
    end
  end

  def self.process_page
    set_page_props
    split = @old_content.split(/\=\=\s*Current\s*nominations(?:&lt;!-- automatically moved by bot --&gt;)?\s*\=\=/i)
    older_nominations = split[0]
    @current_nominations = split[1]

    date_headings = @current_nominations.scan(/\=\=\=\s*Articles\s+created\/expanded\s+on\s+(\w+\s+\d+)\s*\=\=\=/i).flatten
    @oldest_day = Date.parse("#{date_headings.first} #{today.year}")
    @newest_day = Date.parse("#{date_headings.last} #{today.year}")
    @current_nom_date = today - @num_days

    moved = move_current_nom_heading
    added = add_new_heading

    edit_page(older_nominations + @current_nominations) if moved || added
  end

  def self.move_current_nom_heading
    return false if @oldest_day == @current_nom_date
    current_nom_heading = "==Current nominations<!-- automatically moved by bot -->==\n"
    new_oldest_day_heading = @current_nominations.scan(/\=\=\=\s*Articles\s+created\/expanded\s+on\s+#{@current_nom_date.strftime('%B %-d')}\s*\=\=\=/i).flatten[0]
    @current_nominations.gsub!(new_oldest_day_heading, current_nom_heading + new_oldest_day_heading)
  end

  def self.add_new_heading
    return false if @newest_day == today
    holding_area = @current_nominations.scan(/\n==\s*Special occasion holding area\s*==/).flatten[0]
    todays_heading = "\n===Articles created/expanded on #{today.strftime('%B %-d')}===\n" \
      '&lt;!-- After you have created your nomination page, please add it (e.g., {{Did you know nominations/YOUR ARTICLE TITLE}}) ' \
      "to the TOP of this section (after this comment).--&gt;\n"
    @current_nominations.gsub!(holding_area, todays_heading + holding_area)
  end

  def self.edit_page(content, throttle = 0)
    return false if throttle > 5

    begin
      sleep throttle * 5
      @mw.edit(TEMPLATE_PAGE, CGI.unescapeHTML(content),
        basetimestamp: @base_timestamp,
        contentformat: 'text/x-wiki',
        starttimestamp: @start_timestamp,
        summary: "Rotating nomination headings for #{today.strftime('%B %-d')}",
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
      titles: TEMPLATE_PAGE
    ).elements['pages'][0]

    @start_timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
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
      summary: 'Reporting RotateTDYK errors'
    }

    content = @mw.get('User:MusikBot/RotateTDYK/Error log') + "\n\n#{message} &mdash; ~~~~~\n\n"

    @mw.edit('User:MusikBot/RotateTDYK/Error log', content, opts)
  rescue MediaWiki::APIError
    report_error(message, throttle + 1)
  end

  # utilities
  def self.today
    DateTime.now.new_offset(0).to_date
  end
end

RotateTDYK.run
