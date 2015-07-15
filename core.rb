$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'perm_clerk.rb'

config = {}
config[:env] = eval(File.open("env").read)

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
mw = MediaWiki::Gateway.new("https://#{config[:env] == :production ? "en" : "test"}.wikipedia.org/w/api.php")
Auth.login(mw)

# refresh randomized infobox image, just for fun :)
# FIXME: doesn't seem to work?? or doesn't update the lastrun properly...
if config[:env] == :production
  begin
    runStatus = eval(File.open("lastrun", "r").read) rescue {}

    if DateTime.parse(runStatus["purge"]).new_offset(0) + 1 < DateTime.now.new_offset(0)
      mw.purge("User:MusikBot")

      runStatus["purge"] = DateTime.now.new_offset(0).to_s
      runFile = File.open("lastrun", "r+")
      runFile.write(runStatus.inspect)
      runFile.close
    end
  rescue
    puts "Unable to purge User:MusikBot"
  end
end

pagesToFetch = [
  "User:MusikBot/PermClerk/Run",
  "User:MusikBot/PermClerk/Archive/Run",
  "User:MusikBot/PermClerk/Archive/Offset",
  "User:MusikBot/PermClerk/Autoformat/Run",
  "User:MusikBot/PermClerk/Autorespond/Run",
  "User:MusikBot/PermClerk/FetchDeclined/Run",
  "User:MusikBot/PermClerk/FetchDeclined/Offset",
  "User:MusikBot/PermClerk/Prerequisites/Run",
  "User:MusikBot/PermClerk/Prerequisites/config.js",
  "User:MusikBot/PermClerk/Regex/Done",
  "User:MusikBot/PermClerk/Regex/Notdone"
].join("|")

logger = Logger.new("perm_clerk.log")

begin
  configPages = mw.custom_query(prop: "revisions", titles: pagesToFetch, rvprop: "content")[0]
rescue => e
  logger.error("FATAL: Unable to fetch config pages. Error: #{e.message}")
end

for configPage in configPages
  configName = configPage.attributes["title"].gsub(/User\:MusikBot\/PermClerk\/?/,"").gsub("/","_").downcase.chomp("_run").chomp(".js")

  if ["fetchdeclined_offset", "archive_offset"].include?(configName)
    config[configName] = configPage.elements['revisions'][0][0].to_s.to_i
  elsif configName == "prerequisites_config"
    config[configName] = JSON.parse(CGI.unescapeHTML(configPage.elements['revisions'][0][0].to_s))
  elsif configName =~ /^regex_/
    config[configName] = configPage.elements['revisions'][0][0].to_s
  else
    config[configName] = configPage.elements['revisions'][0][0].to_s == "true"
  end

  if config[:env] != :production
    config["archive"] = true
    config["autorespond"] = false
    config["autoformat"] = false
    config["fetchdeclined"] = false
    config["prerequisites"] = true
  end
end

if config["run"]
  PermClerk.init(mw, config)
else
  logger.error("PermClerk disabled")
end
