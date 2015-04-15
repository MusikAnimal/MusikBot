# TODO: have the bot update User:MusikBot/task_1 with 'true' unless the task doesn't finish, in which case it will write 'false'
#       Then on User:MusikBot in the lists of tasks it will transclude the page into a parser function showing whether or not the task is running and when it failed

module PermClerk
  require 'date'
  require 'pry'

  EDIT_THROTTLE = 3
  PERMISSION = "Rollback"
  SEARCH_DAYS = 30
  SPLIT_KEY = "====[[User:"
  PERMISSIONS = [
    # "Account creator",
    # "Autopatrolled",
    # "Confirmed",
    # "File mover",
    # "Pending changes reviewer",
    # "Reviewer",
    "Rollback"
    # "Template editor"
  ]

  def self.init(mw)
    @mw = mw
    @editThrottle = 0
    @endTimestamp = nil
    @pageName = "Wikipedia:Requests for permissions/#{PERMISSION}"
    @startTimestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    @usersCount = 0

    for permission in PERMISSIONS
      # check if task is set to run for this permission
      process(permission)
    end
  end

  def self.editPage(newWikitext)
    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1
      # attempt to save
      res = @mw.edit(@pageName, newWikitext, {
        # assert: 'bot',
        basetimestamp: @baseTimestamp,
        # bot: true,
        contentformat: 'text/x-wiki',
        section: 1,
        starttimestamp: @startTimestamp,
        summary: "Bot clerking, #{@usersCount} user#{'s' if @usersCount > 1} with previously declined requests",
        text: newWikitext
      })
      binding.pry

      # check for edit conflict
      if editConflict
        editPage(newWikitext)
      end
    else
      reportError("Throttle hit for edit page operation")
    end
  end

  def self.findLink(userName)
    currentDate = Date.today
    targetDate = currentDate - SEARCH_DAYS
    links = []

    for monthIndex in (targetDate.month..currentDate.month)
      monthName = Date::MONTHNAMES[monthIndex]
      puts monthName
      page = @mw.get("Wikipedia:Requests for permissions/Denied/#{monthName} #{Date.today.year}")
      # FIXME: (1) use match instead of scan (2) make sure the date itself is within range
      matches = page.scan(/{{Usercheck.*#{userName}.*\/#{PERMISSION}\]\].*(http:\/\/.*)\s+link\]/)
      links += matches.flatten if matches
    end

    return links
  end

  def self.newSectionWikitext(section, links)
    linksMessage = links.map{|l| "[#{l}]"}.join
    comment = "\n:{{comment|Automated comment}} This user has had #{links.length} request#{'s' if links.length > 1} for #{PERMISSION.downcase} declined in the past #{SEARCH_DAYS} days (#{linksMessage}). ~~~~\n"
    return SPLIT_KEY + section.gsub(/\n+$/,"") + comment
  end

  def self.process(permission)
    newWikitext = []

    setPageProps

    sections = @oldWikitext.split(SPLIT_KEY)

    binding.pry

    sections.each do |section|
      links = []
      if userNameMatch = section.match(/{{(?:template\:)?rfplinks\|1=(.*)}}/i)
        userName = userNameMatch.captures[0]
        puts section

        if section.match(/{{(?:template\:)?(done|not done|already done)}}/i) || section.match(/:{{comment|Automated comment}}.*MusikBot/)
          puts "#{userName}'s request already responded to or MusikBot has already commented"
          newWikitext << SPLIT_KEY + section
        else
          puts "Searching for #{userName}"

          links += findLink(userName)
          if links.length > 0
            puts "#{links.length} links found for #{userName}"
            newWikitext << newSectionWikitext(section, links)
            @usersCount += 1
          else
            puts "no links found for #{userName}"
            newWikitext << SPLIT_KEY + section
          end
        end
        puts "======"
      else
        newWikitext << section
      end
    end

    @editThrottle = 0
    editPage(CGI.unescapeHTML(newWikitext.join))
  end

  # FIXME: move to core.rb
  def self.reportError(error)
    abort("Fatal error: #{error}")
  end

  def self.setPageProps
    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1
      begin
        pageObj = @mw.custom_query(prop: 'info|revisions', titles: @pageName, rvprop: 'timestamp|content')[0][0]
        @endTimestamp = pageObj.attributes['touched']
        @oldWikitext = pageObj.elements['revisions'][0][0].to_s
      rescue
        setPageProps
      end
    else
      reportError("Unable to fetch page properties")
    end
  end
end