$LOAD_PATH << '..'
require 'musikbot'

module NPPChart
  # Date of first available data.
  INITIAL_DATE = '2017-08-29'.freeze

  def self.run
    @mb = MusikBot::Session.new(inspect)

    [:monthly, :weekly, :daily, :hourly].each do |type|
      offset = @mb.config["#{type}_offset".to_sym]

      next unless should_refresh_data(type)

      start_date = get_start_date(type, offset)

      data = []

      historical_data(start_date, type).each do |row|
        data << {
          'date' => format_time(type, row['timestamp']),
          'value' => row['count']
        }
      end

      @mb.edit("Wikipedia:New pages patrol/Backlog chart/#{type}",
        content: data.to_json,
        summary: "Updating #{type} data for NPP backlog size"
      )
    end
  end

  def self.should_refresh_data(type)
    case type
      when :hourly
        return true
      when :daily
        return @mb.now.hour == 0
      when :weekly
        return @mb.now.wday == 0
      when :monthly
        return @mb.now.mday == 1
    end
  end

  def self.get_start_date(type, offset, offset_date = @mb.now)
    return @mb.parse_date(INITIAL_DATE) if offset == '*'

    case type
      when :hourly
        return offset_date - (offset.to_f / 24)
      when :daily
        return offset_date - offset.to_i
      when :weekly
        return offset_date - (offset.to_i * 7)
      when :monthly
        return offset_date.prev_month(offset.to_i)
    end
  end

  def self.format_time(type, time)
    if type == :hourly
      return time.to_datetime.new_offset(0).strftime('%Y-%m-%d %H:%M')
    end

    time.to_datetime.new_offset(0).strftime('%Y-%m-%d')
  end

  def self.historical_data(start_date, type = :daily)
    client = @mb.repl_client(credentials: :toolsdb, log: false)

    group_sql = ''

    if type == :daily
      group_sql = 'GROUP BY YEAR(npp_timestamp), MONTH(npp_timestamp), DAY(npp_timestamp)'
    elsif type == :weekly
      group_sql = 'GROUP BY YEAR(npp_timestamp), MONTH(npp_timestamp), WEEK(npp_timestamp)'
    elsif type == :monthly
      group_sql = 'GROUP BY YEAR(npp_timestamp), MONTH(npp_timestamp)'
    end

    timestamp_sql = type == :hourly ? 'npp_timestamp' : 'MAX(npp_timestamp)'

    sql = %{
      SELECT #{timestamp_sql} AS `timestamp`, npp_num_articles AS `count`
      FROM npp_queue_size
      WHERE npp_timestamp > '#{start_date}'
      #{group_sql}
    }

    client.query(sql).to_a
  end
end

NPPChart.run
