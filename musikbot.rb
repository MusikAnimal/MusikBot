require 'optparse'
require 'i18n'
require 'mediawiki-gateway'
require 'auth'
require 'redis'
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

  def translate(opts = {})
    I18n.t(self, opts)
  end
  alias_method :t, :translate
end

def t(str, opts = {})
  return str if I18n.locale == :en && opts.empty?
  res = str.clone.uncapitalize.translate(opts)
  str.capitalized? ? res.capitalize_first : res.uncapitalize
end

module MusikBot
  class Session
    def initialize(task, prodonly = false)
      @task = task
      @env = eval(File.open("#{PROJECT_ROOT}/env").read)
      @opts = {
        prodonly: prodonly,
        project: @env == :test ? 'test.wikipedia' : 'en.wikipedia'
      }
      OptionParser.new do |args|
        args.banner = 'Usage: script.rb [options]'

        args.on('-p', '--project PROJECT', 'Project name (en.wikipedia)') { |v| @opts[:project] = v }
      end.parse!

      @opts[:lang] = @env == :test ? :en : @opts[:project].scan(/^\w\w/).first.to_sym
      I18n.load_path = Dir["#{PROJECT_ROOT}/dictionaries/*/*.yml"]
      I18n.backend.load_translations
      I18n.config.available_locales = @opts[:lang]
      I18n.locale = @opts[:lang]

      @gateway = MediaWiki::Gateway.new("https://#{@opts[:project]}.org/w/api.php",
        bot: true,
        retry_count: 5,
        user_agent: "MusikBot/1.1 (https://#{@opts[:project]}.org/wiki/User:MusikBot/)"
      )
      Auth.login(@gateway)

      unless @task == 'Console' || @opts[:prodonly] || @env == :test || get("User:MusikBot/#{@task}/Run") == 'true'
        report_error("#{@task} disabled")
        exit 1
      end
    end
    attr_reader :opts
    attr_reader :env
    attr_reader :gateway
    attr_reader :task

    def lang
      @opts[:lang]
    end

    # Utilities
    def now
      DateTime.now.new_offset(0)
    end

    def today
      now.to_date
    end

    def parse_date(obj, convert = false)
      if obj.is_a?(String)
        DateTime.parse(obj).new_offset(0)
      elsif obj.is_a?(DateTime)
        obj.new_offset(0)
      elsif convert
        obj.to_datetime
      else
        obj
      end
    end

    def wiki_date(date)
      I18n.l(parse_date(date, true), format: :wiki_time)
    end

    def api_date(date)
      parse_date(date).strftime('%Y-%m-%dT%H:%M:%SZ')
    end

    def db_date(date)
      parse_date(date).strftime('%Y%m%d000000')
    end

    # Database-related
    # FIXME: currently does enwiki-only
    def repl_client
      return @repl_client if @repl_client
      un, pw, host, db, port = Auth.db_credentials
      @repl_client = Repl::Session.new(un, pw, host, db, port)
    end

    # Redis-related
    def redis_client
      @redis_client ||= Auth.redis
    end

    def cache(base_key, time = 3600, &res)
      key = "ma-#{Digest::MD5.hexdigest(base_key.to_s)}"

      unless ret = redis_client.get(key)
        @redis_client.set(key, ret = res.call)
        @redis_client.expire(key, time)
      end

      ret
    end

    def disk_cache(filename, time = 3600, &res)
      filename = "#{PROJECT_ROOT}/disk_cache/#{filename}"
      if File.mtime(filename) < Time.now.utc - time
        ret = res.call

        cache_file = File.open(filename, 'r+')
        cache_file.write(ret.inspect)
        cache_file.close
      else
        ret = eval(File.open(filename).read)
      end

      ret
    end

    def local_storage(filename, opts)
      File.open("#{PROJECT_ROOT}/disk_cache/#{filename}", opts)
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
      @config ||= JSON.parse(CGI.unescapeHTML(get("User:MusikBot/#{@task}/config.js")))
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
      return fail if @env == :test

      opts = {
        contentformat: 'text/x-wiki',
        summary: "Reporting #{@task} errors"
      }
      page = "User:MusikBot/#{@task}/Error log"
      message = "\n*[~~~~~] #{message}"

      if e
        STDERR.puts "#{'>' * 20} #{DateTime.now.strftime('%Y-%m-%d %H:%M:%S')}"
        STDERR.puts "Error during processing: #{$ERROR_INFO}"
        STDERR.puts "Backtrace:\n\t#{e.backtrace.join("\n\t")}"
        message += " &mdash; in {{mono|#{e.backtrace_locations.first.label}}}: ''#{e.message}''"
      end

      content = get(page) + message
      @gateway.edit(page, content, opts) and return false
    end
  end
end
