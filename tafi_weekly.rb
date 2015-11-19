$LOAD_PATH << '.'
require 'musikbot'

module TAFIWeekly
  def self.run
    @mb = MusikBot::Session.new(inspect)

    scheduled_article = add_new_scheduled_selection if config['add_new_scheduled_selection']
    remove_entry_from_afi(scheduled_article) if config['remove_entry_from_afi']
    create_schedule_page(scheduled_article) if config['prepare_scheduled_selection']
    add_tafi_to_article if config['add_tafi_to_article']
    # ~=~=~=~=~=~=~=~ FIXME: IMPORTANT!!! REMOVE HEADER FROM TEMPLATE! ~=~=~=~=~=~=~=~
    message_project_members if config['message_project_members']
    notify_wikiprojects if config['notify_wikiprojects']
    old_article = remove_old_tafi if config['remove_old_tafi']
    add_former_tafi(old_article) if config['add_former_tafi']
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.add_new_scheduled_selection(throttle = 0)
    page = "Wikipedia talk:Today's articles for improvement"
    old_content = @mb.get_page_props(page, rvsection: 2)
    new_content = old_content + "\n" + '{{subst:TAFI scheduled selection}}'

    @mb.edit(page,
      summary: 'Posting new scheduled week selection',
      content: new_content,
      section: 2,
      conflicts: true
    )

    return @mb.get(page).scan(/icon\|\w+}} \[\[(.*?)\]\]\n.*mbdate.*#{@mb.today.day} #{@mb.today.strftime('%B')}/).flatten.last
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      add_new_scheduled_selection(throttle + 1)
    else
      raise e
    end
  end

  def self.remove_entry_from_afi(article)
    unless article
      @mb.report_error(
        'Unable to run task {{mono|remove_entry_from_afi}}, new scheduled article unknown. ' \
        'Please ensure the {{mono|add_new_scheduled_selection}} task is enabled'
      )
    end
    page = 'Wikipedia:Articles for improvement'
    old_content = @mb.get(page, rvsection: 1)
    # FIXME: check for entires with underscores instead of spaces too!
    new_content = old_content.gsub(/#.*?\[\[#{article}\]\]\s*\n/i, '') || old_content.gsub(/#.*?\[\[#{article.gsub(/ /, '_')}\]\]\s*\n/i, '')

    unless new_content
      @mb.report_error("Unable to locate [[#{article}]] within [[#{page}]]")
    end

    @mb.edit(page,
      section: 1,
      content: new_content,
      summary: "Removing [[#{article}]] as the new [[Wikipedia:Today's articles for improvement|article for improvement]]"
    )
  end

  def self.create_schedule_page(article)
    week = @mb.today.cweek + 3
    page = "Wikipedia:Today's articles for improvement/#{@mb.today.year}/#{week}"
    content = "{{subst:Wikipedia:Today's articles for improvement/Schedule/Preload}}"
    @mb.edit(page, content: content)
    @mb.edit(page + '/1', content: "[[#{article}]]")
  end

  def self.add_tafi_to_article(throttle = 0)
    old_content = @mb.get_page_props(new_tafi, rvsection: 0)
    return nil unless old_content
    new_content = "{{TAFI}}\n" + old_content

    @mb.edit(new_tafi,
      summary: "Tagging as the current [[Wikipedia:Today's articles for improvement|article for improvement]]",
      content: new_content,
      section: 0,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      add_tafi_to_article(article, throttle + 1)
    else
      raise e
    end
  end

  def self.new_tafi
    @new_tafi ||= @mb.get("Wikipedia:Today's articles for improvement/#{@mb.today.year}/#{@mb.today.cweek}").scan(/\[\[(.*)\]\]/).flatten[0]
  end

  def self.remove_old_tafi(throttle = 0)
    sleep throttle * 5

    last_week = @mb.today - 7
    old_tafi_page_name = "Wikipedia:Today's articles for improvement/#{last_week.year}/#{last_week.cweek}/1"
    article = @mb.get(old_tafi_page_name).scan(/\[\[(.*)\]\]/).flatten[0]

    page_obj = @mb.get_page_props(article,
      rvprop: 'timestamp|content|ids',
      rvsection: 0,
      full_response: true
    )
    @last_rev_id = page_obj.elements['revisions'][0].attributes['revid']
    old_content = page_obj.elements['revisions'][0][0].to_s
    new_content = old_content.gsub(/\{\{TAFI\}\}\n*/i, '')

    if old_content.length != new_content.length
      @mb.edit(article,
        summary: "Removing {{TAFI}}, [[Wikipedia:Today's articles for improvement|article for improvement]] period has concluded",
        content: new_content,
        section: 0,
        conflicts: true
      )
    end

    article
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      remove_old_tafi(throttle + 1)
    else
      raise e
    end
  end

  def self.add_former_tafi(article, throttle = 0)
    start_date = @mb.today - 7
    unless old_talk_text = @mb.get_revision_at_date("Talk:#{article}", start_date, rvsection: 0)
      @mb.report_error("Unable to fetch [[Talk:#{article}]], aborting add_former_tafi")
    end

    old_class = get_article_class(old_talk_text)

    old_id = @mb.get_revision_at_date(article, start_date,
      rvprop: 'ids',
      full_response: true
    ).elements['revisions'][0].attributes['revid'] rescue nil

    content = "{{Former TAFI|date=#{start_date.strftime('%e %B %Y')}|page=#{article}|oldid2=#{@last_rev_id}"
    content += "|oldid1=#{old_id}" if old_id

    new_talk_text = @mb.get_page_props("Talk:#{article}", rvsection: 0)
    new_class = get_article_class(new_talk_text)
    if old_class != new_class && old_class.present? && new_class.present?
      content += "|oldclass=#{old_class}|newclass=#{new_class}"
    end
    content += '}}'

    @mb.edit("Talk:#{article}",
      summary: "Adding {{Former TAFI}} as previous [[Wikipedia:Today's articles for improvement|article for improvement]]",
      content: content,
      section: 0,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      add_former_tafi(article, throttle + 1)
    else
      raise e
    end
  end

  def self.get_article_class(text)
    text.scan(/\|class\s*=\s*(\w+)\s*(?:\||})/).flatten.first rescue nil
  end

  def self.message_project_members
    spamlist = "Wikipedia:Today's articles for improvement/Members/Notifications"
    subject = "This week's [[Wikipedia:Today's articles for improvement|article for improvement]] (week #{@mb.today.cweek}, #{@mb.today.year})"
    message = '{{subst:TAFI weekly selection notice}}'
    @mw.mass_message(spamlist, subject, message)
  end

  def self.notify_wikiprojects
    talk_text = @mb.get("Talk:#{new_tafi}",
      rvsection: 0,
      rvparse: true
    )
    wikiprojects = talk_text.scan(%r{\"\/wiki\/Wikipedia:(WikiProject_.*?)(?:#|\/|\")}).flatten.uniq
    content = '{{subst:TAFI project notice}}'
    wikiprojects.each do |wikiproject|
      @mb.edit("Wikipedia talk:#{wikiproject}", content, section: 'new')
    end
  end

  # API-related
  def self.config
    @config ||= JSON.parse(CGI.unescapeHTML(@mb.get('User:MusikBot/TAFIWeekly/config.js')))
  end
end

TAFIWeekly.run
