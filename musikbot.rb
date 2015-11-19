require 'auth'
require 'repl'

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

module MusikBot
  class Session
    def initialize(task)
      @task = task

      env = eval(File.open('env').read)
      @gateway = MediaWiki::Gateway.new("https://#{env == :production ? 'en' : 'test'}.wikipedia.org/w/api.php", bot: true)
      Auth.login(@gateway)

      exit 1 unless env == :test || api_get("User:MusikBot/#{@task}/Run") == 'true'
    end
    attr_reader :gateway

    # Utilities
    def today
      DateTime.now.new_offset(0).to_date
    end

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

    def get_page_props(page, opts)
      full_response = opts.delete(:full_response)

      opts = {
        prop: 'info|revisions',
        rvprop: 'timestamp|content',
        titles: page
      }.merge(opts)

      page_obj = @gateway.custom_query(opts).elements['pages'][0]
      unless page_obj.elements['revisions']
        report_error("Unable to fetch properties of [[#{page}]] - page does not exist!")
      end

      @start_timestamp = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      @base_timestamp = page_obj.elements['revisions'][0].attributes['timestamp']
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
        summary: 'Reporting TAFIWeekly errors'
      }
      page = "User:MusikBot/#{@task}/Error log"
      message = "\n*[~~~~~] #{message} – in {{mono|#{e.backtrace_locations.first.label}}}: ''#{e.message}''"
      content = get(page) + message

      if e
        STDERR.puts "Error during processing: #{$ERROR_INFO}"
        STDERR.puts "Backtrace:\n\t#{e.backtrace.join("\n\t")}"
      end

      @gateway.edit(page, content, opts) and return false
    end
  end
end
