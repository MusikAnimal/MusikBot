# {
#   45: {
#     prop: [old_value, new_value],
#     prop2: [old_value, new_value],
#     lasteditor: 'MusikAnimal',
#     lastedittime: '1970-01-01 00:00:00'
#   }
# }

# id            INTEGER
# filter_id     INTEGER
# actions       STRING
# lasteditor    STRING
# lastedittime  DATE
# deleted       BOOLEAN
# private       BOOLEAN

$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

NUM_DAYS = 7

module EditFilterMonitor
  def self.run
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

    net_changes = {}

    saved_filters.each_with_index do |saved_filter, index|
      sql = 'UPDATE filters SET '
      changed = false
      current_filter = normalize_data(current_filters[index].attributes)
      saved_filter = normalize_data(saved_filter)
      id = saved_filter['id'].to_s

      %w(actions enabled deleted private).each do |prop|
        # || 0 to account for nil when deleted/private are not in filter object
        old_value = saved_filter[prop]
        new_value = current_filter[prop]

        if old_value != new_value
          changed = true
          net_changes[id] ||= {}
          net_changes[id][prop] = [old_value, new_value]
          sql += "#{prop}='#{new_value}', "
        end
      end

      next unless changed

      binding.pry

      net_changes[id]['lasteditor'] = current_filter['lasteditor']
      net_changes[id]['lastedittime'] = DateTime.parse(current_filter['lastedittime']).strftime('%H:%M, %e %B %Y (UTC)')

      sql = "#{sql.chomp(', ')} WHERE filter_id = #{saved_filter['id']};"

      puts sql
      @client.query(sql)
    end

    content = ''
    if net_changes.length > 0
      net_changes.each do |filter_id, change_set|
        content += ";[[Special:AbuseFilter/#{filter_id}|Filter #{filter_id}]]\n"

        if actions = change_set['actions']
          content += "* Actions: #{actions[0]} &rarr; #{actions[1]}\n"
        end
        if enabled = change_set['enabled']
          content += "* Activity: #{enabled[0] == '1' ? 'unenabled &rarr; enabled' : 'enabled &rarr; disabled'}\n"
        end
        if deleted = change_set['deleted']
          content += "* Deletion: #{deleted[0] == '1' ? 'undeleted &rarr; deleted' : 'deleted &rarr; undeleted'}\n"
        end
        if privated = change_set['private']
          content += "* Privacy: #{privated[0] == '1' ? 'private &rarr; public' : 'public &rarr; private'}\n"
        end

        binding.pry

        content += "Last changed by {{no ping|#{change_set['lasteditor']}}} at #{change_set['lastedittime']}\n"
      end
    else
      content += "No changes to edit filters in the past #{NUM_DAYS} days.\n"
    end

    content += "\n([[User:MusikBot/FilterMonitor|More about this task]]) Regards ~~~~\n"

    binding.pry

    error('Failed to write to noticeboard') unless post_to_noticeboard(content, net_changes)
  end

  def self.current_filters
    return @current_filters if @current_filters

    opts = {
      list: 'abusefilters',
      abfprop: 'id|description|actions|lasteditor|lastedittime|status|private',
      abflimit: 1000
    }

    @current_filters = fetch_current_filters(opts)
  end

  def self.saved_filters
    @client.query('SELECT * FROM filters')
  end

  # API methods
  def self.fetch_current_filters(opts, throttle = 0)
    return false if throttle > 5

    begin
      sleep throttle * 5
      return @mw.custom_query(opts).elements['abusefilters']
    rescue MediaWiki::APIError
      return fetch_current_filters(opts, throttle + 1)
    end
  end

  def self.post_to_noticeboard(content, net_changes, throttle = 0)
    return false if throttle > 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: "Reporting recent changes to filters #{net_changes.keys.join(', ')}",
      section: 'new',
      sectiontitle: 'Recent filter changes',
      text: content
    }

    begin
      sleep throttle * 5
      @mw.edit('User:MusikBot/Edit filter noticeboard', CGI.unescapeHTML(content), opts)
    rescue MediaWiki::APIError
      binding.pry
      return post_to_noticeboard(content, net_changes, throttle + 1)
    end

    true
  end

  def self.create_table
    @client.query('CREATE TABLE filters (id INT PRIMARY KEY AUTO_INCREMENT, filter_id TINYINT, actions VARCHAR(255), ' \
    'lasteditor VARCHAR(255), lastedittime DATETIME, enabled TINYINT, deleted TINYINT, private TINYINT);')
  end

  def self.initial_import
    current_filters.each do |filter|
      attrs = filter.attributes
      # id, filter_id, actions, lasteditor, lastedittime, enabled, deleted, private
      puts sql = "INSERT INTO filters VALUES(NULL, #{attrs['id']}, '#{attrs['actions']}', '#{attrs['lasteditor'].gsub("'") { "\\'" }}', " \
        "'#{attrs['lastedittime'].gsub('Z', '')}', '#{attrs['enabled'] ? 1 : 0}', '#{attrs['deleted'] ? 1 : 0}', '#{attrs['private'] ? 1 : 0}');"
      @client.query(sql)
    end
  end

  def self.normalize_data(data)
    %w(enabled deleted private).each do |prop|
      if data[prop].nil?
        data[prop] = '0'
      else
        data[prop] = data[prop].to_s
        data[prop] = '1' if data[prop] == ''
      end
    end
    data
  end
end

EditFilterMonitor.run
