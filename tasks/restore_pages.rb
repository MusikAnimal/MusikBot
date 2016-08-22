$LOAD_PATH << '..'

module RestorePages
  require 'mediawiki-gateway'
  require 'auth.rb'
  require 'pry'

  def self.run
    env = File.open("env").read
    skipped_pages = File.open("skipped_pages", "w")

    MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
    @mw = MediaWiki::Gateway.new("https://#{env == 'production' ? "en" : "test"}.wikipedia.org/w/api.php", {
      bot: true,
      ignorewarnings: true
    })
    Auth.login(@mw)

    source_page = File.open("restore_list1").read
    pages = source_page.split("\n").collect{|p| p.scan(/\[\[:(.*)\]\]/).flatten[0]}

    token = @mw.custom_query({meta: "tokens"})[0].attributes["csrftoken"]

    pages[470..2499].each_with_index do |page, index|
      puts "Restoring #{index + 471} out of #{pages.length} pages: #{page}"

      logEvents = @mw.custom_query({
        list: "logevents",
        letype: "delete",
        letitle: page
      })

      if logEvents[0].length > 1
        puts "  Skipping as there are multiple entries in the deletion log"
        skipped_pages.write("#{page}\n") and next
      end

      sleep 4
      begin
        @undeleteThrottle = 0
        undelete(page, token)
        sleep 1

        @fetchThrottle = 0
        if content = getPageContent(page)
          if @mw.get(page).length == 0
            @mw.edit(page, CGI.unescapeHTML("{{OW}}"), {
              contentformat: "text/x-wiki",
              summary: "Adding {{OW}}: Previous talk page content available in page history",
              text: "{{OW}}"
            })
          end
        else
          puts "  Failed to fetch page #{page}, skipping..."
          skipped_pages.write("#{page}\n") and next
        end
      rescue => e
        puts "Something went wrong!!! Error: #{e}\nAborting..."
      end
    end
  end

  def self.getPageContent(page)
    @fetchThrottle += 1
    if @fetchThrottle > 3
      puts "fetch throttle hit"
      return false
    end

    content = @mw.get(page)

    unless content.is_a?(String)
      puts "fetch attempt ##{@fetchThrottle+1}"
      sleep 2
      return getPageContent(page)
    end

    content
  end

  def self.undelete(page, token)
    @undeleteThrottle += 1
    if @undeleteThrottle > 3
      puts "throttle hit, aborting..."
      exit 1
    end

    delResp = @mw.send(:send_request, {
      action: "undelete",
      title: page,
      reason: "Restoring deleted revisions of user talk page, see [[Wikipedia:Bots/Requests for approval/MusikBot 3]]",
      token: token
    })
  end
end

RestorePages.run