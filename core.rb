$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'repl.rb'
require 'perm_clerk.rb'
require 'pry'

config = {}
config[:env] = eval(File.open('env').read)

un, pw, host, db, port = Auth.db_credentials(config[:env])
repl_client = Repl::Session.new(un, pw, host, db, port)

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
mw = MediaWiki::Gateway.new("https://#{config[:env] == :production ? 'en' : 'test'}.wikipedia.org/w/api.php", bot: true)
Auth.login(mw)

# refresh randomized infobox image, just for fun :)
if config[:env] == :production
  begin
    run_status = eval(File.open('lastrun', 'r').read) rescue {}

    if DateTime.parse(run_status['purge']).new_offset(0) + 1 < DateTime.now.new_offset(0)
      mw.purge('User:MusikBot')

      run_status['purge'] = DateTime.now.new_offset(0).to_s
      run_file = File.open('lastrun', 'r+')
      run_file.write(run_status.inspect)
      run_file.close
    end
  rescue
    puts 'Unable to purge User:MusikBot'
  end
end

pages_to_fetch = [
  'User:MusikBot/PermClerk/Run',
  'User:MusikBot/PermClerk/Archive/Run',
  'User:MusikBot/PermClerk/Archive/Offset',
  'User:MusikBot/PermClerk/Autoformat/Run',
  'User:MusikBot/PermClerk/Autorespond/Run',
  'User:MusikBot/PermClerk/FetchDeclined/Run',
  'User:MusikBot/PermClerk/FetchDeclined/Offset',
  'User:MusikBot/PermClerk/Prerequisites/Run',
  'User:MusikBot/PermClerk/Prerequisites/config.js',
  'User:MusikBot/PermClerk/Regex/Done',
  'User:MusikBot/PermClerk/Regex/Notdone'
].join('|')

`stat perm_clerk.log`
logger = Logger.new('perm_clerk.log')

begin
  config_pages = mw.custom_query(prop: 'revisions', titles: pages_to_fetch, rvprop: 'content')[0]
rescue => e
  logger.error("FATAL: Unable to fetch config pages. Error: #{e.message}")
end

config_pages.each do |config_page|
  config_name = config_page.attributes['title'].gsub(%r{User\:MusikBot/PermClerk/?}, '').gsub('/', '_').downcase.chomp('_run').chomp('.js')

  if %w(fetchdeclined_offset archive_offset).include?(config_name)
    config[config_name] = config_page.elements['revisions'][0][0].to_s.to_i
  elsif config_name == 'prerequisites_config'
    config[config_name] = JSON.parse(CGI.unescapeHTML(config_page.elements['revisions'][0][0].to_s))
  elsif config_name =~ /^regex_/
    config[config_name] = config_page.elements['revisions'][0][0].to_s
  else
    config[config_name] = config_page.elements['revisions'][0][0].to_s == 'true'
  end
end

if config[:env] != :production
  config['archive'] = false
  config['autorespond'] = false
  config['autoformat'] = false
  config['fetchdeclined'] = false
  config['prerequisites'] = true
end

if config['run']
  PermClerk.init(mw, repl_client, config)
else
  logger.error('PermClerk disabled')
end
