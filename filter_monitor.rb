$LOAD_PATH << '.'
require 'mysql2'
require 'mediawiki-gateway'
require 'auth.rb'
require 'date'
require 'pry-byebug'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'

NUM_DAYS = 5
TEMPLATE = 'User:MusikBot/FilterMonitor/Recent changes'

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
    generate_report(changes) if changes.any?
  rescue => e
    if env == :test
      raise e
    else
      report_error(e.message)
    end
  end

  def self.filter_changes
    net_changes = []

    current_filters.each_with_index do |current_filter, index|
      current_filter = normalize_data(current_filter.attributes, true)
      saved_filter = normalize_data(saved_filters[index]) rescue {}
      update_sql = ''
      id = current_filter['id'].to_s
      changes = {}

      comparison_props.each do |prop|
        old_value = saved_filter[prop]
        new_value = current_filter[prop]

        next if old_value == new_value

        if prop == 'deleted' && new_value == '0'
          changes['new'] = 'restored'
        elsif prop == 'deleted' && new_value == '1'
          changes['new'] = 'deleted'
        elsif prop == 'actions'
          changes['actions'] = keyword_from_value(prop, new_value).split(',')
        elsif prop == 'pattern'
          changes['pattern'] = true
        else
          changes['flags'] ||= []
          changes['flags'] << keyword_from_value(prop, new_value)
        end

        update_sql += "#{prop}='#{new_value}', "
      end

      next if changes.empty?

      changes['filter_id'] = current_filter['id']
      changes['lasteditor'] = current_filter['lasteditor']
      changes['lastedittime'] = DateTime.parse(current_filter['lastedittime']).strftime('%H:%M, %e %B %Y (UTC)')

      if saved_filter.present?
        query("UPDATE filters SET #{update_sql.chomp(', ')} WHERE filter_id = #{id};")
      else
        changes['new'] = 'new'
        insert(current_filter)
      end

      net_changes << changes
    end

    net_changes
  end

  def self.generate_report(new_templates_data)
    old_templates = fetch_old_templates
    new_templates = []

    # merge duplicate reports
    new_templates_data.each do |data|
      old_data = {}
      old_templates.delete_if do |ot|
        otd = parse_template(ot)
        old_data = otd if otd['filter_id'] == data['filter_id']
      end
      # join arrays
      old_data['actions'] = (data['actions'] || []) | (old_data['actions'] || [])
      old_data['flags'] = (data['flags'] || []) | (old_data['flags'] || [])
      new_templates << template(old_data.merge(data))
    end

    new_templates += old_templates

    content = new_templates.join("\n\n")

    report_error('Failed to write to template') unless edit_page(TEMPLATE, content, new_templates_data.collect { |ntd| ntd['filter_id'] })
  end

  def self.template(data)
    content = "'''[[Special:AbuseFilter/#{data['filter_id']}|Filter #{data['filter_id']}]]#{' (' + data['new'] + ')' if data['new']}''' &mdash; "
    %w(actions flags pattern).each do |prop|
      next if data[prop].blank? || prop == 'deleted'

      if prop == 'pattern'
        content += "#{humanize_prop(prop)} modified; "
      else
        value = data[prop].sort.join(',')
        content += "#{prop.capitalize}: #{value == '' ? '(none)' : value}; "
      end
    end
    content.chomp!('; ')

    return unless config['lasteditor'] || config['lastedittime']

    content += "\n:Last public change"
    content += " by {{no ping|#{data['lasteditor']}}}" if config['lasteditor']
    content += " at #{data['lastedittime']}" if config['lastedittime']
  end

  def self.parse_template(template)
    data = {}
    data['filter_id'] = template.scan(/AbuseFilter\/(\d+)\|/).flatten[0]
    data['new'] = template.scan(/\((\w+)\)''' &mdash;/).flatten[0] rescue nil
    data['pattern'] = template =~ /Pattern modified/ ? true : nil
    data['lasteditor'] = template.scan(/no ping\|(.*+)}}/).flatten[0] rescue nil
    data['lastedittime'] = template.scan(/(\d\d:\d\d.*\d{4} \(UTC\))/).flatten[0] rescue nil
    data['actions'] = template.scan(/Actions: (.*?)[;\n]/).flatten[0].split(',') rescue []
    data['flags'] = template.scan(/Flags: (.*?)[;\n]/).flatten[0].split(',') rescue []

    data
  end

  def self.humanize_prop(prop, dehumanize = false)
    props = {
      'actions' => 'Actions',
      'pattern' => 'Pattern',
      'description' => 'Description',
      'enabled' => 'State',
      'deleted' => 'Deleted',
      'private' => 'Privacy'
    }
    props = props.invert if dehumanize
    props[prop]
  end

  def self.dehumanize_prop(prop)
    humanize_prop(prop, true)
  end

  def self.keyword_from_value(prop, value)
    case prop
    when 'actions'
      value.blank? ? '(none)' : value
    when 'pattern'
      value
    when 'description'
      value
    when 'enabled'
      value == '1' ? 'enabled' : 'disabled'
    # when 'deleted'
    #   value == '1' ? 'deleted' : 'restored'
    when 'private'
      value == '1' ? 'private' : 'public'
    end
  end

  def self.value_from_keyword(prop, value)
    case prop
    when 'actions'
      value == '(none)' ? '' : value
    when 'description'
      value
    when 'enabled'
      value == 'enabled' ? '1' : '0'
    when 'deleted'
      value == 'deleted' ? '1' : '0'
    when 'private'
      value == 'private' ? '1' : '0'
    end
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
      abfprop: 'id|description|actions|pattern|lasteditor|lastedittime|status|private',
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
    sleep throttle * 5
    return @mw.custom_query(opts).elements['abusefilters']
  rescue MediaWiki::APIError
    return fetch_current_filters(opts, throttle + 1)
  end

  def self.fetch_old_templates(throttle = 0)
    return false if throttle > 5
    sleep throttle * 5
    filters = @mw.get(TEMPLATE).split(/^'''/).drop(1).map { |f| "'''#{f.rstrip}" }
    return filters.keep_if { |f| DateTime.parse(f.scan(/(\d\d:\d\d.*\d{4} \(UTC\))/).flatten[0]) > DateTime.now - NUM_DAYS }
  rescue MediaWiki::APIError
    return old_templates(throttle + 1)
  end

  def self.edit_page(page, content, filter_ids, throttle = 0)
    return false if throttle > 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: "Reporting recent changes to filters #{filter_ids.join(', ')}",
      text: content
    }

    begin
      sleep throttle * 5
      @mw.edit(page, CGI.unescapeHTML(content), opts)
    rescue MediaWiki::APIError
      return edit_page(page, content, filter_ids, throttle + 1)
    end

    true
  end

  def self.report_error(message, throttle = 0)
    return if throttle > 5
    sleep throttle * 5

    opts = {
      contentformat: 'text/x-wiki',
      summary: 'Reporting FilterMonitor errors'
    }

    @mw.edit('User:MusikBot/FilterMonitor/Error log', message + " ~~~~~\n\n", opts)
  rescue MediaWiki::APIError
    report_error(message, throttle + 1)
  end

  # Database related stuff
  def self.create_table
    query('CREATE TABLE filters (id INT PRIMARY KEY AUTO_INCREMENT, filter_id INT, description VARCHAR(255), actions VARCHAR(255), ' \
    'pattern VARCHAR(255), lasteditor VARCHAR(255), lastedittime DATETIME, enabled TINYINT, deleted TINYINT, private TINYINT);')
  end

  def self.initial_import
    current_filters.each do |filter|
      attrs = normalize_data(filter.attributes, true)
      insert(attrs)
    end
  end

  def self.insert(obj)
    # id, filter_id, actions, lasteditor, lastedittime, enabled, deleted, private
    query("INSERT INTO filters VALUES(NULL, #{obj['id']}, '#{obj['description']}', '#{obj['actions']}', " \
      "'#{obj['pattern']}', '#{obj['lasteditor']}', '#{obj['lastedittime'].gsub('Z', '')}', "\
      "'#{attr_value(obj['enabled'])}', '#{attr_value(obj['deleted'])}', '#{attr_value(obj['private'])}');")
  end

  def self.query(sql)
    puts sql
    @client.query(sql)
  end

  def self.attr_value(value)
    value == '' || value == '1' ? '1' : '0'
  end

  def self.normalize_data(data, digest = false)
    %w(enabled deleted private).each do |prop|
      if data[prop].nil?
        data[prop] = '0'
      else
        data[prop] = data[prop].to_s
        data[prop] = '1' if data[prop] == ''
      end
    end

    if digest
      %w(description lasteditor).each do |prop|
        data[prop] = @client.escape(data[prop].to_s)
      end
      data['pattern'] = Digest::MD5.hexdigest(data['pattern']) rescue ''
    end

    data
  end
end

EditFilterMonitor.run
