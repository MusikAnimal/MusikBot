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

        # blank sort key should be preserved, otherwise strip out whitespace
        if sort_key && sort_key != ' '
          sort_key.strip!
        end

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
    return @pages if @pages

    param_str = Array.new(categories.length).fill('?').join(', ')

    sql = %{
      SELECT DISTINCT p.page_title
      FROM page p
      -- First link to get target categories (?, ?, ?)
      JOIN categorylinks cl_target 
        ON p.page_id = cl_target.cl_from
      JOIN linktarget lt_target 
        ON cl_target.cl_target_id = lt_target.lt_id

      -- Second link to check for 'Living_people'
      JOIN categorylinks cl_living 
        ON p.page_id = cl_living.cl_from
      JOIN linktarget lt_living 
        ON cl_living.cl_target_id = lt_living.lt_id

      WHERE p.page_namespace = 0
        AND lt_living.lt_namespace = 14
        AND lt_living.lt_title = 'Living_people'
        AND lt_target.lt_namespace = 14
        AND lt_target.lt_title IN (#{param_str});
    }

    @pages = @mb.repl_query(sql, *categories.map{ |cat| cat.score })
      .to_a
      .collect { |a| a['page_title'] }
  end

  def self.categories
    @categories ||= @mb.config[:categories]
  end
end

BLPCat.run
