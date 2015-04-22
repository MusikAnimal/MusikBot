# TODO: have the bot update User:MusikBot/task_1 with 'true' unless the task doesn't finish, in which case it will write 'false'
#       Then on User:MusikBot in the lists of tasks it will transclude the page into a parser function showing whether or not the task is running and when it failed

module PermClerk
  require 'date'
  require 'pry'
  require 'logger'

  @logger = Logger.new("perm_clerk.log")
  @logger.level = Logger::DEBUG

  EDIT_THROTTLE = 3
  SEARCH_DAYS = 30
  SPLIT_KEY = "====[[User:"
  PERMISSIONS = [
    "Account creator",
    "Autopatrolled",
    # "Confirmed",
    "File mover",
    "Pending changes reviewer",
    # "Reviewer",
    "Rollback"
    "Template editor"
  ]

  @usersCache = {}
  @deniedCache = {}

  def self.init(mw)
    @mw = mw
    @usersCount = 0

    for @permission in PERMISSIONS
      # TODO: check if task is set to run for this permission
      @baseTimestamp = nil
      @editThrottle = 0
      @pageName = "Wikipedia:Requests for permissions/#{@permission}"
      unless process(@permission)
        error("Failed to process")
      else
        info("Processing of #{@permission} complete")
      end
      @logger.info("\n#{'=' * 100}")
      sleep 2
    end
  end

  def self.editPage(newWikitext)
    if @usersCount == 0
      info("No links found for any of the current requests")
      return true
    end

    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1

      info("Writing to page, attempt #{@editThrottle}")

      # attempt to save
      begin
        @mw.edit(@pageName, newWikitext, {
          basetimestamp: @baseTimestamp,
          contentformat: 'text/x-wiki',
          starttimestamp: @startTimestamp,
          summary: "Bot clerking, #{@usersCount} user#{'s' if @usersCount > 1} with previously declined requests",
          text: newWikitext
        })
      rescue MediaWiki::APIError => e
        if e.code.to_s == "editconflict"
          warn("Edit conflict, trying again")
          return process(@permission)
        else
          warn("API error when writing to page: #{e.code.to_s}, trying again")
          return process(@permission)
        end
      rescue => e
        error("Unknown exception when writing to page: #{e.message}") and return false
      end
    else
      error("Throttle hit for edit page operation, continuing to process next permission") and return false
    end

    true
  end

  def self.findLinks(userName)
    if @usersCache[userName]
      info("Cache hit for #{userName}")
      return @usersCache[userName]
    end

    currentDate = Date.today
    targetDate = currentDate - SEARCH_DAYS
    links = []

    for date in (targetDate..currentDate)
      puts date.to_s
      if dayWikitext = getDeniedForDate(date)
        if match = dayWikitext.scan(/{{Usercheck.*\|#{userName}}}.*\/#{@permission}\]\].*(http:\/\/.*)\s+link\]/i)[0]
          # TODO: fetch declining admin's username and ping them
          links << match.flatten[0]
        end
      end
    end

    return @usersCache[userName] = links
  end

  def self.getDeniedForDate(date)
    key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
    if @deniedCache[key]
      info("Cache hit for #{key}")
      page = @deniedCache[key]
    else
      page = @mw.get("Wikipedia:Requests for permissions/Denied/#{key}")
      @deniedCache[key] = page
    end

    # binding.pry
    reduced = page.split(/==\s*\w+\s+/i)
    dayWikitext = reduced.select{|entry| entry.scan(/^(\d+)\s*==/).flatten[0].to_i == date.day.to_i}

    return dayWikitext[0]
  end

  def self.newSectionWikitext(section, links)
    linksMessage = links.map{|l| "[#{l}]"}.join
    comment = "\n:{{comment|Automated comment}} This user has had #{links.length} request#{'s' if links.length > 1} for #{@permission.downcase} declined in the past #{SEARCH_DAYS} days (#{linksMessage}). ~~~~\n"
    return SPLIT_KEY + section.gsub(/\n+$/,"") + comment
  end

  def self.process(permission)
    info("Processing...")
    newWikitext = []
    @fetchThrotte = 0

    oldWikitext = setPageProps
    return false unless oldWikitext

    sections = oldWikitext.split(SPLIT_KEY)

    sections.each do |section|
      debug("Checking section: #{section}")
      links = []
      if userNameMatch = section.match(/{{(?:template\:)?rfplinks\|1=(.*)}}/i)
        userName = userNameMatch.captures[0]

        if section.match(/{{(?:template\:)?(done|not done|already done)}}/i) || section.match(/:{{comment|Automated comment}}.*MusikBot/)
          info("#{userName}'s request already responded to or MusikBot has already commented")
          newWikitext << SPLIT_KEY + section
        else
          info("Searching #{userName}")

          begin
            links += findLinks(userName)
          rescue => e
            links += []
            error("Unknown exception when finding links: #{e.message}") and return false
          end
          if links.length > 0
            info("#{links.length} links found for #{userName}")
            newWikitext << newSectionWikitext(section, links)
            @usersCount += 1
          else
            info("No links found for #{userName}")
            newWikitext << SPLIT_KEY + section
          end
        end
      else
        newWikitext << section
      end
    end

    return editPage(CGI.unescapeHTML(newWikitext.join))
  end

  def self.setPageProps
    if @fetchThrotte < 3
      sleep @fetchThrotte
      @fetchThrotte += 1
      info("Fetching page properties, attempt #{@fetchThrotte}")
      begin
        @startTimestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        pageObj = @mw.custom_query(prop: 'info|revisions', titles: @pageName, rvprop: 'timestamp|content')[0][0]
        @baseTimestamp = pageObj.elements['revisions'][0].attributes['timestamp']
        return pageObj.elements['revisions'][0][0].to_s
      rescue => e
        warn("Unable to fetch page properties, trying again. Error: #{e.message}")
        return setPageProps
      end
    else
      error("Unable to fetch page properties, continuing to process next permission") and return false
    end
  end

  def self.debug(msg); @logger.debug("#{@permission.upcase} : #{msg}"); end
  def self.info(msg); @logger.info("#{@permission.upcase} : #{msg}"); end
  def self.warn(msg); @logger.warn("#{@permission.upcase} : #{msg}"); end
  def self.error(msg); @logger.error("#{@permission.upcase} : #{msg}"); end
end