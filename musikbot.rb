require 'mediawiki-gateway'
require 'auth'
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

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

module MusikBot
  class Session
    def initialize(task, prodonly = false)
      @task = task

      @env = eval(File.open('env').read)
      @gateway = MediaWiki::Gateway.new("https://#{@env == :production || prodonly ? 'en' : 'test'}.wikipedia.org/w/api.php", bot: true)
      Auth.login(@gateway)

      unless task == 'Console' || @env == :test || get("User:MusikBot/#{@task}/Run") == 'true'
        report_error("#{@task} disabled")
        exit 1
      end
    end
    attr_reader :env
    attr_reader :gateway
    attr_reader :task

    # Utilities
    def today
      DateTime.now.new_offset(0).to_date
    end
    alias_method :now, :today

    # Database-related
    def repl_client
      return @repl_client if @repl_client
      un, pw, host, db, port = Auth.db_credentials(@env)
      @repl_client = Repl::Session.new(un, pw, host, db, port)
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

      @gateway.edit(page, CGI.unescapeHTML(opts.delete(:content)), opts)
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
        rvstart: date.strftime('%Y-%m-%dT%H:%M:%SZ'),
        rvlimit: 1
      }.merge(opts)

      page_obj = @gateway.custom_query(opts).elements['pages'][0]

      if full_response
        page_obj
      else
        page_obj.elements['revisions'][0][0].to_s
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
        page_obj.elements['revisions'][0][0].to_s
      end
    end
    attr_reader :base_timestamp
    attr_reader :start_timestamp

    def report_error(message, e = nil)
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
