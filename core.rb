$LOAD_PATH << '.'

require 'media_wiki'
require 'auth.rb'
require 'perm_clerk.rb'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (http://en.wikipedia.org/MusikBot/)'
mw = MediaWiki::Gateway.new('http://test.wikipedia.org/w/api.php', ignorewarnings: true)
Auth.login(mw)

PermClerk.init(mw)