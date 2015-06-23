$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'perm_clerk.rb'

config = {}
config[:env] = eval(File.open("env").read)

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
mw = MediaWiki::Gateway.new("https://#{config[:env] == :production ? "en" : "test"}.wikipedia.org/w/api.php")
Auth.login(mw)

pagesToFetch = [
  "User:MusikBot/PermClerk/Run",
  # "User:MusikBot/PermClerk/Archive/Run",
  # "User:MusikBot/PermClerk/Archive/Offset",
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

  if configName == "fetchdeclined_offset"
    config[configName] = configPage.elements['revisions'][0][0].to_s.to_i
  elsif configName == "prerequisites_config"
    config[configName] = JSON.parse(CGI.unescapeHTML(configPage.elements['revisions'][0][0].to_s))
  elsif configName =~ /^regex_/
    config[configName] = configPage.elements['revisions'][0][0].to_s
  else
    config[configName] = configPage.elements['revisions'][0][0].to_s == "true"
  end

  if config[:env] != :production
    config["archive"] = false
    config["autorespond"] = false
    config["autoformat"] = true
    config["fetchdeclined"] = true
    config["prerequisites"] = true
  end
end

if config["run"]
  PermClerk.init(mw, config)
else
  logger.error("PermClerk disabled")
end
