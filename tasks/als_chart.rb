$LOAD_PATH << '..'
require 'musikbot'

module ALSChart

  def self.run
    @mb = MusikBot::Session.new(inspect)

    size = @mb.gateway.custom_query(
      titles: @mb.config[:category],
      prop: 'categoryinfo'
    ).elements['pages/page/categoryinfo'].attributes['size'].to_i

    date = @mb.now.strftime('%Y-%m-%d')
    data = @mb.get(@mb.config[:dataset])
    binding.pry
    data << {
      'date' => date,
      'value' => size
    }

    @mb.edit(@mb.config[:dataset],
      content: data.to_json,
      summary: "Adding size of #{@mb.config[:category]]} as of #{date}"
    )
  end

end

ALSChart.run
