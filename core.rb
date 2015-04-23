$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'perm_clerk.rb'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (http://en.wikipedia.org/MusikBot/)'
mw = MediaWiki::Gateway.new('http://test.wikipedia.org/w/api.php', ignorewarnings: true)
Auth.login(mw)

# TODO: fetch duration from User:MusikBot/PermClerk/Offset and run values for each permission in same API call
if mw.get("User:MusikBot/PermClerk/Run").to_s.downcase == "true"
  PermClerk.init(mw)
else
  logger = Logger.new("perm_clerk.log")
  logger.error("PermClerk disabled")
end