$LOAD_PATH << '..'

require 'mediawiki-gateway'
require 'auth.rb'
require 'pry'
require 'socket'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
mw = MediaWiki::Gateway.new("https://#{config[:env] == :production ? "en" : "test"}.wikipedia.org/w/api.php", {
  bot: true
})
Auth.login(mw)

server = "irc.cluenet.org"
port = "6667"
channel = "#cluebotng-spam"
nick = "MusikBot"

s = TCPSocket.open(server, port)
print("addr: " + s.addr.join(":"), "\n")
print("peer: " + s.peeraddr.join(":"), "\n")
s.puts "USER musikbot 0 * MusikBot"
s.puts "NICK #{nick}"

feed = s.gets
tries = 0

while !feed.include?("PING")
  # FIXME: only try so many times!
  feed = s.gets
end

pong = feed.scan(/PING :(.*)\r\n/).flatten.first
s.puts "PONG :#{pong}\r\n"

sleep 1

s.puts "JOIN #{channel}"

50.times do
  feed = s.gets
end

reverts = []
startTime = Time.now

while Time.now < startTime + 180
  if match = s.gets.scan(/(.*)\# Reverted/).flatten.first
    reverts << match
  end
end

puts reverts.length