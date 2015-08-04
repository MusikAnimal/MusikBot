module PermClerk
  require 'date'
  require 'logger'

  COMMENT_INDENT = "\n::"
  AWB_COMMENT_INDENT = "\n*:"
  COMMENT_PREFIX = "{{comment|Automated comment}} "
  EDIT_THROTTLE = 3
  SPLIT_KEY = "====[[User:"
  AWB_SPLIT_KEY = "*{{AWBUser|"

  PERMISSION_KEYS = {
    "Account creator" => "accountcreator",
    "Autopatrolled" => "autoreviewer",
    "Confirmed" => "(?=>auto)?confirmed",
    "File mover" => "filemover",
    "Mass message sender" => "massmessage-sender",
    "Pending changes reviewer" => "reviewer",
    "Rollback" => "rollbacker",
    "Template editor" => "templateeditor",
    "AWB" => "awb"
  }

  def self.init(mw, replClient, config)
    @mw = mw
    @replClient = replClient
    @config = config

    @deniedCache = {}
    @userInfoCache = {}
    @userLinksCache = {}

    @logger = Logger.new("perm_clerk.log")
    @logger.level = Logger::DEBUG

    @runStatus = eval(File.open("lastrun", "r").read) rescue {}
    @runFile = File.open("lastrun", "r+")

    @archiveChanges = {}
    @errors = {}

    if @config[:env] == :production
      @PREREQ_EXPIRY = 90
      @PERMISSIONS = [
        "Account creator",
        "Autopatrolled",
        "AWB",
        "Confirmed",
        "File mover",
        "Mass message sender",
        "Pending changes reviewer",
        "Rollback",
        "Template editor"
      ]
    else
      @PREREQ_EXPIRY = 0
      @PERMISSIONS = ["Rollback"]
    end

    start

    @runFile.write(@runStatus.inspect)
    @runFile.close
  end

  def self.start
    totalUserCount = 0
    for @permission in @PERMISSIONS
      sleep 2

      @baseTimestamp = nil
      @permEditThrottle = 0
      @editSummaries = []
      @headersRemoved = {}
      @usersCount = 0
      if process
        info("Processing of #{@permission} complete")
        @runStatus[@permission] = currentTime.to_s
        totalUserCount += @usersCount
      else
        error("Failed to process")
      end
    end

    @permission = ""
    archiveRequests if @archiveChanges.length

    reportErrors

    info("#{'~' * 25} Task complete #{'~' * 25}")
  end

  def self.process
    info("Processing #{@permission}...")

    if @permission == "AWB"
      @pageName = "Wikipedia talk:AutoWikiBrowser/CheckPage"
    else
      @pageName = "Wikipedia:Requests for permissions/#{@permission}"
    end

    @fetchThrotte = 0
    oldWikitext = setPageProps

    return false unless oldWikitext

    @lastEdit = parseDateTime(@baseTimestamp)
    @lastRun = parseDateTime(@runStatus[@permission]) rescue DateTime.new

    prereqs = @config["prerequisites_config"][@permission.downcase.gsub(/ /,"_")]
    if @config["prerequisites"] && prereqs # if prereqs enabled for this permission
      hasPrereqData = oldWikitext.match(/&lt;!-- mb-\w*(?:Count|Age) --&gt;/)
      shouldUpdatePrereqData = @config["prerequisites"] ? !!hasPrereqData : false
    else
      shouldUpdatePrereqData = false
    end

    # only process if there's data to update, the page has changed since the last run or it's been 90 minutes since the last run
    if @config[:env] == :production && !shouldUpdatePrereqData && @lastRun > @lastEdit && @lastRun + Rational(90, 1440) > currentTime
      info("  Less than 90 minutes since last run without changes, and no prerequisites to update")
      return false
    end

    newWikitext = []

    if @config["autoformat"] && @permission != "AWB"
      debug("Checking for extraneous headers")
      oldWikitext = removeHeaders(oldWikitext)
    end

    @splitKey = @permission == "AWB" ? AWB_SPLIT_KEY : SPLIT_KEY
    @numOpenRequests = 0

    return false unless formattingCheck(oldWikitext)

    # first make fixes to confirm to what splitKey looks for
    oldWikitext.gsub!(/\*\s+{{AWBUser\|/, "*{{AWBUser|")
    oldWikitext.gsub(/\=\=\=\=\s+\[\[User:/,"====[[User:")

    sections = oldWikitext.split(@splitKey)
    newWikitext << sections.shift

    sections.each do |section|
      botSection = ""
      if @permission == "AWB"
        botSplit = section.split(/====\s*Bots/i)
        section = botSplit[0]
        botSection = "==== Bots"+botSplit[1] if botSplit[1]
      end

      requestChanges = []

      if @permission == "AWB"
        userName = section.scan(/^(.*)}}/).flatten[0]
      else
        userName = section.scan(/{{(?:template\:)?rfplinks\|1=(.*)}}/i).flatten[0]
      end

      if !userName || userName == "username" || userName == "bot username"
        newWikitext << @splitKey + section + botSection
        next
      end

      info("Checking section for User:#{userName}...")

      userName.gsub!("_", " ")

      # XXX: shouldn't include MusikBot's timestamp now
      timestamps = section.scan(/(?<!&lt;!-- mbdate --&gt; )\d\d:\d\d.*\d{4} \(UTC\)/)
      newestTimestamp = timestamps.min {|a,b| parseDateTime(b) <=> parseDateTime(a)}
      if overridenResolution = section.match(/\{\{User:MusikBot\/override\|d\}\}/i) ? "done" : section.match(/\{\{User:MusikBot\/override\|nd\}\}/i) ? "notdone" : false
        info("  Resolution override found")
      end
      resolution = overridenResolution || (section.match(/#{@config["regex_done"]}/i) ? "done" : section.match(/#{@config["regex_notdone"]}/i) ? "notdone" : false)
      resolutionDate = Date.parse(section.scan(/#{@config["regex_#{resolution}"]}.*?(\d\d:\d\d.*\d{4} \(UTC\))/i).flatten[1]) rescue nil

      # use newest timestamp when forcing resolution and no resolution template exists
      if resolutionDate.nil? && overridenResolution
        resolutionDate = Date.parse(newestTimestamp)
      end

      @numOpenRequests += 1 unless resolution

      if shouldUpdatePrereqData = section.scan(/&lt;!-- mb-/).length > 0
        prereqSigRegex = section.scan(/(&lt;!-- mbsig --&gt;.*&lt;!-- mbdate --&gt; (\d\d:\d\d.*\d{4} \(UTC\)))/)
        prereqSignature = prereqSigRegex.flatten[0]
        prereqTimestamp = prereqSigRegex.flatten[1]
        if shouldUpdatePrereqData = currentTime > parseDateTime(prereqTimestamp) + Rational(@PREREQ_EXPIRY, 1440) rescue false
          debug("  Found expired prerequisite data")
        else
          debug("  Prerequisite data under #{@PREREQ_EXPIRY} minutes old")
        end
      end

      shouldArchiveNow = section.match(/\{\{User:MusikBot\/archivenow\}\}/)

      # <ARCHIVING>
      if resolution && @config["archive"] && resolutionDate.nil?
        recordError({
          group: "archive",
          message: "User:#{userName} - Resolution template not dated",
          logMessage: "    User:#{userName}: Resolution template not dated"
        }) and next
      elsif resolution && @config["archive"] && (shouldArchiveNow || parseDateTime(newestTimestamp) + Rational(@config["archive_offset"], 24) < currentTime)
        if shouldArchiveNow
          info("  Found request for immediate archiving")
        else
          info("  Time to archive!")
        end

        # if we're archiving as done, check if they have the said permission and act accordingly (skip if overriding resolution)
        if resolution == "done" && !overridenResolution
          userInfo = getUserInfo(userName)

          # make sure they have the permission
          # TODO: actually check the checkpage to see if they've been added
          if @permission != "AWB"
            hasPermission = userInfo[:userGroups].grep(/#{PERMISSION_KEYS[@permission]}/).length > 0
          end

          if section.include?("&gt;&lt;!-- mbNoPerm --&gt;")
            warn("    MusikBot already reported that #{userName} does not have the permission #{@permission}")
            newWikitext << @splitKey + section
            next
          elsif !hasPermission && @permission != "AWB"
            requestChanges << {
              type: :noSaidPermission,
              permission: @permission.downcase
            }
            @editSummaries << :noSaidPermission

            newWikitext = queueChanges(requestChanges, section, botSection, newWikitext)

            recordError({
              group: "archive",
              message: "User:#{userName} does not have the permission #{@permission}. " +
                "Use <code><nowiki>{{subst:User:MusikBot/override|d}}</nowiki></code> to archive as approved or " +
                "<code><nowiki>{{subst:User:MusikBot/override|nd}}</nowiki></code> to archive as declined",
              logMessage: "    #{userName} does not have the permission #{@permission}"
            }) and next
          end
        end

        resolutionPageName = resolution == "done" ? "Approved" : "Denied"
        info("    archiving as #{resolutionPageName.upcase}")
        archiveKey = "#{resolutionPageName}/#{Date::MONTHNAMES[resolutionDate.month]} #{resolutionDate.year}"
        archiveSet = @archiveChanges[archiveKey].to_a << {
          userName: userName,
          permission: @permission,
          revisionId: @revisionId,
          date: resolutionDate
        }
        @archiveChanges[archiveKey] = archiveSet

        @usersCount += 1
        @editSummaries << "archive#{resolutionPageName}".to_sym

        newWikitext << botSection
        # absence of newWikitext << @split + section == remove entry from page
        next
      end
      # </ARCHIVING>

      if resolution
        info("  #{userName}'s request already responded to")
        newWikitext << @splitKey + section + botSection
      elsif section.match(/{{comment|Automated comment}}.*MusikBot/) && !shouldUpdatePrereqData
        info("  MusikBot has already commented on #{userName}'s request and no prerequisite data to update")
        newWikitext << @splitKey + section + botSection
      else
        haveResponded = false

        # NOTE: the && !shouldUpdatePrereqData is just a way to see if the request has already been assessed by MusikBot.
        #       We still need this check individually as during the first pass it will be false so that all tasks run, including prereqs

        # <AUTORESPOND>
        if @config["autorespond"] && !shouldUpdatePrereqData
          debug("  Checking if #{userName} already has permission #{@permission}...")

          sleep 1
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
        # </AUTORESPOND>

        # <AUTOFORMAT>
        if @config["autoformat"] && !shouldUpdatePrereqData && @permission != "AWB"
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
        # </AUTOFORMAT>

        if !haveResponded && @permission != "Confirmed" && !userName.match(/bot$/)
          # <PREREQUISTES>
          if @config["prerequisites"] && !prereqs.empty?
            if updatingPrereq = section.match(/&lt;!-- mb-\w*(?:Count|Age) --&gt;/)
              debug("  Checking if prerequisite update is needed...")
            else
              debug("  Checking if #{userName} meets configured prerequisites...")
            end

            sleep 1
            userInfo = getUserInfo(userName, prereqs.keys)

            prereqs.each do |key, value|
              pass = userInfo[key.to_sym] >= value rescue nil

              # TODO: special handling for template editor
              # templateSpaceCount + moduleSpaceCount >= value

              if pass.nil?
                recordError({
                  group: "prerequisites",
                  message: "Failed to fetch data <tt>#{key}</t> for User:#{userName}",
                  logMessage: "      failed to fetch prerequisite data: #{key}"
                })
              elsif pass
                info("      User meets criteria")
                # if updatingPrereq
                #   info("      Removing prereq comment")

                #   # FIXME: either check if this prereq is part of a string of other prereqs and only remove that part,
                #   #   or find a way to remove the comment altogether before looping through prereq array
                #   section.gsub!(/\\n::{{comment\|Automated comment}}.*&lt;!-- mbdate --&gt; \d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/, "")
                #   shouldUpdatePrereqData = false
                # end
              elsif updatingPrereq
                prereqCountRegex = section.scan(/(&lt;!-- mb-#{key} --&gt;(.*)&lt;!-- mb-#{key}-end --&gt;)/)
                prereqText = prereqCountRegex.flatten[0]
                prereqCount = prereqCountRegex.flatten[1].to_i rescue 0

                if !userInfo[key.to_sym].nil? && userInfo[key.to_sym].to_i > prereqCount && prereqCount > 0
                  section.gsub!(prereqText, "&lt;!-- mb-#{key} --&gt;#{userInfo[key.to_sym].to_i}&lt;!-- mb-#{key}-end --&gt;")
                  section.gsub!(prereqSignature, "~~~~")

                  info("    Prerequisite data updated")
                  requestChanges << { type: :prerequisitesUpdated }
                  @editSummaries << :prerequisitesUpdated
                else
                  debug("      Update not needed")
                end
              elsif !pass
                info("      Found unmet prerequisite: #{key}")
                requestChanges << { type: key }.merge(userInfo)
                @editSummaries << :prerequisites
              end
            end
          end
          # </PREREQUISTES>

          # <FETCH DECLINED>
          if @config["fetchdeclined"] && !shouldUpdatePrereqData
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
          # </FETCH DECLINED>
        end

        newWikitext = queueChanges(requestChanges, section, botSection, newWikitext)
      end
    end

    return editPermissionPage(CGI.unescapeHTML(newWikitext.join))
  end

  def self.queueChanges(requestChanges, section, botSection, newWikitext)
    if requestChanges.length > 0
      info("***** Commentable data found *****")
      @usersCount += 1

      newSection = @splitKey + section.gsub(/\n+$/,"")

      if requestChanges.index{|obj| obj[:type] == :prerequisitesUpdated}
        newSection += "\n"
      else
        newSection += messageCompiler(requestChanges)
      end
      newWikitext << newSection + botSection
    else
      info("  ~~ No commentable data found ~~")
      newWikitext << @splitKey + section + botSection
    end
  end

  def self.archiveRequests
    return nil unless @archiveChanges.length > 0

    numRequests = @archiveChanges.values.flatten.length

    info("***** Archiving #{numRequests} requests *****")

    @archiveChanges.keys.each do |key|
      pageToEdit = "Wikipedia:Requests for permissions/#{key}"
      monthName = key.scan(/\/(\w+)/).flatten[0]
      year = key.scan(/\d{4}/).flatten[0]

      @archiveFetchThrotte = 0
      unless pageWikitext = fetchArchivePage(pageToEdit)
        recordError({
          group: "archive",
          message: "Unable to fetch archive page for #{key}. Some requests may not have been saved to archives.",
          logMessage: "  unable to fetch archive page for #{key}, aborting",
          errorSet: "Fatal"
        }) and return false
      end

      newPage = pageWikitext.empty?

      editSummary = "Archiving #{@archiveChanges[key].length} request#{'s' if @archiveChanges[key].length > 1}:"

      # ensure there's a newline at the end
      pageWikitext = pageWikitext.chomp('') + "\n"

      # convert sections as a hash of format {"Month day" => "content"}
      sections = Hash[*pageWikitext.split(/\=\=\s*(\w+ \d+)\s*\=\=/).drop(1).flatten(1)]

      @archiveChanges[key].each do |request|
        # monthName = Date::MONTHNAMES[request[:date].month]
        editSummary += " #{request[:userName]} (#{request[:permission].downcase});"
        archivePageName = request[:permission] == "AWB" ? "Wikipedia talk:AutoWikiBrowser/CheckPage" : "Wikipedia:Requests for permissions/#{request[:permission]}"
        linkMarkup = "*{{Usercheck-short|#{request[:userName]}}} [[#{archivePageName}]] " +
          "<sup>[http://en.wikipedia.org/wiki/Special:PermaLink/#{request[:revisionId]}#User:#{request[:userName].gsub(" ","_")} link]</sup>"

        # add linkMarkup to section
        sectionKey = "#{monthName} #{request[:date].day}"
        sections[sectionKey] = sections[sectionKey].to_s.gsub(/^\n|\n$/,"") + "\n" + linkMarkup + "\n"
      end
      editSummary.chomp!(";")

      # construct back to single wikitext string, sorted by day
      newWikitext = ""
      sortedKeys = sections.keys.sort_by{|k| k.scan(/\d+/)[0].to_i}
      sortedKeys.each do |sortKey|
        newWikitext += "\n== " + sortKey + " ==\n" + sections[sortKey].gsub(/^\n/,"")
      end

      # we're done archiving for this month

      # first see if it's a new page and if so add it to the log page
      if newPage
        logPageName = "Wikipedia:Requests for permissions/#{key.scan(/(.*)\//).flatten[0]}"
        info("  Adding new page [[#{pageToEdit}]] to log [[#{logPageName}]]")

        @archiveFetchThrotte = 0
        unless logPage = fetchArchivePage(logPageName)
          recordError({
            group: "archive",
            message: "Unable to fetch log page [[#{logPageName}]], archiving aborted",
            logMessage: "  unable to fetch log page [[#{logPageName}]], aborting",
            errorSet: "Fatal"
          }) and return false
        end

        # convert to {"year" => "requests"}
        yearSections = Hash[*logPage.split(/\=\=\=\s*(\d{4})\s*\=\=\=/).drop(1)]
        yearSections[year] = "\n*[[#{pageToEdit}]]" + yearSections[year].to_s

        logPageWikitext = ""
        yearSections.sort{|a,b| b <=> a}.to_h.keys.each do |yearSectionKey|
          logPageWikitext += "\n=== " + yearSectionKey + " ===\n" + yearSections[yearSectionKey].gsub(/^\n/,"")
        end

        @editThrottle = 0
        info("    Attempting to write to page [[#{logPageName}]]")
        logPageWikitext = logPage.split("===")[0] + logPageWikitext
        return false unless editPage(logPageName, logPageWikitext, "Adding entry for [[#{pageToEdit}]]")
      end

      @editThrottle = 0
      info("  Attempting to write to page [[#{pageToEdit}]]")
      return false unless editPage(pageToEdit, newWikitext, editSummary)
    end
  end

  def self.editPage(pageName, content, editSummary)
    if @editThrottle < EDIT_THROTTLE
      sleep @editThrottle
      @editThrottle += 1

      begin
        opts = {
          contentformat: "text/x-wiki",
          summary: editSummary,
          text: content
        }
        @mw.edit(pageName, CGI.unescapeHTML(content), opts)
      rescue MediaWiki::APIError => e
        warn("API error when writing to page: #{e.code.to_s}, trying again")
        return editPage(pageName, content, editSummary)
      rescue => e
        error("Unknown exception when writing to page: #{e.message}") and return false
      end
    else
      error("Throttle hit for edit page operation, aborting") and return false
    end
  end

  def self.fetchArchivePage(pageName)
    if @archiveFetchThrotte < 3
      sleep @archiveFetchThrotte
      @archiveFetchThrotte += 1
      info("Fetching page [[#{pageName}]]")
      begin
        opts = {
          prop: 'revisions',
          rvprop: 'content',
          titles: pageName
        }

        pageObj = @mw.custom_query(opts)[0][0].elements['revisions']

        return pageObj[0][0].to_s rescue ""
      rescue => e
        warn("Unable to fetch page properties, reattmpt ##{@archiveFetchThrotte}. Error: #{e.message}")
        return fetchArchivePage(pageName)
      end
    else
      error("Unable to fetch page properties, continuing to process next permission") and return false
    end
  end

  def self.reportErrors
    errorsDigest = Digest::MD5.hexdigest(@errors.values.join)
    if @runStatus["report_errors"] != errorsDigest || parseDateTime(@runStatus["report"]) < currentTime - Rational(3, 24)
      unless generateReport
        @runStatus["report"] = currentTime.to_s
        @runStatus["report_errors"] = errorsDigest
      end
    end
  end

  def self.generateReport
    if @errors.keys.length > 0
      numErrors = @errors.values.flatten.length
      content = "{{hidden|style=float:left;background:transparent|headerstyle=padding-right:3.5em|header=" +
        "<span style='color:red;font-weight:bold'>#{numErrors} error#{'s' if numErrors > 1} as of ~~~~~</span>|content="
      @errors.keys.each do |permissionGroup|
        content += "\n;[[Wikipedia:Requests for permissions/#{permissionGroup}|#{permissionGroup}]]\n"
        @errors[permissionGroup].each do |error|
          content += "* '''#{error[:group].capitalize}''': #{error[:message]}\n"
        end
      end
      content += "}}{{-}}"
    else
      content = "<span style='color:green; font-weight:bold'>No errors!</span> Report generated at ~~~~~"
    end

    @editThrottle = 0
    info("Updating report...")
    unless editPage("User:MusikBot/PermClerk/Report", content, "Updating [[User:MusikBot/PermClerk|PermClerk]] report")
      error("  Unable to update report") and return false
    end
  end

  def self.editPermissionPage(newWikitext, e = nil)
    adminBacklog = !!(newWikitext =~ /\{\{admin\s*backlog(?:\|bot=MusikBot)?\}\}/)

    fixes = []

    if @numOpenRequests > 0
      requestCountMsg = "#{@numOpenRequests} open request#{"s" if @numOpenRequests > 1} remaining"
      newWikitext.gsub!(/\{\{no\s*admin\s*backlog(?:\|bot=MusikBot)?\}\}/, "{{admin backlog|bot=MusikBot}}")
      @editSummaries << :adminBacklog if backlogChange = !adminBacklog
    else
      requestCountMsg = "0 open requests remaining"
      newWikitext.gsub!(/\{\{admin\s*backlog(?:\|bot=MusikBot)?\}\}/, "{{no admin backlog|bot=MusikBot}}")
      @editSummaries << :noAdminBacklog if backlogChange = adminBacklog
    end

    unless @usersCount > 0 || headersRemoved? || backlogChange
      info("Nothing to do this time around") and return true
    end

    info("  updating {{adminbacklog}}") if backlogChange

    # get approved/denied counts
    approved = @editSummaries.count(:archiveApproved)
    denied = @editSummaries.count(:archiveDenied)
    if approved + denied > 0
      archiveMsg = []
      archiveMsg << "#{approved} approved" if approved > 0
      archiveMsg << "#{denied} denied" if denied > 0
      archiveMsg = archiveMsg.join(", ")
    end

    plural = @usersCount > 1

    fixes << "archiving (#{archiveMsg})" if approved.to_i + denied.to_i > 0
    fixes << "marked request as already done" if @editSummaries.include?(:autorespond)
    fixes << "repaired malformed request#{'s' if plural}" if @editSummaries.include?(:autoformat)
    fixes << "prerequisite data updated" if @editSummaries.include?(:prerequisitesUpdated)
    fixes << "unmet prerequisites" if @editSummaries.include?(:prerequisites)
    fixes << "found previously declined requests" if @editSummaries.include?(:fetchdeclined)
    fixes << "unable to archive one or more requests" if @editSummaries.include?(:noSaidPermission)

    if fixes.length == 0
      fixes << "{{admin backlog}}" if @editSummaries.include?(:adminBacklog)
      fixes << "{{no admin backlog}}" if @editSummaries.include?(:noAdminBacklog)
    end

    if @permEditThrottle < EDIT_THROTTLE
      sleep @permEditThrottle
      @permEditThrottle += 1

      info("Attempting to write to page [[#{@pageName}]]")

      # attempt to save
      begin
        opts = {
          basetimestamp: @baseTimestamp,
          contentformat: "text/x-wiki",
          starttimestamp: @startTimestamp,
          summary: "Bot clerking#{" on #{@usersCount} requests" if plural}: #{fixes.join(', ')} (#{requestCountMsg})",
          text: newWikitext
        }

        @mw.edit(@pageName, newWikitext, opts)
      rescue MediaWiki::APIError => e
        if e.code.to_s == "editconflict"
          warn("Edit conflict, trying again")
          return process(@permission)
        else
          warn("API error when writing to page: #{e.code.to_s}, trying again")
          return editPermissionPage(newWikitext, e)
        end
      rescue => e
        recordError({
          group: "Saving",
          message: "Exception thrown when writing to page. Error: <tt>#{e.message}</tt>",
          logMessage: "Unknown exception when writing to page: #{e.message}"
        }) and return false
      end
    else
      recordError({
        group: "Saving",
        message: "Throtte hit for edit page operation. " +
          lastError ? "Error: <tt>#{e.message}</tt>. " : "",
        logMessage: "Throttle hit for edit page operation, continuing to process next permission"
      }) and return false
    end

    true
  end

  def self.findLinks(userName)
    if @userLinksCache[userName]
      debug("Cache hit for #{userName}")
      return @userLinksCache[userName]
    end

    permissionName = @permission == "AWB" ? "AutoWikiBrowser/CheckPage" : @permission

    currentDate = Date.today
    targetDate = currentDate - @config["fetchdeclined_offset"]
    links = []
    datesToFetch = (targetDate..currentDate).select {|d| d.day == targetDate.day || d.day == currentDate.day}.uniq{|m| m.month}

    for date in datesToFetch
      key = "#{Date::MONTHNAMES[date.month]} #{date.year}"
      if @deniedCache[key]
        debug("    Cache hit for #{key}")
        page = @deniedCache[key]
      else
        page = @mw.get("Wikipedia:Requests for permissions/Denied/#{key}")
        @deniedCache[key] = page
      end

      next unless page

      declineDays = page.split(/==\s*\w+\s+/i)
      declineDays.each do |declineDay|
        dayNumber = declineDay.scan(/^(\d+)\s*==/).flatten[0].to_i
        next if dayNumber == 0
        declineDayDate = Date.parse("#{date.year}-#{date.month}-#{dayNumber}")
        if declineDayDate >= targetDate && match = declineDay.scan(/{{Usercheck.*\|#{userName.gsub('_',' ')}}}.*#{permissionName}\]\].*(https?:\/\/.*)\s+link\]/i)[0]
          links << match.flatten[0]
        end
      end
    end

    return @userLinksCache[userName] = links
  end

  def self.getUserInfo(userName, *dataAttrs)
    begin
      prereqs = @config["prerequisites_config"]
      dataAttrs = dataAttrs.flatten

      # return cache if there's nothing new to fetch
      if @userInfoCache[userName] && dataAttrs.select{|da| @userInfoCache[userName].keys.include?(da)}
        debug("  cache hit for #{userName}")
        return @userInfoCache[userName]
      end

      debug("    Fetching data for: #{dataAttrs.join(", ")}")

      # get basic info if we haven't already and query the repl database as needed for other info
      unless @userInfoCache[userName] && @userInfoCache[userName][:editCount]
        apiQuery = @mw.custom_query(
          list: "users",
          ususers: userName,
          usprop: "groups|editcount|registration",
          continue: ""
        )
        apiInfo = apiQuery[0][0].attributes
        registrationDate = apiInfo["registration"] ? Date.parse(apiInfo["registration"]) : nil

        @userInfoCache[userName] = {
          accountAge: registrationDate ? (Date.today - registrationDate).to_i : 0,
          editCount: apiInfo["editcount"].to_i,
          registration: registrationDate,
          userGroups: apiQuery[0][0][0].to_a.collect{|g| g[0].to_s}
        }
      end

      # don't start any queries gone wild
      unless @userInfoCache[userName][:editCount] > 50000
        dataAttrs.each do |dataAttr|
          count = case dataAttr.downcase
            when "articlecount"
              @replClient.countArticlesCreated(userName)
            when "modulespacecount"
              @replClient.countNamespaceEdits(userName, 828)
            when "mainspacecount"
              @replClient.countNamespaceEdits(userName, 0)
            when "manualmainspacecount"
              @replClient.countNonAutomatedNamespaceEdits(userName, 0)
            when "templatespacecount"
              @replClient.countNamespaceEdits(userName, 10)
          end
          @userInfoCache[userName].store(dataAttr.to_sym, count)
        end
        sleep 1
      end

      return @userInfoCache[userName]
    rescue
      error("  Unable to fetch user info for #{userName}") and return false
    end
  end

  def self.getMessage(type, params = {})
    permissionName = @permission == "AWB" ? "AWB access" : @permission.downcase
    return case type
      when :accountAge
        "has had an account for <!-- mb-accountAge -->#{params[:accountAge]}<!-- mb-accountAge-end --> days"
      when :articleCount
        "has created roughly <!-- mb-articleCount -->#{params[:articleCount]}<!-- mb-articleCount-end --> [[WP:ARTICLE|article#{'s' if params[:articleCount] != 1}]]"
      when :autoformat
        "An extraneous header or other inappropriate text was removed from this request"
      when :autorespond
        "already has the \"#{params[:permission]}\" user right"
      when :editCount
        "has <!-- mb-editCount -->#{params[:editCount]}<!-- mb-editCount-end --> total edits"
      when :fetchdeclined
        "has had #{params[:numDeclined]} request#{'s' if params[:numDeclined].to_i > 1} for #{permissionName} declined in the past #{@config["fetchdeclined_offset"]} days (#{params[:declinedLinks]})"
      when :mainSpaceCount
        "has <!-- mb-mainSpaceCount -->#{params[:mainSpaceCount]}<!-- mb-mainSpaceCount-end --> edit#{'s' if params[:mainSpaceCount] != 1} in the [[WP:MAINSPACE|mainspace]]"
      when :manualMainSpaceCount
        "has approximently <!-- mb-manualMainSpaceCount -->#{params[:manualMainSpaceCount]}<!-- mb-manualMainSpaceCount-end --> [[User:MusikBot/PermClerk/prerequisites/Nonautomated edits|non-automated]] edit#{'s' if params[:manualMainSpaceCount] != 1} in the [[WP:MAINSPACE|mainspace]]"
      when :moduleSpaceCount
        "has <!-- mb-moduleSpaceCount -->#{params[:moduleSpaceCount]}<!-- mb-moduleSpaceCount-end --> edit#{'s' if params[:moduleSpaceCount] != 1} in the [[WP:LUA|module namespace]]"
      when :noSaidPermission
        "does not appear to have the permission <tt>#{params[:permission]}</tt><!-- mbNoPerm -->"
      when :templateSpaceCount
        "has <!-- mb-templateSpaceCount -->#{params[:templateSpaceCount]}<!-- mb-templateSpaceCount-end --> edit#{'s' if params[:templateSpaceCount] != 1} in the [[WP:TMP|template namespace]]"
    end
  end

  def self.messageCompiler(requestData)
    str = ""

    commentIndent = @permission == "AWB" ? AWB_COMMENT_INDENT : COMMENT_INDENT

    if index = requestData.index{|obj| obj[:type] == :autoformat}
      requestData.delete_at(index)
      str = "#{commentIndent}<small>#{COMMENT_PREFIX}#{getMessage(:autoformat)} ~~~~</small>\n"
      return str if requestData.length == 0
    end

    if index = requestData.index{|obj| obj[:type] == :autorespond}
      str += "\n::#{requestData[index][:resolution]} (automated response): This user "
    else
      str += commentIndent + COMMENT_PREFIX + "This user "
    end

    requestData.each_with_index do |data, i|
      type = data.delete(:type).to_sym
      str = str.chomp(", ") + " and " if i == requestData.length - 1 && requestData.length > 1
      str += getMessage(type, data) + ", "
    end

    str.chomp(", ") + ". ~~~~\n"
  end

  def self.formattingCheck(oldWikitext)
    ret = true

    splitKeyMatch = oldWikitext.scan(/\n(.*)[^\n]#{Regexp.escape(@splitKey)}(.*)\n/).flatten
    if splitKeyMatch.length > 0
      error("A request heading is not on its own line: #{splitKeyMatch[0]}")
      @errors[@permission] = @errors[@permission].to_a << {
        group: "formatting",
        message: "Unable to process page! A request heading is not on its own line:\n*:" +
          "<code style='color:red'><nowiki>#{splitKeyMatch[0]}</nowiki></code><code><nowiki>#{@splitKey}#{splitKeyMatch[1]}</nowiki></code>"
      }
      ret = false
    end

    return ret
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

  def self.headersRemoved?
    @headersRemoved.length > 0
  end

  def self.setPageProps
    if @fetchThrotte < 3
      sleep @fetchThrotte
      @fetchThrotte += 1
      info("Fetching page properties of [[#{@pageName}]]")
      begin
        @startTimestamp = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

        opts = {
          prop: 'info|revisions',
          rvprop: 'timestamp|content',
          titles: @pageName
        }

        pageObj = @mw.custom_query(opts)[0][0]
        @baseTimestamp = pageObj.elements['revisions'][0].attributes['timestamp']
        @revisionId = pageObj.attributes["lastrevid"]

        return pageObj.elements['revisions'][0][0].to_s
      rescue => e
        warn("Unable to fetch page properties, reattmpt ##{@fetchThrotte}. Error: #{e.message}")
        return setPageProps
      end
    else
      recordError({
        group: "Internal error",
        message: "Unable to fetch page properties.",
        logMessage: "Unable to fetch page properties, continuing to process next permission"
      }) and return false
    end
  end

  def self.recordError(opts)
    errorSet = opts[:errorSet] || @permission
    @errors[errorSet] = @errors[errorSet].to_a << {
      group: opts[:group],
      message: opts[:message]
    }
    error(opts[:logMessage])
  end

  def self.debug(msg); @logger.debug("#{@permission.upcase} : #{msg}"); end
  def self.info(msg); @logger.info("#{@permission.upcase} : #{msg}"); end
  def self.warn(msg); @logger.warn("#{@permission.upcase} : #{msg}"); end
  def self.error(msg); @logger.error("#{@permission.upcase} : #{msg}"); end
  def self.parseDateTime(str); DateTime.parse(str).new_offset(0); end
  def self.currentTime; DateTime.now.new_offset(0); end
end
