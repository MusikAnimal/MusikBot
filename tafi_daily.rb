$LOAD_PATH << '.'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

module TAFIDaily
  def self.run(throttle = 0)
    sleep throttle * 180
    @env = eval(File.open('env').read)

    @mw = MediaWiki::Gateway.new("https://#{@env == :production ? 'en' : 'test'}.wikipedia.org/w/api.php", bot: true)
    Auth.login(@mw)

    exit 1 unless api_get('User:MusikBot/TAFIDaily/Run') == 'true' || @env == :test

    process_nomination_board
  rescue => e
    report_error("Fatal error: #{e.message}")
  end

  def self.process_nomination_board
    text = api_get("Wikipedia:Today's articles for improvement/Nominations", rvsection: 1)
    afi_entries = []
    approved = []
    unapproved = []
    text.split("\n===").each do |entry|
      section = "\n===#{entry}"
      article, assessment = entry.scan(/{{\s*TAFI nom\s*\|\s*article\s*=(.*?)\s*(?:\||}})(?:class\s*=\s*(\w+))?/i).flatten

      if entry =~ /{{\s*approved\s*}}/i
        afi_entries << "# {{icon|#{assessment || 'unknown'}}} [[#{article}]]"
        text.gsub!(section, '')
        approved << section
      end
      if entry =~ /{{\s*(not\s*approved|unapproved)\s*}}/i
        text.gsub!(section, '')
        unapproved << section
      end
    end
    add_afti_entries(afi_entries) if afi_entries.present?
    archive_nominations(:approved, approved) if approved.any?
    archive_nominations(:unapproved, unapproved) if unapproved.any?
  end

  def self.add_afti_entries(entries)
    page = 'Wikipedia:Articles for improvement/List'
    text = api_get(page)
    edit_page(page,
      content: text + entries.join("\n"),
      summary: "Adding #{entries.length} newly approved article#{'s' if entries.length > 1} for improvement"
    )
  end

  def self.archive_section(type, entries)
    page = "Wikipedia:Today's articles for improvement/Archives/#{type == :approved ? 'Successful' : 'Unsuccessful'} Nominations"
  end

  # API-related
  def self.edit_page(page, opts, throttle = 0)
    sleep throttle * 5
    opts.merge(contentformat: 'text/x-wiki')
    @mw.edit(page, CGI.unescapeHTML(opts[:content]), opts)
  rescue MediaWiki::APIError
    return false if throttle > 4
    edit_page(page, opts, throttle + 1)
  end

  def self.report_error(message, throttle = 0)
    return if throttle > 5
    sleep throttle * 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: 'Reporting TAFIWeekly errors'
    }

    content = api_get('User:MusikBot/TAFIWeekly/Error log') + "\n\n#{message} &mdash; ~~~~~\n\n"

    @mw.edit('User:MusikBot/TAFIWeekly/Error log', content, opts)
  rescue MediaWiki::APIError
    report_error(message, throttle + 1)
  end

  def self.api_get(page, opts = {}, throttle = 0)
    sleep throttle * 5
    @mw.get(page, opts)
  rescue MediaWiki::APIError
    if throttle > 5
      report_error("API error when fetching #{page}")
    else
      api_get(page, throttle + 1)
    end
  end
end

TAFIDaily.run
