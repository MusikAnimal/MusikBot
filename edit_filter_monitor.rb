# {
#   45: {
#     prop: [old_value, new_value],
#     prop2: [old_value, new_value]
#   }
# }

$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

module EditFilterMonitor
  def self.init
    @mw = MediaWiki::Gateway.new('https://en.wikipedia.org/w/api.php', bot: true)
    Auth.login(@mw)

    env = eval(File.open('env').read)
    un,pw,host,db,port = Auth.ef_db_credentials(env)

    @client = Mysql2::Client.new(
      host: host,
      username: un,
      password: pw,
      database: db,
      port: port
    )

    binding.pry

    changes = []

    sql = 'UPDATE filters SET '

    saved_filters.each_with_index do |saved_filter, index|
      saved_filter.keys.each do |prop|
        old_value = saved_filter[prop]
        new_value = current_filters[index][prop]
        if old_value != new_value
          changes[saved_filter[:id].to_s] ||= {}
          changes[saved_filter[:id].to_s][prop] = [old_value, new_value]
          sql += "#{prop}=#{new_value}, "
        end
      end

      sql.chomp(', ')
      sql += " WHERE filter_id = #{saved_filter[:id]}"

      @client.sql(sql)
    end

    content = ''
    if changes.length
      changes.each do |filter_id, change_set|
        content += ";[[Special:AbuseFilter/#{filter_id}|Filter #{filter_id}]]\n"
        change_set.keys.each do |prop|
          old_value = change_set[prop][0]
          new_value = change_set[prop][1]
          content += "* '''#{prop}''': #{old_value} &rarr; #{new_value}\n"
        end
      end
    else
      content += "Nothing for this week\n"
    end

    content += "([[User:MusikBot/FilterMonitor|More about this task]]) Regards ~~~~\n"

    opts = {
      contentformat: 'text/x-wiki',
      summary: "Posting filter changes for week ending in #{Date.today}",
      section: 'new',
      sectiontitle: "Filter changes for week #{Date.today}",
      text: content
    }
    @mw.edit('Wikipedia:Edit filter noticeboard', CGI.unescapeHTML(content), opts)
  end

  def self.current_filters
    return @current_filters if @current_filters

    opts = {
      list: 'abusefilters',
      abfprop: 'id|description|actions|lasteditor|lastedittime|status|private',
      abflimit: 1000
    }

    @current_filters = @mw.custom_query(opts).elements['abusefilters']
  end

  def self.saved_filters
    # retrun save filters
  end
end

EditFilterMonitor.init
