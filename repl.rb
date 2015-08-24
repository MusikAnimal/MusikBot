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
      @baseUri = 'https://tools.wmflabs.org/musikanimal/api/nonautomated_edits'
    end

    def countArticlesCreated(userName)
      count("SELECT count(*) FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " +
        "WHERE rev_user_text = \"#{userName}\" AND rev_timestamp > 1 AND rev_parent_id = 0 " +
        "AND page_namespace = 0 AND page_is_redirect = 0;")
    end

    def countNamespaceEdits(userName, namespace = 0)
      namespaceStr = namespace.is_a?(Array) ? "IN (#{namespace.join(',')})" : "= #{namespace}"
      count("SELECT count(*) FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " +
        "WHERE rev_user_text = \"#{userName}\" AND page_namespace #{namespaceStr};")
    end

    def countNonAutomatedEdits(userName)
      @getter.get(@baseUri, {query: {
        username: userName,
        redirects: "on",
        moves: "on"
      }})["nonautomated_count"]
    end

    def countNonAutomatedNamespaceEdits(userName, namespace)
      @getter.get(@baseUri, {query: {
        username: userName,
        namespace: namespace,
        redirects: "on",
        moves: "on"
      }})["nonautomated_count"]
    end

    def countToolEdits(userName, tool)
      countAutomatedEdits(userName, false, tool)
    end

    def getArticlesCreated(userName)
      query = "SELECT page_title, rev_timestamp AS timestamp FROM #{@db}.page JOIN #{@db}.revision_userindex ON page_id = rev_page " +
        "WHERE rev_user_text = \"#{userName}\" AND rev_timestamp > 1 AND rev_parent_id = 0 " +
        "AND page_namespace = 0 AND page_is_redirect = 0;"
      puts query
      res = @client.query(query)
      articles = []
      res.each do |result|
        result["timestamp"] = DateTime.parse(result["timestamp"])
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