$LOAD_PATH << '..'
require 'musikbot'
require 'cinch'
require 'em-eventsource'

module NSFW
  def self.run
    $mb = MusikBot::Session.new(inspect)

    bot = Cinch::Bot.new do
      configure do |c|
        c.server = 'chat.freenode.org'
        c.channels = ['##MusikBot_II']
        c.nick = $mb.app_config[:nsfw_irc][:nick]
        c.password = $mb.app_config[:nsfw_irc][:password]
        c.user = $mb.app_config[:nsfw_irc][:user]
      end

      helpers do
        def get_images_and_scores(log_id)
          puts "get_images_and_scores for #{log_id}"
          ret = $mb.gateway.custom_query(
            list: 'abuselog',
            afllogid: log_id,
            aflprop: 'details'
          )

          images = []

          # Find each image that was added and removed
          ret.elements['abuselog'].to_a.each do |entry|
            entry.elements['details/added_lines'].each do |line|
              # images << added.scan(/(?:\=(?:\s*\[\[(?:File|Image)\s*:)|(?:File|Image)\s*:)\s*(.*?\.(?:jpe?g|svg|png|gif|webm|ogv))/).flatten
              images << line[0].to_s.scan(/(?:\[\[\s*(?:File|Image)\s*:\s*|(?:logo|image|image_name|cover|image_file|image_photo|insignia|photo|mark|map|range_map)\d*\s*\=|<gallery>)\s*(.*?\.(?:jpe?g|svg|png|gif|tiff|webm|ogv))/i)
            end
          end

          # Remove duplicates
          images.flatten!.uniq!

          if images.empty?
            puts "No images parsed for log ID #{log_id}"
            return []
          end

          # Get the URLs for the images
          urls = get_urls(images)

          # Build hash of images => scores.
          scores = {}
          urls.each do |title, url|
            score = get_score(url)
            if score > 0.4
              scores[title] = score
            end
          end

          scores
        end

        def get_messages(user, log_id, scores)
          messages = [
            "User:#{user.score} added images that are NSFW with https://en.wikipedia.org/wiki/Special:AbuseLog/#{log_id}"
          ]

          scores.each do |title, score|
            messages << "* https://en.wikipedia.org/wiki/#{title.score} - #{score}"
          end

          messages
        end

        def get_urls(images)
          ret = $mb.gateway.custom_query(
            prop: 'imageinfo',
            titles: images.map { |i| "File:#{i}" }.join('|'),
            iiprop: 'url'
          )

          urls = {}
          ret.elements['pages'].to_a.each do |page|
            urls[page.attributes['title']] = page.elements['imageinfo'][0].attributes['url'] if page && page.elements['imageinfo']
          end

          urls
        end

        def get_score(url)
          $mb.repl_client.getter.post('https://nsfw.wmflabs.org',
            body: { url: url }
          ).to_f
        end
      end

      on :connect do
        EM.run do
          source = EventMachine::EventSource.new('https://stream.wikimedia.org/v2/stream/recentchange')

          source.on "message" do |message|
            data = JSON.parse(message)
            if data['server_name'] == 'en.wikipedia.org' && data['log_action'] == 'hit' && 1001 == data['log_params']['filter'].to_i
              scores = get_images_and_scores(data['log_params']['log'])

              if scores.any?
                msgs = get_messages(data['user'].score, data['log_params']['log'], scores)

                msgs.each do |msg|
                  User('MusikAnimal').send(msg)
                end
              end
            end
          end

          source.error do |error|
            puts "EventStreams error: #{error}"
          end

          source.open do
            puts "EventStreams connection opened"
          end

          source.start
        end
      end

      on :message, "!ping" do |m|
        m.reply 'Pong.'
      end
    end

    bot.start
  end
end

NSFW.run
