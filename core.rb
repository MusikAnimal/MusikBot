$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'perm_clerk.rb'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (http://en.wikipedia.org/wiki/User:MusikBot/)'
mw = MediaWiki::Gateway.new('http://en.wikipedia.org/w/api.php', ignorewarnings: true)
Auth.login(mw)

pagesToFetch = [
  "User:MusikBot/PermClerk/Run",
  "User:MusikBot/PermClerk/FetchDeclined",
  "User:MusikBot/PermClerk/FetchDeclined/Offset",
  "User:MusikBot/PermClerk/Autoformat"
].join("|")

logger = Logger.new("perm_clerk.log")

begin
  configPages = mw.custom_query(prop: "revisions", titles: pagesToFetch, rvprop: "content")[0]

  config = {}

  for configPage in configPages
    configName = configPage.attributes["title"].gsub("User:MusikBot/PermClerk/","").gsub("/","_").downcase

    if configName == "fetchdeclined_offset"
      config[configName] = configPage.elements['revisions'][0][0].to_s.to_i
    else
      config[configName] = configPage.elements['revisions'][0][0].to_s == "true"
    end
  end

  if config["run"]
    PermClerk.init(mw, config)
  else
    logger.error("PermClerk disabled")
  end
rescue => e
  logger.error("FATAL ERROR: Unable to fetch config pages. Error: #{e.message}")
end