module Repl
  class Session
    require 'mysql2'
    require 'httparty'

    def initialize(opts)
      @logging = opts.delete(:log)
      @client = Mysql2::Client.new(opts)
      @db = opts[:db]
      @getter = HTTParty
      @base_uri = 'https://xtools.wmflabs.org/api/user'
    end

    def count_articles_created(username)
      count("SELECT count(*) FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " \
        "WHERE rev_user_text = \"#{escape(username)}\" AND rev_timestamp > 1 AND rev_parent_id = 0 " \
        'AND page_namespace = 0 AND page_is_redirect = 0;')
    end

    def count_namespace_edits(username, namespace = 0)
      namespace_str = namespace.is_a?(Array) ? "IN (#{namespace.join(',')})" : "= #{namespace}"
      count("SELECT count(*) FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " \
        "WHERE rev_user_text = \"#{escape(username)}\" AND page_namespace #{namespace_str};")
    end

    def count_nonautomated_edits(username)
      @getter.get(
        "#{@base_uri}/automated_editcount/en.wikipedia.org/#{URI.escape(username.score)}"
      )['nonautomated_editcount']
    end

    def count_nonautomated_namespace_edits(username, namespace)
      @getter.get(
        "#{@base_uri}/automated_editcount/en.wikipedia.org/#{URI.escape(username.score)}/#{namespace}"
      )['nonautomated_editcount']
    end

    def count_tool_edits(username, tool)
      countAutomatedEdits(username, false, tool)
    end

    def get_articles_created(username)
      sql = "SELECT page_title, rev_timestamp AS timestamp FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " \
        "WHERE rev_user_text = \"#{escape(username)}\" AND rev_timestamp > 1 AND rev_parent_id = 0 " \
        'AND page_namespace = 0 AND page_is_redirect = 0;'
      res = query(sql)
      articles = []
      res.each do |result|
        result['timestamp'] = DateTime.parse(result['timestamp'])
        articles << result
      end
      articles
    end

    def query(sql)
      puts sql if @logging
      @client.query(sql)
    end

    def prepare(sql)
      puts sql if @logging
      @client.prepare(sql)
    end

    def escape(string)
      @client.escape(string)
    end

    private

    def count(sql)
      query(sql).first.values[0].to_i
    end
  end
end
