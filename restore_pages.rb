$LOAD_PATH << '.'

module RestorePages
  require 'mediawiki-gateway'
  require 'auth.rb'
  require 'pry'

  env = eval(File.open("env").read)
  skipped_pages = File.open("skipped_pages", "w")

  MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
  mw = MediaWiki::Gateway.new("https://#{env == :production ? "en" : "test"}.wikipedia.org/w/api.php", {
    bot: true,
    ignorewarnings: true
  })
  Auth.login(mw)

  source_page = mw.get("User:BD2412/sandbox6")
  pages = source_page.split("\n").collect{|p| p.scan(/\[\[:(.*)\]\]/).flatten[0]}
  pages.delete_at(0)

  token = mw.custom_query({meta: "tokens"})[0].attributes["csrftoken"]

  pages.each_with_index do |page, index|
    puts "Restoring #{index + 1} out of #{pages.length} pages: #{page}"

    logEvents = mw.custom_query({
      list: "logevents",
      letype: "delete",
      letitle: page
    })
    if logEvents[0].length > 1
      puts "  Skipping as there are multiple entries in the deletion log"
      skipped_pages.write("#{page}\n")
      next
    end

    sleep 5
    begin
      delResp = mw.send(:send_request, {
        action: "undelete",
        title: page,
        reason: "Restoring deleted revisions of user talk page",
        token: token
      })
    rescue => e
      puts "Something went wrong!!! Error: #{e}\nAborting..."
    end
  end
end