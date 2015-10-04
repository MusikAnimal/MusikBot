module Repl
  class Session
    require 'mysql2'
    require 'httparty'

    def initialize(username, password, host, db, port)
      @client = Mysql2::Client.new(
        host: host,
        username: username,
        password: password,
        database: db,
        port: port
      )
      @db = db
      @getter = HTTParty
      @base_uri = 'https://tools.wmflabs.org/musikanimal/api/nonautomated_edits'
    end

    def count_articles_created(username)
      count("SELECT count(*) FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " \
        "WHERE rev_user_text = \"#{username}\" AND rev_timestamp > 1 AND rev_parent_id = 0 " \
        'AND page_namespace = 0 AND page_is_redirect = 0;')
    end

    def count_namespace_edits(username, namespace = 0)
      namespace_str = namespace.is_a?(Array) ? "IN (#{namespace.join(',')})" : "= #{namespace}"
      count("SELECT count(*) FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " \
        "WHERE rev_user_text = \"#{username}\" AND page_namespace #{namespace_str};")
    end

    def count_nonautomated_edits(username)
      @getter.get(@base_uri, query: {
        username: username,
        redirects: 'on',
        moves: 'on'
      })['nonautomated_count']
    end

    def count_nonautomated_namespace_edits(username, namespace)
      @getter.get(@base_uri, query: {
        username: username,
        namespace: namespace
      })['nonautomated_count']
    end

    def count_tool_edits(username, tool)
      countAutomatedEdits(username, false, tool)
    end

    def get_articles_created(username)
      query = "SELECT page_title, rev_timestamp AS timestamp FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " \
        "WHERE rev_user_text = \"#{username}\" AND rev_timestamp > 1 AND rev_parent_id = 0 " \
        'AND page_namespace = 0 AND page_is_redirect = 0;'
      puts query
      res = @client.query(query)
      articles = []
      res.each do |result|
        result['timestamp'] = DateTime.parse(result['timestamp'])
        articles << result
      end
      articles
    end

    private

    def count(query)
      puts query
      @client.query(query).first.values[0].to_i
    end
  end
end
