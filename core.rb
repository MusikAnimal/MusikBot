$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'perm_clerk.rb'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (http://en.wikipedia.org/wiki/User:MusikBot/)'
mw = MediaWiki::Gateway.new('http://en.wikipedia.org/w/api.php', ignorewarnings: true)
Auth.login(mw)

pagesToFetch = [
  "User:MusikBot/PermClerk/Run",
  # "User:MusikBot/PermClerk/Archive/Run",
  "User:MusikBot/PermClerk/Autoformat/Run",
  "User:MusikBot/PermClerk/Autorespond/Run",
  "User:MusikBot/PermClerk/FetchDeclined/Run",
  "User:MusikBot/PermClerk/FetchDeclined/Offset",
  "User:MusikBot/PermClerk/Prerequisites/Run",
  "User:MusikBot/PermClerk/Prerequisites/config.js"
].join("|")

logger = Logger.new("perm_clerk.log")

begin
  configPages = mw.custom_query(prop: "revisions", titles: pagesToFetch, rvprop: "content")[0]
rescue => e
  logger.error("FATAL: Unable to fetch config pages. Error: #{e.message}")
end

config = {}

for configPage in configPages
  configName = configPage.attributes["title"].gsub(/User\:MusikBot\/PermClerk\/?/,"").gsub("/","_").downcase.chomp("_run").chomp(".js")

  if configName == "fetchdeclined_offset"
    config[configName] = configPage.elements['revisions'][0][0].to_s.to_i
  elsif configName == "prerequisites_config"
    config[configName] = JSON.parse(CGI.unescapeHTML(configPage.elements['revisions'][0][0].to_s))
  else
    config[configName] = configPage.elements['revisions'][0][0].to_s == "true"
  end
end

if config["run"]
  PermClerk.init(mw, config)
else
  logger.error("PermClerk disabled")
end
