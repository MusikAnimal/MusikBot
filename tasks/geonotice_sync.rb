$LOAD_PATH << '..'
require 'musikbot'
require 'countries'

module GeonoticeSync
  def self.run
    @mb = MusikBot::Session.new(inspect)

    @config_page = @mb.config[:config_page]
    @geonotice_page = @mb.config[:geonotice_page]
    @report_page = "#{t('User')}:MusikBot II/GeonoticeSync/Report"
    @errors = []

    synced_at = @mb.parse_date(@mb.local_storage['synced'])

    @current_edit = @mb.gateway.custom_query(
      titles: @config_page,
      prop: 'revisions',
      rvprop: 'ids|timestamp|content',
      rvslots: '*'
    ).elements['pages'][0].elements['revisions'][0]

    return if synced_at > @mb.parse_date(@current_edit.attributes['timestamp'])

    begin
      success = sync
    rescue => e
      @errors << {
        group: I18n.t('errors.fatal'),
        message: I18n.t('errors.fatal_msg',
          log_page: "#{t('User')}:MusikBot II/GeonoticeSync/Error log"
        )
      }
      generate_report
      raise e
    end

    if success
      @mb.local_storage(
        'last_revid' => @current_edit.attributes['revid'],
        'synced' => @mb.now.to_s
      )
    end

    generate_report
  rescue => e
    @mb.report_error(t('Fatal error'), e)
  end

  def self.validate(json)
    valid = true

    json.each do |title, config|
      # Keys
      if (config.keys - %w(begin end country text corners)).any?
        add_error(title, I18n.t('geonotice.errors.keys'))
        valid = false
      end
      if config['country'].present? && config['corners'].present?
        add_error(title, I18n.t('geonotice.errors.coords_country'))
        valid = false
      end

      # Text
      if config['text'].blank?
        add_error(title, I18n.t('geonotice.errors.text'))
        valid = false
      end

      # Dates
      %w(begin end).each do |field|
        if (Date.parse(config['begin']) rescue nil).nil?
          add_error(title, I18n.t('geonotice.errors.date', field: "<code>#{field}</code>"))
          valid = false
        end
      end

      # Country
      if config['country'].present? && ISO3166::Country.new(config['country']).nil?
        add_error(title, I18n.t('geonotice.errors.country', country: config['country']))
        valid = false
      end

      # Corners
      if config['corners'].present? && validate_corners(title, config['corners']) == false
        valid = false
      end
    end

    valid
  end

  def self.validate_corners(title, corners)
    if corners.length != 2
      add_error(title, I18n.t('geonotice.errors.corners.length', field: '<code>corners</code>'))
      return false
    else
      corners.each do |corner|
        if corner.length != 2
          add_error(title, I18n.t('geonotice.errors.corners.coord_length', field: '<code>corners</code>'))
          return false
        end

        if !corner[0].is_a?(Float) || !corner[1].is_a?(Float)
          add_error(title, I18n.t('geonotice.errors.corners.numeric', field: '<code>corners</code>'))
          return false
        end
      end
    end

    true
  end

  def self.add_error(title, msg, type = 'syntax')
    @errors << {
      group: I18n.t("geonotice.errors.#{type}"),
      message: "(#{title}) " + msg
    }
  end

  def self.sync
    json = JSON.parse(@mb.get(@config_page))

    return false unless validate(json)

    comment = @mb.get(@geonotice_page).scan(/(\/\*.*?\*\/)/m).flatten[0]
    content = "#{comment}\n\nwindow.GeoNotice = {};\nwindow.GeoNotice.notices = " + JSON.pretty_generate(json) + ';'

    @mb.edit(@geonotice_page,
      content: content,
      summary: I18n.t('geonotice.sync_summary',
        link: "[[Special:Diff/#{@mb.local_storage['last_revid']}/#{@current_edit.attributes['revid']}|#{@config_page}]]"
      )
    )

    true
  rescue JSON::ParserError
    @errors << {
      group: I18n.t('geonotice.parser').upcase,
      message: I18n.t('geonotice.errors.parser', config_page: @config_page)
    }
    false
  end

  # Work in progress...
  def self.generate_report
    content = ''

    if @errors.any?
      content = "<div style='color:red;font-weight:bold'>#{I18n.t('geonotice.errors.num_errors', num: @errors.length)}</div>\n"

      @errors.each do |error|
        content += "* <span style='font-weight:bold'>#{error[:group]}</span>: #{error[:message]}\n"
      end
    else
      content = "<span style='color:green; font-weight:bold'>#{I18n.t('geonotice.errors.no_errors')}</span>\n"
    end

    content += "\n" + I18n.t('geonotice.last_synced',
      date: @mb.wiki_date(@mb.local_storage['synced'])
    )

    @mb.edit(@report_page,
      content: content,
      summary: I18n.t('updating_report', link: "[[#{t('User')}:MusikBot II/GeonoticeSync|GeonoticeSync]]")
    )
  end
end

GeonoticeSync.run
