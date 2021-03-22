$LOAD_PATH << '..'
require 'musikbot'

module CategoryCounter

  def self.run
    @mb = MusikBot::Session.new(inspect)

    # First determine which datasets need updating based on the granularity.
    categories = @mb.config
    to_update = []
    categories.each do |entry|
      if should_refresh_data?(entry)
        to_update << entry
      end
    end

    date = @mb.now.strftime('%Y-%m-%d')
    sizes = fetch_category_sizes(to_update)
    to_update.each do |entry|
      category_title = 'Category:' + entry['category'].gsub(/^Category:/, '')
      data = JSON.parse(@mb.get(entry['dataset']))

      if entry['cutoff'].present?
        data = trim_old_data(data, entry['cutoff'])
      end

      data << {
        'date' => date,
        'value' => sizes[category_title]
      }

      @mb.edit(entry['dataset'],
        content: data,
        summary: "Adding size of [[#{category_title}]] as of #{date} ([[User:MusikBot/ALSChart|more info]])"
      )
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  # Remove all data points dated before the present day - 'cutoff' days
  def self.trim_old_data(data, cutoff)
    data.map do |datum|
      @mb.parse_date(datum['date']) > (@mb.today - cutoff.to_i)
    end
  end

  # Get the size of each category
  def self.fetch_category_sizes(categories)
    sizes = {}

    # Batched API requests to 500 per request.
    categories.each_slice(500).to_a.each do |chunk|
      titles = chunk.map { |c| c['category'] }

      pages = @mb.gateway.custom_query(
        titles: titles,
        prop: 'categoryinfo',
        formatversion: 2
      ).elements['pages'].to_a

      pages.each do |page|
        if page['categoryinfo']
          sizes[page['title']] = page['categoryinfo']['size']
        end
      end
    end

    sizes
  end

  def self.should_refresh_data?(entry)
    ret = entry[:category].present? && entry[:granularity].present? && entry[:dataset].present?
    ret && case granularity
      when :daily
        true
      when :weekly
        @mb.now.wday == 0
      when :monthly
        @mb.now.mday == 1
    end
  end

end

CategoryCounter.run
