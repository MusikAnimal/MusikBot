$LOAD_PATH << '..'
require 'musikbot'

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

    sync
    generate_report

    @mb.local_storage(
      'last_revid' => @current_edit.attributes['revid'],
      'synced' => @mb.now.to_s
    )
  rescue => e
    # Goes to the bot's error log.
    @mb.report_error(t('Fatal error'), e)

    # Also add to report page.
    @errors << [
      group: I18n.t('errors.fatal'),
      message: I18n.t('errors.fatal_msg',
        log_page: "#{t('User')}:MusikBot II/GeonoticeSync/Error log"
      )
    ]
  end

  def self.sync
    json = JSON.parse(@mb.get(@config_page))

    # TODO: validate format...

    content = "window.GeoNotice = {};\nwindow.GeoNotice.notices = {\n\n" + JSON.pretty_generate(json) + "\n};"

    @mb.edit(@geonotice_page,
      content: content,
      summary: I18n.t('geonotice.sync_summary',
        link: "[[Special:Diff/#{@mb.local_storage['last_revid']}/#{@current_edit.attributes['revid']}]]"
      )
    )

    true
  rescue JSON::ParserError => e
    @errors << {
      group: I18n.t('geonotice.parser').upcase,
      message: I18n.t('geonotice.errors.parser', config_page: @config_page)
    }
    false
  end

  def self.generate_report
    content = ''

    binding.pry

    if @errors.any?
      content = "<div style='color:red;font-weight:bold'>#{num_errors} error#{'s' if num_errors > 1} as of ~~~~~</div>\n"

      @errors.each do |error|
        content += "* <span style='font-weight:bold'>#{error[:group]}</span>: #{error[:message]}\n"
      end
    end

    content += '\n' + I18n.t('geonotice.last_synced',
      date: @mb.wiki_date(@mb.local_storage['last_sync'])
    )

    @mb.edit(@report_page,
      content: content,
      summary: I18n.t('errors.reporting_errors', num: @errors.length)
    )
  end
end

GeonoticeSync.run
