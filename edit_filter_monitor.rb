$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

NUM_DAYS = 7

class Object
  def present?
    !blank?
  end

  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

module EditFilterMonitor
  def self.run
    @mw = MediaWiki::Gateway.new('https://en.wikipedia.org/w/api.php', bot: true)
    Auth.login(@mw)

    env = eval(File.open('env').read)

    exit 1 unless @mw.get('User:MusikBot/FilterMonitor/Run') == 'true' || env == :test

    un, pw, host, db, port = Auth.ef_db_credentials(env)
    @client = Mysql2::Client.new(
      host: host,
      username: un,
      password: pw,
      database: db,
      port: port
    )

    changes = filter_changes
    generate_report(changes)
  end

  def self.filter_changes
    net_changes = {}

    current_filters.each_with_index do |current_filter, index|
      update_sql = 'UPDATE filters SET '
      current_filter = normalize_data(current_filter.attributes)
      saved_filter = normalize_data(saved_filters[index]) rescue {}
      id = current_filter['id'].to_s

      comparison_props.each do |prop|
        # || 0 to account for nil when deleted/private are not in filter object
        old_value = saved_filter[prop]
        new_value = current_filter[prop]

        next if old_value == new_value

        net_changes[id] ||= {}
        net_changes[id][prop] = [old_value, new_value]
        update_sql += "#{prop}='#{new_value}', "
      end

      next unless net_changes[id].present?

      net_changes[id]['lasteditor'] = current_filter['lasteditor']
      net_changes[id]['lastedittime'] = DateTime.parse(current_filter['lastedittime']).strftime('%H:%M, %e %B %Y (UTC)')

      if saved_filter.present?
        query("#{update_sql.chomp(', ')} WHERE filter_id = #{id};")
      else
        # new filter!
        net_changes[id]['new'] = true
        insert(current_filter)
      end
    end

    net_changes
  end

  def self.generate_report(net_changes)
    content = ''
    if net_changes.length > 0
      net_changes.each do |filter_id, change_set|
        new_str = change_set['new'] ? " '''(new)'''" : ''
        content += ";[[Special:AbuseFilter/#{filter_id}|Filter #{filter_id}]]#{new_str}\n"
        content += comparison_props.collect { |prop| entry_str(prop, change_set[prop]) }.join("\n").gsub(/^\n+/, '').gsub(/\n+$/, '')

        next unless config['lasteditor'] || config['lastedittime']

        content += "\n:Last changed"
        content += " by {{no ping|#{change_set['lasteditor']}}}" if config['lasteditor']
        content += " at #{change_set['lastedittime']}" if config['lastedittime']
        content += "\n"
      end
    else
      # XXX: issue report if there are no changes?
      content += "No changes to edit filters in the past #{NUM_DAYS} days.\n"
    end

    content += "\n~~~~\n"

    issue_report(content, net_changes)
  end

  def self.entry_str(type, changes)
    return '' unless changes
    before = changes[0]
    after = changes[1]

    case type
    when 'actions'
      title, keywords = 'Actions', [before.blank? ? '(none)' : before, after.blank? ? '(none)' : after]
    when 'description'
      title, keywords = 'Description', [before.blank? ? '(none)' : before, after.blank? ? '(none)' : after]
    when 'enabled'
      title, keywords = 'Activity', %w(enabled disabled)
    when 'deleted'
      title, keywords = 'Deletion', %w(deleted present)
    when 'private'
      title, keywords = 'Privacy', %w(public private)
    end

    keywords.reverse if after == '0'
    "* #{title}: " + (before.nil? ? keywords.last : "#{keywords.first} &rarr; #{keywords.last}\n")
  end

  def self.config
    @config ||= JSON.parse(CGI.unescapeHTML(@mw.get('User:MusikBot/FilterMonitor/config.js')))
  end

  def self.comparison_props
    config.select { |_k, v| v }.keys - %w(lasteditor lastedittime)
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
    @saved_filters ||= @client.query('SELECT * FROM filters').to_a
  end

  # API methods
  def self.fetch_current_filters(opts, throttle = 0)
    return false if throttle > 5

    begin
      sleep throttle * 5
      return @mw.custom_query(opts).elements['abusefilters']
    rescue MediaWiki::APIError => e
      binding.pry
      return fetch_current_filters(opts, throttle + 1)
    end
  end

  def self.issue_report(content, net_changes)
    # error('Failed to write to noticeboard') unless post_to_noticeboard(content, net_changes)
    error('Failed to write to template') unless update_template(content, net_changes)
  end

  # def self.post_to_noticeboard(content, net_changes)
  #   edit_page(@noticeboard_path, net_changes,
  #     text: content,
  #     section: 'new',
  #     sectiontitle: "Recent filter changes: #{Date.today.strftime('%e %B, %Y')}"
  #   )
  # end

  def self.update_template(content, net_changes)
    edit_page('User:MusikBot/FilterMonitor/Recent changes', net_changes, text: content)
  end

  def self.edit_page(page, changes, opts, throttle = 0)
    return false if throttle > 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: "Reporting recent changes to filters #{changes.keys.join(', ')}"
    }.merge(opts)

    begin
      sleep throttle * 5
      @mw.edit(page, CGI.unescapeHTML(opts[:text]), opts)
    rescue MediaWiki::APIError => e
      binding.pry
      return edit_page(page, changes, opts, throttle + 1)
    end

    true
  end

  def self.create_table
    query('CREATE TABLE filters (id INT PRIMARY KEY AUTO_INCREMENT, filter_id INT, description VARCHAR(255), actions VARCHAR(255), ' \
    'lasteditor VARCHAR(255), lastedittime DATETIME, enabled TINYINT, deleted TINYINT, private TINYINT);')
  end

  def self.initial_import
    current_filters.each do |filter|
      attrs = filter.attributes
      insert(attrs)
    end
  end

  def self.insert(obj)
    # id, filter_id, actions, lasteditor, lastedittime, enabled, deleted, private
    query("INSERT INTO filters VALUES(NULL, #{obj['id']}, '#{obj['description'].gsub("'") { "\\'" }}', '#{obj['actions']}', '#{obj['lasteditor'].gsub("'") { "\\'" }}', " \
      "'#{obj['lastedittime'].gsub('Z', '')}', '#{attr_value(obj['enabled'])}', '#{attr_value(obj['deleted'])}', '#{attr_value(obj['private'])}');")
  end

  def self.query(sql)
    puts sql
    @client.query(sql)
  end

  def self.attr_value(value)
    value == '' || value == '1' ? '1' : '0'
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
