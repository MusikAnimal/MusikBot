# TODO: have the bot update User:MusikBot/task_1 with 'true' unless the task doesn't finish, in which case it will write 'false'
#       Then on User:MusikBot in the lists of tasks it will transclude the page into a parser function showing whether or not the task is running and when it failed

module PermClerk
  require 'date'
  require 'pry'

  USER = "Example One"

  # GET REQUESTS
  EDIT_IDENTIFIER = "Automated comment"
  SPLIT_KEY = "====[[User:"
  SEARCH_DAYS = 30

  def self.init(mw)
    @mw = mw
    requests = mw.get("Wikipedia:Requests for permissions/Rollback", {rvsection: 1})
    sections = requests.split(SPLIT_KEY)

    sections.each_index do |i|
      links = []
      section = sections[i]
      request = section.match(/{{rfplinks\|1=(.*)}}/)
      if request
        userName = request[1]
        sectionId = i #sections.index{|s| s.include?(userName)}
        puts "(#{sectionId}) #{userName}"

        links += find_link(userName)
        if links.length > 0
          puts "#{links.length} links found for #{userName}"
          comment(section, sectionId, links)
        else
          puts "no links found for #{userName}"
        end
      end
      puts "======"
    end
  end

  def self.find_link(userName)
    currentDate = Date.today
    targetDate = currentDate - SEARCH_DAYS
    links = []

    for monthIndex in (targetDate.month..currentDate.month)
      monthName = Date::MONTHNAMES[monthIndex]
      puts monthName
      page = @mw.get("Wikipedia:Requests for permissions/Denied/#{monthName} #{Date.today.year}")
      matches = page.scan(/{{Usercheck.*#{userName}.*\/Rollback\]\].*(http:\/\/.*)\s+link\]/)
      links += matches.flatten if matches
    end

    return links
  end

  def self.comment(section, sectionId, links)
    message = ":[[File:Pictogram voting comment.svg|15px|link=]]&nbsp;'''"+EDIT_IDENTIFIER+"''' "
    linksMessage = links.map{|l| "[#{l}]"}.join
    if !section.include?(EDIT_IDENTIFIER)
      comment = "#{message} A request for this user was declined (#{linksMessage}) within the past #{SEARCH_DAYS} days. ~~~~"
      newWikitext = SPLIT_KEY + section + comment
      puts comment
      # save to page
      puts "saving..."
    else
      puts "Already commented"
    end
  end
end