$LOAD_PATH << '..'
require 'musikbot'

module RotateTDYK
  TEMPLATE_PAGE = 'Template talk:Did you know'.freeze

  def self.run
    @mb = MusikBot::Session.new(inspect)

    # Keep track of the last successful run so we can retry the job
    last_run = @mb.parse_date(
      @mb.local_storage['last_run'] || (@mb.now - 1).to_s
    ).to_date
    if last_run.to_date === @mb.now.to_date
      # Already ran today
      return
    end

    @num_days = @mb.get('User:MusikBot/RotateTDYK/Offset').to_i

    process_page

    @mb.local_storage('last_run' => @mb.now.to_s)
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_page(throttle = 0)
    @old_content = @mb.get_page_props(TEMPLATE_PAGE)
    split = @old_content.split(/\=\=\s*Current\s*nominations(?:\<!-- automatically moved by bot --\>)?\s*\=\=/i)
    older_nominations = split[0]
    @current_nominations = split[1]

    date_headings = @current_nominations.scan(/\=\=\=\s*Articles\s+created\/expanded\s+on\s+(\w+\s+\d+)\s*\=\=\=/i).flatten
    @oldest_day = @mb.parse_date("#{date_headings.first} #{@mb.today.year}")
    @newest_day = @mb.parse_date("#{date_headings.last} #{@mb.today.year}")
    @current_nom_date = @mb.today - @num_days

    moved = move_current_nom_heading
    added = add_new_heading

    if moved || added
      @mb.edit(TEMPLATE_PAGE,
        content: older_nominations.rstrip + "\n" + @current_nominations,
        summary: "Rotating nomination headings for #{@mb.today.strftime('%B %-d')}",
        conflicts: true
      )
    end
  rescue MediaWiki::APIError => e
    if ['editconflict', 'readonly'].include?(e.code.to_s)
      process_page(throttle + 1)
    elsif throttle > 3
      @mb.report_error('Edit throttle hit', e)
    else
      raise e
    end
  end

  def self.move_current_nom_heading
    # T:TDYK doesn't actually state the year anywhere on the page, but we can safely compare just the day/month
    if [@oldest_day.day, @oldest_day.month] == [@current_nom_date.day, @current_nom_date.month]
      return false
    end
    current_nom_heading = "==Current nominations<!-- automatically moved by bot -->==\n"
    new_oldest_day_heading = @current_nominations.scan(/\=\=\=\s*Articles\s+created\/expanded\s+on\s+#{@current_nom_date.strftime('%B %-d')}\s*\=\=\=/i).flatten[0]
    @current_nominations.gsub!(new_oldest_day_heading, current_nom_heading + new_oldest_day_heading)
  end

  def self.add_new_heading
    return false if @newest_day == @mb.today
    holding_area = @current_nominations.scan(/\n==\s*Special occasion holding area\s*==/).flatten[0]
    todays_heading = "\n===Articles created/expanded on #{@mb.today.strftime('%B %-d')}===\n" \
      '<!-- After you have created your nomination page, please add it (e.g., {{Did you know nominations/YOUR ARTICLE TITLE}}) ' \
      "to the TOP of this section (after this comment).-->\n"
    @current_nominations.gsub!(holding_area, todays_heading + holding_area)
  end
end

RotateTDYK.run
