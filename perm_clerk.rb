module PermClerk
  require 'date'
  require 'pry'
  require 'logger'

  @logger = Logger.new("perm_clerk.log")
  @logger.level = Logger::INFO

  EDIT_THROTTLE = 3
  SPLIT_KEY = "====[[User:"
  PERMISSIONS = [
    "Account creator",
    "Autopatrolled",
    "Confirmed",
    "File mover",
    "Pending changes reviewer",
    "Rollback",
    "Template editor"
  ]

  @usersCache = {}
  @deniedCache = {}

  def self.init(mw, config)
    @mw = mw
    @config = config

    for @permission in PERMISSIONS
      # TODO: check if task is set to run for this permission
      @baseTimestamp = nil
      @editThrottle = 0
      @headersRemoved = []
      @pageName = "Wikipedia:Requests for permissions/#{@permission}"
      @usersCount = 0
      unless process(@permission)
        error("Failed to process")
      else
        info("Processing of #{@permission} complete")
      end
      @logger.info("\n#{'=' * 100}")
      sleep 2
    end
    @logger.info("Task complete\n#{'~' * 100}")
  end

  def self.editPage(newWikitext)
    unless @usersCount > 0 || headersRemoved?
      info("No links or extraneous headers found for any of the current requests")
      return true
    end

    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1

      info("Attempting to write to page [[#{@pageName}]]")

      fixes = []
      fixes << "#{@usersCount} user#{'s' if @usersCount > 1} with previously declined requests" if @usersCount > 0
      fixes << "extraneous headers removed" if headersRemoved?

      # attempt to save
      begin
        @mw.edit(@pageName, newWikitext, {
          basetimestamp: @baseTimestamp,
          contentformat: 'text/x-wiki',
          starttimestamp: @startTimestamp,
          summary: "Bot clerking, #{fixes.join(', ')}",
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
      debug("Cache hit for #{userName}")
      return @usersCache[userName]
    end

    currentDate = Date.today
    targetDate = currentDate - @config["fetchdeclined_offset"]
    links = []

    for date in (targetDate..currentDate)
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
      debug("Cache hit for #{key}")
      page = @deniedCache[key]
    else
      page = @mw.get("Wikipedia:Requests for permissions/Denied/#{key}")
      @deniedCache[key] = page
    end

    return nil unless page

    reduced = page.split(/==\s*\w+\s+/i)
    dayWikitext = reduced.select{|entry| entry.scan(/^(\d+)\s*==/).flatten[0].to_i == date.day.to_i}

    return dayWikitext[0]
  end

  def self.headersRemoved?
    @headersRemoved.length > 0
  end

  def self.newSectionWikitext(section, links, userName)
    wikitext = SPLIT_KEY + section.gsub(/\n+$/,"")

    if headersRemoved? && @headersRemoved.include?(userName)
      wikitext = wikitext.gsub(/\n+$/, "\n") + "\n::<small>{{comment|Automated comment}} - An extraneous header was removed from this request. ~~~~</small>\n"
    end
    if links && links.length > 0
      linksMessage = links.map{|l| "[#{l}]"}.join
      wikitext = wikitext.gsub(/\n+$/, "\n") + "\n::{{comment|Automated comment}} This user has had #{links.length} request#{'s' if links.length > 1} for #{@permission.downcase} declined in the past #{@config["fetchdeclined_offset"]} days (#{linksMessage}). ~~~~\n"
    end

    wikitext
  end

  def self.process(permission)
    info("Processing #{permission}...")
    newWikitext = []
    @fetchThrotte = 0

    oldWikitext = setPageProps
    return false unless oldWikitext

    if @config["autoformat"]
      oldWikitext = removeHeaders(oldWikitext)
    end

    if permission == "Confirmed"
      if headersRemoved?
        editPage(CGI.unescapeHTML(oldWikitext))
      end
      return true
    end

    sections = oldWikitext.split(SPLIT_KEY)

    sections.each do |section|
      debug("Checking section: #{section}")
      links = []
      if userNameMatch = section.match(/{{(?:template\:)?rfplinks\|1=(.*)}}/i)
        userName = userNameMatch.captures[0]

        if section.match(/{{(?:template\:)?(done|not\s*done|nd|already\s*done)}}/i) || section.match(/::{{comment|Automated comment}}.*MusikBot/)
          info("#{userName}'s request already responded to or MusikBot has already commented")
          newWikitext << SPLIT_KEY + section
        else
          if @config["fetchdeclined"]
            info("Searching #{userName}")

            begin
              links += findLinks(userName)
            rescue => e
              links += []
              error("Unknown exception when finding links: #{e.message}") and return false
            end
          end

          if links.length > 0 || (headersRemoved? && @headersRemoved.include?(userName))
            info("#{links.length} links found for #{userName} or an extraneous header was removed")
            newWikitext << newSectionWikitext(section, links, userName)
            @usersCount += 1
          else
            info("No links or extraneous headers found for #{userName}")
            newWikitext << SPLIT_KEY + section
          end
        end
      else
        newWikitext << section
      end
    end

    return editPage(CGI.unescapeHTML(newWikitext.join))
  end

  def self.removeHeaders(oldWikitext)
    return false unless oldWikitext

    headersMatch = oldWikitext.scan(/(^\=\=[^\=]*\=\=[^\=]*(\=\=\=\=[^\=]*\=\=\=\=\n\*.*rfplinks\|1=(.*)\}\}\n))/)

    if headersMatch.length > 0
      info("Extraneous headers detected")

      for match in headersMatch
        if match[2]
          oldWikitext.sub!(match[0], match[1])
          @headersRemoved << match[2]
        end
      end
    end

    oldWikitext
  end

  def self.setPageProps
    if @fetchThrotte < 3
      sleep @fetchThrotte
      @fetchThrotte += 1
      info("Fetching page properties of [[#{@pageName}]]")
      begin
        @startTimestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        pageObj = @mw.custom_query(prop: 'info|revisions', titles: @pageName, rvprop: 'timestamp|content')[0][0]
        @baseTimestamp = pageObj.elements['revisions'][0].attributes['timestamp']
        return pageObj.elements['revisions'][0][0].to_s
      rescue => e
        warn("Unable to fetch page properties, reattmpt ##{@fetchThrotte}. Error: #{e.message}")
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