$LOAD_PATH << '..'
require 'musikbot'

module NPPChart
  # Date of first available data.
  INITIAL_DATE = '2017-08-29'.freeze

  def self.run
    @mb = MusikBot::Session.new(inspect)

    last_runs = {}

    [:monthly, :weekly, :daily, :hourly].each do |type|
      offset = @mb.config["#{type}_offset".to_sym]

      next unless get_start_date(type, 1) > get_last_date(type)

      start_date = get_start_date(type, offset)

      data = []

      historical_data(start_date, type).each do |row|
        data << {
          'date' => format_time(type, row['timestamp']),
          'value' => row['count']
        }
      end

      @mb.edit("User:MusikBot/NPPChart/Sources/#{type}",
        content: data.to_json,
        summary: "Updating #{type} data for NPP backlog size"
      )
    end
  end

  def self.get_last_date(type)
    now = @mb.now
    case type
      when :hourly
        return @mb.parse_date((now + (1.0 / 24)).strftime('%Y-%m-%d %H:00'))
      when :daily
        return @mb.parse_date(now.strftime('%Y-%m-%d 00:00'))
      when :weekly
        return @mb.parse_date((now - now.wday).strftime('%Y-%m-%d 00:00'))
      when :monthly
        return @mb.parse_date((now - now.mday + 1).strftime('%Y-%m-01 00:00'))
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
