$LOAD_PATH << '.'
require 'musikbot'
require 'mysql2'

NUM_DAYS = 5

module FilterMonitor
  def self.run
    @mb = MusikBot::Session.new(inspect)
    un, pw, host, db, port = Auth.ef_db_credentials(eval(File.open('env').read), @mb.lang)
    @client = Mysql2::Client.new(
      host: host,
      username: un,
      password: pw,
      database: db,
      port: port
    )

    @template_name = "#{i18n('User')}:MusikBot/FilterMonitor/#{i18n('Recent changes')}"

    changes = filter_changes
    generate_report(changes) if changes.any?
  rescue => e
    @mb.report_error(i18n('Fatal error'), e)
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
        changes['new'] = i18n('new')
        insert(current_filter)
      end

      net_changes << changes unless current_filter['private'] == '1' && @mb.config['private'] == false
    end

    net_changes
  end

  def self.generate_report(new_templates_data)
    old_templates = fetch_old_templates
    new_templates = []
    @edit_summaries = {}

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

    unless write_template(@template_name, content, @edit_summaries)
      @mb.report_error(i18n('Failed to write to template'))
    end
  end

  def self.template(data)
    content = "'''[[#{i18n('Special:AbuseFilter')}/#{data['filter_id']}|#{i18n('Filter')} #{data['filter_id']}]]#{' (' + data['new'] + ')' if data['new']}''' &mdash; "
    @edit_summaries[data['filter_id']] = []
    %w(actions flags pattern).each do |prop|
      next if data[prop].blank? || prop == 'deleted'

      if prop == 'pattern'
        content += "#{i18n('Pattern modified')}; "
      else
        value = data[prop].sort.map { |v| i18n(v) }.join(',')
        value.sub!(i18n('disallow'), "<span style='color:red;font-weight:bold'>#{i18n('disallow')}</span>")
        value = value.blank? ? "(#{i18n('none')})" : value
        content += "#{i18n(prop.capitalize_first)}: #{value}; "
      end
      @edit_summaries[data['filter_id']] << i18n(prop.uncapitalize)
    end
    content.chomp!('; ')

    return unless @mb.config['lasteditor'] || @mb.config['lastedittime']

    content += "\n:#{i18n('Last public change')}"
    content += " #{i18n('by')} {{no ping|#{data['lasteditor']}}}" if @mb.config['lasteditor']
    content += " #{i18n('at')} #{data['lastedittime']}" if @mb.config['lastedittime']
  end

  def self.parse_template(template)
    data = {}
    data['filter_id'] = template.scan(/#{i18n('AbuseFilter')}\/(\d+)\|/).flatten[0]
    data['new'] = template.scan(/\((\w+)\)''' &mdash;/).flatten[0] rescue nil
    data['pattern'] = template =~ /#{i18n('Pattern modified')}/ ? true : nil
    data['lasteditor'] = template.scan(/no ping\|(.*+)}}/).flatten[0] rescue nil
    data['lastedittime'] = template.scan(/(\d\d:\d\d.*\d{4} \(UTC\))/).flatten[0] rescue nil
    data['actions'] = template.scan(/#{i18n('Actions')}: (.*?)[;\n]/).flatten[0].split(',') rescue []
    data['flags'] = template.scan(/#{i18n('Flags')}: (.*?)[;\n]/).flatten[0].split(',') rescue []

    data
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

  def self.comparison_props
    @mb.config.select { |_k, v| v }.keys - %w(lasteditor lastedittime)
  end

  def self.current_filters
    return @current_filters if @current_filters

    opts = {
      list: 'abusefilters',
      abfprop: 'id|description|actions|pattern|lasteditor|lastedittime|status|private',
      abflimit: 1000
    }

    @current_filters = @mb.gateway.custom_query(opts).elements['abusefilters']
  end

  def self.saved_filters
    @saved_filters ||= @client.query('SELECT * FROM filters').to_a
  end

  # API methods
  def self.fetch_old_templates
    filters = @mb.get(@template_name).split(/^'''/).drop(1).map { |f| "'''#{f.rstrip}" }
    filters.keep_if { |f| DateTime.parse(f.scan(/(\d\d:\d\d.*\d{4} \(UTC\))/).flatten[0]) > DateTime.now - NUM_DAYS }
  end

  def self.write_template(page, content, summaries)
    edit_summary = ''
    summaries.keys.each do |f|
      edit_summary += "[[#{i18n('Special:AbuseFilter')}/#{f}|#{f}]]" + (summaries[f].any? ? " (#{summaries[f].join(', ')})" : '') + '; '
    end

    opts = {
      summary: "#{i18n('Reporting recent changes to filters')} #{edit_summary.chomp('; ')}",
      content: content,
      bot: false
    }
    @mb.edit(page, opts)
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
    # id, filter_id, description, actions, pattern, lasteditor, lastedittime, enabled, deleted, private
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

  # i18n
  def self.i18n(str)
    return str if @mb.lang == 'en'
    res = i18n_hash[str.clone.capitalize_first]
    str.capitalized? ? res.capitalize_first : res.uncapitalize
  end

  def self.i18n_hash
    case @mb.lang
    when 'pt'
      {
        'AbuseFilter' => 'Filtro de abusos',
        'Actions' => 'Ações',
        'At' => 'em',
        'By' => 'por',
        'Description' => 'Descrição',
        'Disallow' => 'não autorizar',
        'Disabled' => 'desabilitado',
        'Enabled' => 'ativado',
        'Failed to write to template' => 'Falha ao gravar no modelo',
        'Fatal error' => 'Erro fatal',
        'Filter' => 'Filtro',
        'Flags' => 'Sinalizações',
        'Last public change' => 'Última alteração público',
        'Modified' => 'modificada',
        'New' => 'novo',
        'None' => 'nenhum',
        'Pattern' => 'Padrão',
        'Pattern modified' => 'Padrão modificado',
        'Privacy' => 'Privacidade',
        'Recent changes' => 'Modificações recentes',
        'Reporting recent changes to filters' => 'Relatórios recentes alterações para filtros',
        'Special:AbuseFilter' => 'Especial:Filtro de abusos',
        'Tag' => 'etiquetar',
        'Throttle' => 'limitador',
        'User' => 'Usuário(a)',
        'Warn' => 'avisar'
      }
    end
  end
end

FilterMonitor.run
