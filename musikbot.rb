require 'optparse'
require 'i18n'
require 'mediawiki-gateway'
require 'auth'
require 'redis'
require 'httparty'
require 'repl'
require 'uri'
require 'pry-byebug'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

class String
  def capitalize_first
    self[0] = self[0].capitalize
    self
  end

  def uncapitalize
    self[0, 1].downcase + self[1..-1]
  end

  def uppercase?
    match(/\p{Upper}/).present?
  end

  def lowercase?
    !uppercase?
  end

  def capitalized?
    self[0, 1].uppercase?
  end

  def score
    tr(' ', '_')
  end

  def descore
    tr('_', ' ')
  end

  def translate(opts = {})
    I18n.t(self, opts)
  end
  alias_method :t, :translate
end

def t(key, opts = {})
  if I18n.locale == :en && opts.blank?
    key
  elsif key.is_a?(Symbol)
    I18n.t(key, opts)
  else
    res = key.clone.uncapitalize.translate(opts)
    key.capitalized? ? res.capitalize_first : res.uncapitalize
  end
end

module MusikBot
  class Session
    def initialize(task, prodonly = false)
      @task = task
      @opts = {
        prodonly: prodonly,
        project: env == 'test' && !prodonly ? 'test.wikipedia' : 'en.wikipedia'
      }
      OptionParser.new do |args|
        args.banner = 'Usage: script.rb [options]'

        args.on('-p', '--project PROJECT', 'Project name (en.wikipedia)') { |v| @opts[:project] = v }
      end.parse!

      @opts[:lang] = env == 'test' ? :en : @opts[:project].scan(/^\w\w/).first.to_sym
      I18n.load_path = Dir["#{PROJECT_ROOT}/dictionaries/*/*.yml"]
      I18n.backend.load_translations
      I18n.config.available_locales = [:en, :fr, :pt]
      I18n.locale = @opts[:lang]

      @gateway = MediaWiki::Gateway.new("https://#{@opts[:project]}.org/w/api.php",
        bot: bot?,
        retry_count: 5,
        user_agent: "MusikBot/1.1 (https://#{@opts[:project]}.org/wiki/User:MusikBot/)",
        ignorewarnings: true
      )
      Auth.login(@gateway)

      unless @task =~ /Console|SoundSearch/ || @opts[:prodonly] || env == 'test' || get("User:MusikBot/#{@task}/Run") == 'true'
        report_error("#{@task} disabled")
        exit 1
      end
    end
    attr_reader :opts
    attr_reader :gateway
    attr_reader :task

    def env
      if @env.present?
        @env
      else
        @env = File.open("#{PROJECT_ROOT}/env").read.strip
      end
    end

    def lang
      @opts[:lang]
    end

    def bot?
      bot_blacklist = ['fr.wikipedia']
      !bot_blacklist.include?(@opts[:project])
    end

    # Utilities
    def now
      DateTime.now.new_offset(0)
    end

    def today
      now.to_date
    end

    def delocalize_wiki_date(str)
      if lang == :en
        str
      else
        str.scan(/#{I18n.t('time.formats.wiki_time_regex', lang)}/).flatten.join
      end
    end

    def parse_date(obj, convert = false)
      if obj.is_a?(String)
        begin
          DateTime.parse(obj).new_offset(0)
        rescue => e
          raise e unless e.message == 'invalid date'
          # try as if i18n wiki date
          DateTime.parse(delocalize_wiki_date(obj))
        end
      elsif obj.is_a?(DateTime)
        obj.new_offset(0)
      elsif convert
        obj.to_datetime
      else
        obj
      end
    end

    def wiki_date(date, locale = @opts[:lang])
      I18n.l(parse_date(date, true),
        format: :wiki_time,
        locale: locale
      )
    end

    def api_date(date)
      parse_date(date).strftime('%Y-%m-%dT%H:%M:%SZ')
    end

    def db_date(date)
      parse_date(date).strftime('%Y%m%d000000')
    end

    # Wiki-tools
    def wiki_tools(tool, query)
      @getter ||= HTTParty
      base_uri = "https://tools.wmflabs.org/musikanimal/api/#{tool}"
      @getter.get(base_uri, query: query)
    end

    # Database-related
    # FIXME: currently does enwiki-only
    def repl_client
      return @repl_client if @repl_client
      un, pw, host, db, port = Auth.db_credentials(lang)
      @repl_client = Repl::Session.new(un, pw, host, db, port)
    end

    # Cache-related
    def redis_client
      @redis_client ||= Auth.redis
    end

    def cache(base_key, time = 3600)
      key = "ma-#{Digest::MD5.hexdigest(base_key.to_s)}"

      unless ret = redis_client.get(key)
        @redis_client.set(key, ret = yield)
        @redis_client.expire(key, time)
      end

      ret
    end

    def disk_cache(filename, time = 3600)
      filename = "#{PROJECT_ROOT}/disk_cache/#{filename}.yml"

      if File.mtime(filename) < Time.now.utc - time
        ret = yield

        cache_file = File.open(filename, 'r+')
        cache_file.write(
          YAML.dump(ret)
        )
        cache_file.close
      else
        ret = YAML.load(File.open(filename).read)
      end

      ret
    end

    def local_storage(data = nil)
      if data
        file = File.open("#{PROJECT_ROOT}/disk_cache/#{@task}.yml", 'r+')
        file.write(YAML.dump(data))
        file.close
      else
        YAML.load(
          File.open("#{PROJECT_ROOT}/disk_cache/#{@task}.yml", 'r').read
        )
      end
    end

    # API-related
    def get(page, opts = {})
      @gateway.get(page, opts)
    end

    def edit(page, opts = {})
      opts.merge(contentformat: 'text/x-wiki')
      if opts.delete(:conflicts)
        opts.merge(
          basetimestamp: @base_timestamp,
          starttimestamp: @start_timestamp
        )
      end

      @gateway.edit(page, opts.delete(:content), opts)
    end

    def config
      @config ||= JSON.parse(CGI.unescapeHTML(get("User:MusikBot/#{@task}/config")))
    end

    def get_revision_at_date(page, date, opts = {})
      full_response = opts.delete(:full_response)

      opts = {
        prop: 'revisions',
        rvprop: 'content',
        titles: page,
        rvstart: api_date(date),
        rvlimit: 1
      }.merge(opts)

      page_obj = @gateway.custom_query(opts).elements['pages'][0]

      return nil if page_obj.nil?

      if full_response
        page_obj
      else
        rev = page_obj.elements['revisions/rev']
        opts[:rvprop] == 'content' ? rev.text : rev
      end
    rescue MediaWiki::APIError => e
      report_error("Unable to fetch #{page}", e)
    end

    def get_page_props(page, opts = {})
      full_response = opts.delete(:full_response)
      no_conflict = opts.delete(:no_conflict)

      opts = {
        prop: 'info|revisions',
        rvprop: 'timestamp|content',
        titles: page
      }.merge(opts)

      page_obj = @gateway.custom_query(opts).elements['pages'][0]
      unless page_obj.elements['revisions']
        report_error("Unable to fetch properties of [[#{page}]] - page does not exist!")
      end

      unless no_conflict
        @start_timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
        @base_timestamp = page_obj.elements['revisions'][0].attributes['timestamp']
      end

      if full_response
        page_obj
      else
        page_obj.elements['revisions/rev'].text
      end
    end
    attr_reader :base_timestamp
    attr_reader :start_timestamp

    def report_error(message, e = nil)
      return raise if env == 'test'

      opts = {
        contentformat: 'text/x-wiki',
        summary: "Reporting #{@task} errors"
      }
      page = "User:MusikBot/#{@task}/Error log"

      if e
        STDERR.puts "#{'>' * 20} #{DateTime.now.strftime('%Y-%m-%d %H:%M:%S')}"
        STDERR.puts "Error during processing: #{$ERROR_INFO}"
        STDERR.puts "Backtrace:\n\t#{e.backtrace.join("\n\t")}"
        message += " &mdash; in {{mono|#{e.backtrace_locations.first.label}}}: ''#{e.message}''"
      end

      content = get(page)
      content.sub!(content.scan(/.*\n/).first, '') if content.length > 10_000

      last_timestamp, last_message = content.split(/\[(.*?)\] /).last(2)
      if last_message != message || parse_date(last_timestamp) < today - 1
        message = "\n*[~~~~~] #{message}"
        @gateway.edit(page, content + message, opts)
      end

      false
    end
  end
end
