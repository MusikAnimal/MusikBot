module PermClerk
  require 'date'
  require 'pry'
  require 'logger'

  @logger = Logger.new("perm_clerk.log")
  @logger.level = Logger::DEBUG

  @runStatus = eval(File.open("lastrun", "r").read) rescue {}
  @runFile = File.open("lastrun", "r+")

  COMMENT_INDENT = "\n::"
  COMMENT_PREFIX = "{{comment|Automated comment}} "
  EDIT_THROTTLE = 3
  SPLIT_KEY = "====[[User:"

  PERMISSION_KEYS = {
    "Account creator" => "accountcreator",
    "Autopatrolled" => "autopatrolled",
    "Confirmed" => "(?=>auto)?confirmed",
    "File mover" => "filemover",
    "Pending changes reviewer" => "reviewer",
    "Rollback" => "rollbacker",
    "Template editor" => "templateeditor"
  }

  @userLinksCache = {}
  @userInfoCache = {}
  @deniedCache = {}

  def self.init(mw, config)
    @mw = mw
    @config = config

    if config[:env] == :production
      @PREREQ_EXPIRY = 90
    else
      @PREREQ_EXPIRY = 0
    end

    if config[:env] == :production
      @PERMISSIONS = [
        "Account creator",
        "Autopatrolled",
        "Confirmed",
        "File mover",
        "Pending changes reviewer",
        "Rollback",
        "Template editor"
      ]
    else
      @PERMISSIONS = ["Rollback", "Pending changes reviewer"]
    end

    start
  end

  def self.start
    for @permission in @PERMISSIONS
      @baseTimestamp = nil
      @editThrottle = 0
      @editSummaries = []
      @headersRemoved = {}
      @pageName = "Wikipedia:Requests for permissions/#{@permission}"
      @usersCount = 0
      unless process(@permission)
        error("Failed to process")
      else
        info("Processing of #{@permission} complete")
        @runStatus[@permission] = DateTime.now.new_offset(0).to_s
      end
      @logger.info("\n#{'=' * 100}")
      sleep 2
    end
    @logger.info("Task complete\n#{'~' * 100}")

    @runFile.write(@runStatus.inspect)
    @runFile.close
  end

  def self.process(permission)
    info("Processing #{permission}...")

    @fetchThrotte = 0
    oldWikitext = setPageProps
    return false unless oldWikitext

    lastRun = DateTime.parse(@runStatus[permission]).new_offset(0) rescue DateTime.new
    lastEdit = DateTime.parse(@baseTimestamp).new_offset(0)
    hasPrereqData = oldWikitext.match(/&lt;!-- mb-\w*(?:Count|Age) --&gt;/)
    shouldCheckPrereqData = @config["prerequisites"] ? !!hasPrereqData : false

    if lastRun > lastEdit && !shouldCheckPrereqData
      info("  No changes since last run and no prerequisites to update")
      return false
    end

    newWikitext = []

    if @config["autoformat"]
      debug("Checking for extraneous headers")
      oldWikitext = removeHeaders(oldWikitext)
    end

    sections = oldWikitext.split(SPLIT_KEY)
    newWikitext << sections.shift

    sections.each do |section|

      requestChanges = []
      userNameMatch = section.match(/{{(?:template\:)?rfplinks\|1=(.*)}}/i)

      unless userNameMatch
        newWikitext << SPLIT_KEY + section
        next
      end

      userName = userNameMatch.captures[0].gsub("_", " ")

      info("Checking section for User:#{userName}...")

      timestamps = section.scan(/\d\d:\d\d.*\d{4} \(UTC\)/)
      newestTimestamp = timestamps.min {|a,b| DateTime.parse(b).new_offset(0) <=> DateTime.parse(a).new_offset(0)}
      resolution = section.match(/#{@config["regex_done"]}/i) ? "done" : section.match(/#{@config["regex_notdone"]}/i) ? "notdone" : false

      if @config["prerequisites"]
        prereqSigRegex = section.scan(/(&lt;!-- mbsig --&gt;.*&lt;!-- mbdate --&gt; (\d\d:\d\d.*\d{4} \(UTC\)))/)
        prereqSignature = prereqSigRegex.flatten[0]
        prereqTimestamp = prereqSigRegex.flatten[1]
        if prereqUpdateNeeded = DateTime.now.new_offset(0) > DateTime.parse(prereqTimestamp).new_offset(0) + Rational(@PREREQ_EXPIRY, 1440) rescue false
          debug("  Found expired prerequisite data")
        else
          debug("  Prerequisite data under an hour old")
        end
      end

      if resolution
        info("  #{userName}'s request already responded to")
        newWikitext << SPLIT_KEY + section
      elsif section.match(/::{{comment|Automated comment}}.*MusikBot/) && !prereqUpdateNeeded
        info("  MusikBot has already commented on #{userName}'s request and no prerequisite data to update")
        newWikitext << SPLIT_KEY + section
      else
        haveResponded = false

        # AUTORESPOND
        if @config["autorespond"] && !prereqUpdateNeeded
          debug("  Checking if #{userName} already has permission #{@permission}...")

          if userInfo = getUserInfo(userName)
            if userInfo[:userGroups].include?(PERMISSION_KEYS[@permission])
              info("    Found matching user group")
              requestChanges << {
                type: :autorespond,
                permission: @permission.downcase,
                resolution: "{{already done}}"
              }
              haveResponded = true
              @editSummaries << :autorespond
            end
          end
        end

        # AUTOFORMAT
        if @config["autoformat"] && !prereqUpdateNeeded
          debug("  Checking if request is fragmented...")

          fragmentedRegex = /{{rfplinks.*}}\n:(Reason for requesting (?:#{@PERMISSIONS.join("|").downcase}) rights) .*\(UTC\)\n*(.*)/
          fragmentedMatch = section.scan(fragmentedRegex)

          if fragmentedMatch.length > 0
            info("    Found improperly formatted request for #{userName}, repairing")

            actualReason = fragmentedMatch.flatten[1]

            if actualReason.length == 0 && @headersRemoved[userName]
              actualReason = @headersRemoved[userName]
            else
              section.gsub!(actualReason, "")
              loop do
                fragMatch = section.match(fragmentedRegex)
                if fragMatch && fragMatch[2] != "" && !(fragMatch[2].include?("UTC") && !fragMatch[2].include?(userName))
                  reasonPart = fragMatch[2]
                  actualReason += "\n:#{reasonPart}"
                  section.gsub!(reasonPart, "")
                else
                  break
                end
              end
            end

            section.gsub!(fragmentedMatch.flatten[0], actualReason)

            duplicateSig = section.scan(/.*\(UTC\)(.*\(UTC\))/)
            if duplicateSig.length > 0
              info("    Duplicate signature found, repairing")
              sig = duplicateSig.flatten[0]
              section = section.sub(sig, "")
            end

            requestChanges << { type: :autoformat }
            @editSummaries << :autoformat
          elsif @headersRemoved[userName] && @headersRemoved[userName].length > 0
            requestChanges << { type: :autoformat }
            @editSummaries << :autoformat
          end
        end

        if !haveResponded && @permission != "Confirmed"
          # CHECK PREREQUISTES
          if @config["prerequisites"]
            prereqs = @config["prerequisites_config"][@permission.downcase.gsub(/ /,"_")]

            if prereqs && !prereqs.empty?
              if hasPrereqData
                debug("  Checking if prerequisite update is needed...")
              else
                debug("  Checking if #{userName} meets configured prerequisites...")
              end

              sleep 1
              userInfo = getUserInfo(userName)

              prereqs.each do |key, value|
                pass = case key
                  when "accountAge"
                    Date.today - value.to_i >= Date.parse(userInfo[:accountAge])
                  when "articleCount"
                    userInfo[:articleCount].to_i >= value
                  when "editCount"
                    userInfo[:editCount].to_i >= value
                  when "mainspaceCount"
                    !userInfo[:mainspaceCount].nil? && userInfo[:mainspaceCount].to_i >= value
                end

                if prereqUpdateNeeded
                  prereqCountRegex = section.scan(/(&lt;!-- mb-#{key} --&gt;(.*)&lt;!-- mb-#{key}-end --&gt;)/)
                  prereqText = prereqCountRegex.flatten[0]
                  prereqCount = prereqCountRegex.flatten[1].to_i rescue 0

                  if !userInfo[key.to_sym].nil? && userInfo[key.to_sym].to_i > prereqCount && prereqCount > 0
                    section.gsub!(prereqText, "&lt;!-- mb-#{key} --&gt;#{userInfo[key.to_sym].to_i}&lt;!-- mb-#{key}-end --&gt;")
                    section.gsub!(prereqSignature, "~~~~")

                    info("  Prerequisite data updated")
                    requestChanges << { type: :prerequisitesUpdated }
                    @editSummaries << :prerequisitesUpdated
                  end
                elsif !pass
                  info("    Found unmet prerequisites")
                  requestChanges << { type: key }.merge(userInfo)
                  @editSummaries << :prerequisites
                end
              end
            end
          end

          # FETCH DECLINED
          if @config["fetchdeclined"] && !prereqUpdateNeeded
            debug("  Searching for declined #{@permission} requests by #{userName}...")

            begin
              links = findLinks(userName)

              if links.length > 0
                info("    Found previously declined requests")
                linksMessage = links.map{|l| "[#{l}]"}.join

                requestChanges << {
                  type: :fetchdeclined,
                  numDeclined: links.length,
                  declinedLinks: linksMessage
                }
                @editSummaries << :fetchdeclined
              end
            rescue => e
              warn("    Unknown exception when finding links: #{e.message}")
            end
          end
        end

        if requestChanges.length > 0
          info("***** Commentable data found for #{userName} *****")
          @usersCount += 1

          newSection = SPLIT_KEY + section.gsub(/\n+$/,"")

          if requestChanges.index{|obj| obj[:type] == :prerequisitesUpdated}
            newSection += "\n"
          else
            newSection += messageCompiler(requestChanges)
          end
          newWikitext << newSection
        else
          info("  ~~ No commentable data found for #{userName} ~~")
          newWikitext << SPLIT_KEY + section
        end
      end
    end

    return editPage(CGI.unescapeHTML(newWikitext.join))
  end

  def self.editPage(newWikitext)
    unless @usersCount > 0 || headersRemoved?
      info("No commentable data or extraneous headers found for any of the current requests")
      return true
    end

    if @editThrottle < 3
      sleep @editThrottle
      @editThrottle += 1

      info("Attempting to write to page [[#{@pageName}]]")

      plural = @usersCount > 1

      # FIXME: cover all bases here, or write "commented on X requests, repaired malformed requests"
      fixes = []
      fixes << "marked request as already done" if @editSummaries.include?(:autorespond)
      fixes << "repaired malformed request#{'s' if plural}" if @editSummaries.include?(:autoformat)
      fixes << "prerequisite data updated" if @editSummaries.include?(:prerequisitesUpdated)
      fixes << "unmet prerequisites" if @editSummaries.include?(:prerequisites)
      fixes << "found previously declined requests" if @editSummaries.include?(:fetchdeclined)

      # attempt to save
      begin
        @mw.edit(@pageName, newWikitext, {
          basetimestamp: @baseTimestamp,
          contentformat: "text/x-wiki",
          starttimestamp: @startTimestamp,
          summary: "Bot clerking#{" on #{@usersCount} requests" if plural}: #{fixes.join(', ')}",
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
    if @userLinksCache[userName]
      # debug("Cache hit for #{userName}")
      return @userLinksCache[userName]
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

    return @userLinksCache[userName] = links
  end

  def self.getDeniedForDate(date)
    key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
    if @deniedCache[key]
      # debug("Cache hit for #{key}")
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

  def self.getUserInfo(userName)
    begin
      if @config["prerequisites"] && @config["prerequisites_config"].to_s.include?("mainspaceCount")
        return @userInfoCache[userName] if @userInfoCache[userName] && @userInfoCache[userName][:mainspaceCount]
        query = @mw.custom_query(
          list: "users|usercontribs",
          ususers: userName,
          ucuser: userName,
          usprop: "groups|editcount|registration",
          ucprop: "ids",
          uclimit: 200,
          ucnamespace: "0",
          continue: ""
        )
      else
        return @userInfoCache[userName] if @userInfoCache[userName]
        query = @mw.custom_query(
          list: "users",
          ususers: userName,
          usprop: "groups|editcount|registration",
          continue: ""
        )
      end

      user = query[0][0].attributes

      userInfo = {
        editCount: user['editcount'],
        mainspaceCount: query[1] ? query[1].length : nil,
        registration: user['registration'],
        userGroups: query[0][0][0].to_a.collect{|g| g[0]}
      }

      return @userInfoCache[userName] = userInfo
    rescue => e
      error("Unable to fetch user info for #{userName}") and return false
    end
  end

  def self.headersRemoved?
    @headersRemoved.length > 0
  end

  def self.getMessage(type, params = {})
    return case type.to_sym
      when :autoformat
        "An extraneous header or other inappropriate text was removed from this request"
      when :autorespond
        "already has the \"#{params[:permission]}\" user right"
      when :editCount
        "has <!-- mb-editCount -->#{params[:editCount]}<!-- mb-editCount-end --> total edits"
      when :mainspaceCount
        "has <!-- mb-mainspaceCount -->#{params[:mainspaceCount].to_i == 0 ? 0 : params[:mainspaceCount]}<!-- mb-mainspaceCount-end --> edit#{'s' if params[:mainspaceCount].to_i != 1} in the [[WP:MAINSPACE|mainspace]]"
      when :fetchdeclined
        "has had #{params[:numDeclined]} request#{'s' if params[:numDeclined].to_i > 1} for #{@permission.downcase} declined in the past #{@config["fetchdeclined_offset"]} days (#{params[:declinedLinks]})"
    end
  end

  def self.messageCompiler(requestData)
    str = ""

    if index = requestData.index{|obj| obj[:type] == :autoformat}
      requestData.delete_at(index)
      str = "#{COMMENT_INDENT}<small>#{COMMENT_PREFIX}#{getMessage(:autoformat)} ~~~~</small>\n"
      return str if requestData.length == 0
    end

    if index = requestData.index{|obj| obj[:type] == :autorespond}
      str += "\n::#{requestData[index][:resolution]} (automated response): This user "
    else
      str += COMMENT_INDENT + COMMENT_PREFIX + "This user "
    end

    requestData.each_with_index do |data, index|
      type = data.delete(:type)
      str = str.chomp(", ") + " and " if index == requestData.length - 1 && requestData.length > 1
      str += getMessage(type, data) + ", "
    end

    str.chomp(", ") + ". ~~~~\n"
  end

  def self.removeHeaders(oldWikitext)
    return false unless oldWikitext

    headersMatch = oldWikitext.scan(/(^\=\=[^\=]*\=\=([^\=]*)(\=\=\=\=[^\=]*\=\=\=\=\n\*.*rfplinks\|1=(.*)\}\}\n))/)

    if headersMatch.length > 0
      info("Extraneous headers detected")

      for match in headersMatch
        originalMarkup = match[0]
        levelTwoText = match[1].gsub("\n","")
        rfplinksPart = match[2]
        name = match[3]

        if name
          oldWikitext.sub!(originalMarkup, rfplinksPart)
          headerText = originalMarkup.scan(/\=\=\s*([^\=]*)\s*\=\=/)[0][0]
          if levelTwoText.length > headerText.length
            @headersRemoved[name] = levelTwoText.gsub(/^\n*/,"").gsub(/\n$/,"")
          else
            @headersRemoved[name] = headerText
          end
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
