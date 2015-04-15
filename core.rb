$LOAD_PATH << '.'

require 'media_wiki'
require 'auth.rb'
require 'perm_clerk.rb'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (http://en.wikipedia.org/MusikBot/)'
mw = MediaWiki::Gateway.new('http://test.wikipedia.org/w/api.php', ignorewarnings: true)
Auth.login(mw)

# FIXME: fetch duration from User:MusikBot/PermClerk/Offset in same API call
if @mw.get("User:MusikBot/PermClerk/Run").to_s.downcase == "true"
  PermClerk.init(mw)
else
  puts "PermClerk disabled"
end