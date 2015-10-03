$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'httparty'
require 'logger'
require 'pry'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

module SoundSearch
  @enwiki_mw = MediaWiki::Gateway.new('https://en.wikipedia.org/w/api.php', bot: true)
  Auth.login(@enwiki_mw)

  def self.run
    # first get list of all sound file in list pages
    sound_list_pages = [
      'A',
      'Ba',
      'Bb–Bz',
      'C',
      'D–G',
      'H',
      'I–L',
      'M',
      'N–Q',
      'R',
      'S',
      'T–Z'
    ].collect { |p| 'Wikipedia:Sound/list/' + p }

    sound_list = []

    sound_list_pages.each do |sound_list_page|
      sound_list_source = @enwiki_mw.get(sound_list_page)
      sound_list += sound_list_source.scan(/\[\[media:\s*(.*?.(?:ogg|flac|midi))/i).flatten
    end

    search_endpoint = 'http://localhost:9292/musikanimal/api/sound_search'

    composer_list_page = 'List of composers by name'
    composer_list_source = @enwiki_mw.get(composer_list_page)
    composer_files = {}

    composer_list_source.split(/==\w+==/).drop(1).each_with_index do |composerSet, index| # /
      character = (index + 65).chr
      section_content = "== #{character} ==\n"

      # may contain pipes, e.g. "Mozart (composer)|Mozart"
      composer_strings = composerSet.scan(/^\*\s*\[\[(.*?)\]\]/i).flatten

      composer_strings.each do |composerString|
        composer, composer2 = composerString.split('|')

        sleep 0.5

        begin
          new_composer_files = HTTParty.get(search_endpoint, {
            query: {
              composer: composer,
              list: 'unused'
            },
            timeout: 600
          })['files']

          if composer2 && composer2 = composer2.scan(/(.*)\]\]/).flatten[0]
            sleep 0.5
            new_composer_files += HTTParty.get(search_endpoint, {query: {
              composer: composer
            }, timeout: 600})['files']
          end

          if new_composer_files.any?
            composer_files[character] ||= {}
            composer_files[character][composer] = new_composer_files
          end

          puts "#{composerString} #{'-- ' + new_composer_files.length.to_s + ' found' if new_composer_files.any?}"

          if new_composer_files.length > 0
            sleep 0.5
            content = ";#{composerString}\n"

            before_length = new_composer_files.length
            new_composer_files.delete_if { |file| sound_list.include?(file['title'].gsub(/^File:/, '')) }

            if new_composer_files.length != before_length
              puts '    contained files already in sound list!'
            end

            if new_composer_files.length > 0
              new_composer_files.each do |file|
                content += "* [[:#{file['title']}]]\n"
              end

              section_content += content

              ret = write_to_list(section_content, index + 1, composerString)

              log_error(composer, 'throttle hit when writing to page') if ret.nil?
            end
          end
        rescue => e
          log_error(composer, e.message)
        end
      end

      puts "=== #{character} SET COMPLETE ==="
      sleep 0.5
    end
  end

  def self.log_error(composer, message)
    puts "FAILURE ON #{composer}, ERROR: #{message}"
    @logger ||= Logger.new('sound_search.err')
    @logger.error("FAILURE ON #{composer}, ERROR: #{message}")
  end

  def self.write_to_list(content, section, composer_string, throttle = 0)
    return nil if throttle > 5

    sleep(throttle * 5)

    opts = {
      contentformat: 'text/x-wiki',
      section: section,
      summary: "Listing unused files for #{composer_string}",
      text: content
    }

    begin
      @enwiki_mw.edit('User:MusikBot/SoundSearch/List2', CGI.unescapeHTML(content), opts)
    rescue MediaWiki::APIError
      return write_to_list(content, section, composer_string, throttle + 1)
    end

    true
  end
end

SoundSearch.run
