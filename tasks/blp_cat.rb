$LOAD_PATH << '..'
require 'musikbot'

module BLPCat
  def self.run(throttle = 0)
    @mb = MusikBot::Session.new(inspect)

    pages.each do |page|
      content = @mb.get(page)

      next if content =~ /\{\{(nobots\s*|\s*bots\|deny\s*=.*?MusikBot)\}\}/i

      changes = []

      categories.each do |category|
        cat_regex = /(\[\[\s*Category\s*:\s*(?:#{category.score}|#{category.descore})\s*(?:\|(.*?))?\]\]\n?)/i
        captures = content.scan(cat_regex)

        next unless captures.any?

        sort_keys = captures.map { |cap| cap[1] }.compact.uniq

        # ambiguous sort keys, let's abort...
        next if sort_keys.length > 1

        changes << category

        # replace first instance with corrected category
        sort_key = captures[0][1]
        sort_key&.strip! unless sort_key == ' ' # blank sort key should be preserved
        old_cat = captures.shift[0]
        content.gsub!(old_cat, "[[Category:#{category} (living people)#{'|' + sort_key if sort_key}]]\n")

        # remove duplicates
        duplicates = captures.collect { |cap| cap[0] }
        duplicates.each { |d| content.gsub!(d, '') }
      end

      next unless changes.any?

      summary = changes.map { |c| "[[Category:#{c}]] → [[Category:#{c} (living people)]]" }.join(', ')

      @mb.edit(page,
        content: content,
        summary: "Changing #{summary}"
      )
    end
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      run(throttle + 1)
    else
      raise
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.pages
    @pages ||= @mb.repl.query(%{
      SELECT DISTINCT(page_title)
      FROM page
      JOIN categorylinks
      ON cl_from = page_id
      WHERE page_namespace = 0
      AND page_id IN (
        SELECT cl_from
        FROM categorylinks
        WHERE cl_to = 'Living_people'
      ) AND (
        #{categories.map{ |cat| "cl_to = '#{cat.score}'"}.join(' OR ')}
      )
    }).to_a.collect { |a| a['page_title'] }
  end

  def self.categories
    @categories ||= @mb.config[:categories]
  end
end

BLPCat.run
