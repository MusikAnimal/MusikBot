$LOAD_PATH << '.'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

module TAFIWeekly
  def self.run(throttle = 0)
    sleep throttle * 180
    @env = eval(File.open('env').read)

    @mw = MediaWiki::Gateway.new("https://#{@env == :production ? 'en' : 'test'}.wikipedia.org/w/api.php", bot: true)
    Auth.login(@mw)

    exit 1 unless api_get('User:MusikBot/TAFIWeekly/Run') == 'true' || @env == :test

    scheduled_article = add_new_scheduled_selection
    remove_entry_from_afi(scheduled_article)
    create_schedule_page(scheduled_article)
    new_article = add_tafi_to_article
    # message_project_members(new_article)
    old_article = remove_old_tafi
    add_former_tafi(old_article)
  rescue => e
    report_error("Fatal error: #{e.message}")
  end

  def self.add_new_scheduled_selection(throttle = 0)
    page = "Wikipedia talk:Today's articles for improvement"
    old_content = get_page_props(page, rvsection: 2)
    new_content = old_content + "\n" + '{{subst:TAFI scheduled selection}}'

    edit_page(page,
      summary: 'Posting new scheduled week selection',
      content: new_content,
      section: 2,
      conflicts: true
    )

    return api_get(page).scan(/icon\|\w+}} \[\[(.*?)\]\]\n.*mbdate.*#{today.day} #{today.strftime('%B')}/).flatten.last
  rescue MediaWiki::APIError => e
    raise e if @env == :test
    if throttle > 3
      report_error('Edit throttle hit for add_new_scheduled_selection, aborting') and return false
    else
      add_new_scheduled_selection(throttle + 1)
    end
  end

  def self.remove_entry_from_afi(article)
    page = 'Wikipedia:Articles for improvement'
    old_content = api_get(page, rvsection: 1)
    # FIXME: check for entires with underscores instead of spaces too!
    new_content = old_content.gsub(/#.*?\[\[#{article}\]\]\s*\n/i, '')
    edit_page(page,
      section: 1,
      content: new_content,
      summary: "Removing [[#{article}]] as the new [[Wikipedia:Today's articles for improvement|article for improvement]]"
    )
  end

  def self.create_schedule_page(article)
    week = today.cweek + 3
    page = "Wikipedia:Today's articles for improvement/#{today.year}/#{week}"
    content = "{{subst:Wikipedia:Today's articles for improvement/Schedule/Preload}}"
    edit_page(page, content: content)
    edit_page(page + '/1', content: "[[#{article}]]")
  end

  def self.add_tafi_to_article(throttle = 0)
    article = api_get("Wikipedia:Today's articles for improvement/#{today.year}/#{today.cweek}").scan(/\[\[(.*)\]\]/).flatten[0]
    old_content = get_page_props(article, rvsection: 0)
    return nil unless old_content
    new_content = "{{TAFI}}\n" + old_content

    edit_page(article,
      summary: "Tagging as the current [[Wikipedia:Today's articles for improvement|article for improvement]]",
      content: new_content,
      section: 0,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      record_error('Edit throttle hit for add_tafi_to_article, aborting') and return false
    elsif e.code.to_s == 'editconflict'
      add_tafi_to_article(article, throttle + 1)
    else
      raise e
    end
  end

  def self.remove_old_tafi(throttle = 0)
    last_week = today - 7
    old_tafi_page_name = "Wikipedia:Today's articles for improvement/#{last_week.year}/#{last_week.cweek}/1"
    article = api_get(old_tafi_page_name).scan(/\[\[(.*)\]\]/).flatten[0]

    page_obj = get_page_props(article,
      rvprop: 'timestamp|content|ids',
      rvsection: 0,
      full_response: true
    )
    @last_rev_id = page_obj.elements['revisions'][0].attributes['revid']
    old_content = page_obj.elements['revisions'][0][0].to_s
    new_content = old_content.gsub(/\{\{TAFI\}\}\n*/i, '')

    if old_content.length != new_content.length
      edit_page(article,
        summary: "Removing {{TAFI}}, [[Wikipedia:Today's articles for improvement|article for improvement]] period has concluded",
        content: new_content,
        section: 0,
        conflicts: true
      )
    end

    article
  rescue MediaWiki::APIError => e
    if throttle > 3
      record_error('Edit throttle hit for remove_old_tafi, aborting') and return false
    elsif e.code.to_s == 'editconflict'
      remove_old_tafi(throttle + 1)
    else
      raise e
    end
  end

  def self.add_former_tafi(article)
    start_date = today - 7
    unless old_talk_text = get_revision_at_date("Talk:#{article}", start_date, rvsection: 0)
      report_error("Unable to fetch [[Talk:#{article}]], aborting add_former_tafi") and return false
    end

    old_class = get_article_class(old_talk_text)

    old_id = get_revision_at_date(article, start_date,
      rvprop: 'ids',
      full_response: true
    ).elements['revisions'][0].attributes['revid'] rescue nil

    content = "{{Former TAFI|date=#{start_date.strftime('%e %B %Y')}|page=#{article}|oldid2=#{@last_rev_id}"
    content += "|oldid1=#{old_id}" if old_id

    new_talk_text = get_page_props("Talk:#{article}", rvsection: 0)
    new_class = get_article_class(new_talk_text)
    if old_class != new_class && old_class.present? && new_class.present?
      content += "|oldclass=#{old_class}|newclass=#{new_class}"
    end
    content += '}}'

    edit_page("Talk:#{article}",
      summary: "Adding {{Former TAFI}} as previous [[Wikipedia:Today's articles for improvement|article for improvement]]",
      content: content,
      section: 0,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      record_error('Edit throttle hit for add_former_tafi, aborting') and return false
    elsif e.code.to_s == 'editconflict'
      add_former_tafi(article)
    else
      raise e
    end
  end

  def self.get_article_class(text)
    text.scan(/\|class\s*=\s*(\w+)\s*(?:\||})/).flatten.first rescue nil
  end

  def self.message_project_members
    spamlist = "Wikipedia:Today's articles for improvement/Members/Notifications"
    subject = "This week's [[Wikipedia:Today's articles for improvement|article for improvement]] (week #{today.cweek}, #{today.year})"
    message = '{{subst:TAFI weekly selections notice}}'
    @mw.mass_message(spamlist, subject, message)
  end

  # API-related
  def self.edit_page(page, opts, throttle = 0)
    sleep throttle * 5

    opts.merge(contentformat: 'text/x-wiki')
    if opts.delete(:conflicts)
      opts.merge(
        basetimestamp: @base_timestamp,
        starttimestamp: @start_timestamp
      )
    end

    @mw.edit(page, CGI.unescapeHTML(opts.delete(:content)), opts)
  rescue MediaWiki::APIError => e
    raise e if throttle > 4 || e.code.to_s == 'editconflict' || @env == :test
    edit_page(page, opts, throttle + 1)
  end

  def self.get_page_props(page, opts, throttle = 0)
    sleep throttle * 5
    full_response = opts.delete(:full_response)

    opts = {
      prop: 'info|revisions',
      rvprop: 'timestamp|content',
      titles: page
    }.merge(opts)

    page_obj = @mw.custom_query(opts).elements['pages'][0]
    unless page_obj.elements['revisions']
      report_error("Unable to fetch properties of [[#{page}]] - page does not exist!") and return nil
    end

    @start_timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    @base_timestamp = page_obj.elements['revisions'][0].attributes['timestamp']
    if full_response
      page_obj
    else
      page_obj.elements['revisions'][0][0].to_s
    end
  rescue MediaWiki::APIError => e
    raise e if throttle > 4 || @env == :test
    get_page_props(page, opts, throttle + 1)
  end

  def self.get_revision_at_date(page, date, opts = {}, throttle = 0)
    sleep throttle * 5
    full_response = opts.delete(:full_response)

    opts = {
      prop: 'revisions',
      rvprop: 'content',
      titles: page,
      rvstart: date.strftime('%Y-%m-%dT%H:%M:%SZ'),
      rvlimit: 1
    }.merge(opts)

    page_obj = @mw.custom_query(opts).elements['pages'][0]

    if full_response
      page_obj
    else
      page_obj.elements['revisions'][0][0].to_s
    end
  rescue MediaWiki::APIError
    if throttle > 5
      report_error("API error when fetching #{page}") and return nil
    else
      get_revision_at_date(page, date, full_response, throttle + 1)
    end
  rescue
    return nil
  end

  def self.report_error(message, throttle = 0)
    return if throttle > 5
    sleep throttle * 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: 'Reporting TAFIWeekly errors'
    }

    content = api_get('User:MusikBot/TAFIWeekly/Error log') + "\n\n#{message} &mdash; ~~~~~\n\n"

    @mw.edit('User:MusikBot/TAFIWeekly/Error log', content, opts)
  rescue MediaWiki::APIError
    report_error(message, throttle + 1)
  end

  def self.api_get(page, opts = {}, throttle = 0)
    sleep throttle
    @mw.get(page, opts)
  rescue MediaWiki::APIError
    if throttle > 5
      report_error("API error when fetching #{page}")
    else
      api_get(page, throttle + 1)
    end
  end

  # utilities
  def self.today
    DateTime.now.new_offset(0).to_date
  end
end

TAFIWeekly.run
