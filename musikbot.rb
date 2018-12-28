require 'optparse'
require 'i18n'
require 'mediawiki-gateway'
require 'redis'
require 'mysql2'
require 'repl'
require 'httparty'
require 'core_extensions'
require 'uri'
require 'pry-byebug'

module MusikBot
  class Session
    def initialize(task, prodonly = false)
      @task = task
      @opts = {
        prodonly: prodonly,
        project: env == 'test' && !prodonly ? 'test.wikipedia' : 'en.wikipedia',
        edition: 1
      }
      OptionParser.new do |args|
        args.banner = 'Usage: script.rb [options]'

        args.on('-p', '--project PROJECT', 'Project name (en.wikipedia)') { |v| @opts[:project] = v }
        args.on('-db', '--database DATABASE', 'Database name (enwiki)') { |v| @opts[:database] = v }
        args.on('-l', '--lang LANGUAGE', 'Language code (en)') { |v| @opts[:lang] = v.to_sym }
        args.on('-b', '--nobot', 'Don\'t assert as bot') { @opts[:nobot] = true }
        args.on('-e', '--env ENVIRONMENT', 'production to use specified wiki, or test to use testwiki')
        args.on('-f', '--edition EDITION', '1 for MusikBot, 2 for MusikBot II, etc.') { |v| @opts[:edition] = v }
        args.on('-d', '--dry', 'pass to disable all editing and instead invoke debugger') { @opts[:dry] = true }
      end.parse!

      unless @opts[:lang]
        @opts[:lang] = env == 'test' ? :en : @opts[:project].scan(/^\w\w/).first.to_sym
      end

      I18n.load_path = Dir[dir('dictionaries/*/*.yml')]
      I18n.backend.load_translations
      I18n.config.available_locales = [:en, :fr, :pt, :it]
      I18n.locale = @opts[:lang]

      login

      unless @task =~ /Console|SoundSearch/ || @opts[:prodonly] || env == 'test' || get("User:#{username}/#{@task}/Run") == 'true'
        report_error("#{@task} disabled")
        exit 1
      end
    end
    attr_reader :opts
    attr_reader :task

    def environment
      @environment ||= app_config[:environment]
    end
    alias_method :env, :environment

    def lang
      @opts[:lang]
    end

    def database
      return 'testwiki' if env == 'test'
      @opts[:database].present? ? @opts[:database] : "#{lang}wiki"
    end

    def bot?
      bot_blacklist = ['fr.wikipedia']
      !bot_blacklist.include?(@opts[:project]) && !@opts[:nobot]
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

    # HTTParty getter
    def http_get(base_uri, params)
      @getter ||= HTTParty
      @getter.get(base_uri, params)
    end

    # Wiki-tools
    def wiki_tools(tool, query)
      @getter ||= HTTParty
      base_uri = "https://tools.wmflabs.org/musikanimal/api/#{tool}"
      @getter.get(base_uri, query: query)
    end

    # Database-related
    def repl_client(opts = {})
      opts = {
        reload: false,
        database: nil,
        credentials: :replica,
        log: true,
        replicas: true
      }.merge(opts)
      return @repl_client if @repl_client && !opts.delete(:reload)
      suffix = opts.delete(:replicas) ? '_p' : ''
      @repl_client = Repl::Session.new(
        { database: opts[:database] || db + suffix }.merge(app_config[opts[:credentials]])
      )
    end
    alias_method :repl, :repl_client

    def local_client(db, reload = false)
      return @local_client if @local_client && !reload
      @local_client = Mysql2::Client.new(
        app_config[:local].merge(database: db)
      )
    end

    def site_map
      @site_map ||= YAML.load(
        File.open(dir('config/site_map.yml')).read
      )
    end

    def db
      site_map[@opts[:project].sub(/^www./, '')]
    end

    def repl_query(sql, *values)
      statement = repl_client.prepare(sql)
      statement.execute(*values)
    end

    # Cache-related
    def redis_client
      @redis_client ||= Redis.new(app_config[:redis])
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
      filename = dir("disk_cache/#{filename}.yml")

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
      filename = dir("disk_cache/#{@task}.yml")

      if data
        file = File.open(filename, 'w')
        file.write(YAML.dump(data))
        file.close
      else
        YAML.load(
          File.open(filename, 'r').read
        )
      end
    end

    # API-related
    def gateway
      @gateway ||= MediaWiki::Gateway.new("https://#{@opts[:project]}.org/w/api.php",
        bot: bot?,
        retry_count: 5,
        user_agent: "#{username}/1.1 (https://#{@opts[:project]}.org/wiki/User:#{username}/)",
        ignorewarnings: true
      )
    end

    def get(page, opts = {})
      gateway.get(page, opts)
    end

    def edit(page, opts = {})
      return binding.pry if @opts[:dry]
      opts.merge(contentformat: 'text/x-wiki')
      if opts.delete(:conflicts)
        opts.merge!(
          basetimestamp: @base_timestamp,
          starttimestamp: @start_timestamp
        )
      end

      gateway.edit(page, opts.delete(:content), opts)
    end

    def config
      @config ||= JSON.parse(CGI.unescapeHTML(get("User:#{username}/#{@task}/config"))).symbolize_keys
    end

    def get_revision_at_date(page, date, opts = {})
      full_response = opts.delete(:full_response)
      deleted = opts.delete(:deleted)

      if deleted
        opts = {
          prop: 'deletedrevisions',
          drvprop: 'content',
          titles: page,
          drvstart: api_date(date),
          drvlimit: 1
        }.merge(opts)
      else
        opts = {
          prop: 'revisions',
          rvprop: 'content',
          titles: page,
          rvstart: api_date(date),
          rvlimit: 1
        }.merge(opts)
      end

      page_obj = gateway.custom_query(opts).elements['pages'][0]

      return nil if page_obj.nil?

      if full_response
        page_obj
      elsif deleted
        rev = page_obj.elements['deletedrevisions/rev']
        opts[:drvprop] == 'content' ? rev.text : rev
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

      page_obj = gateway.custom_query(opts).elements['pages'][0]
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
      page = "User:#{username}/#{@task}/Error log"

      if e
        STDERR.puts "#{'>' * 20} #{DateTime.now.strftime('%Y-%m-%d %H:%M:%S')}"
        STDERR.puts "Error during processing: #{$ERROR_INFO}"
        STDERR.puts "Backtrace:\n\t#{e.backtrace.join("\n\t")}"
        message += " &mdash; in <code>#{e.backtrace_locations.first.label}</code>: ''#{e.message}''"
      end

      content = get(page) || ''
      content.sub!(content.scan(/.*\n/).first, '') if content.length > 10_000

      last_timestamp, last_message = content.split(/\[(.*?)\] /).last(2)
      if last_message != message || parse_date(last_timestamp) < today - 1
        message = "\n*[~~~~~] #{message}"
        gateway.edit(page, content + message, opts)
      end

      false
    end

    def username
      app_config[:api][:"edition_#{@opts[:edition]}"][:wiki_user]
    end

    private

    def dir(path = '')
      File.dirname(__FILE__) + '/' + path
    end

    def app_config
      @app_config ||= YAML.load(
        File.open(
          dir('config/application.yml')
        ).read
      ).symbolize_keys
    end

    def login(throttle = 0)
      return if throttle > 5
      sleep throttle * 5
      gateway.login(
        app_config[:api][:"edition_#{@opts[:edition]}"][:username],
        app_config[:api][:"edition_#{@opts[:edition]}"][:password]
      )
    rescue MediaWiki::APIError
      mw.login(throttle + 1)
    end
  end
end
