$LOAD_PATH << '..'
require 'musikbot'

module BLPCat
  def self.run
    @mb = MusikBot::Session.new(inspect)

    pages.each do |page|
      content = @mb.get(page)
      changes = []

      categories.each do |category|
        cat_regex = /\[\[Category:(#{category.score}|#{category.descore})\s*(\||\]\])/

        next unless content =~ cat_regex

        changes << category

        content.gsub!(
          cat_regex,
          "[[Category:#{category} (living people)]]"
        )
      end

      next unless changes.any?

      summary = changes.map { |c| "[[Category:#{c}]] → [[Category:#{c} (living people)]]" }.join(', ')

      binding.pry

      @mb.edit(page,
        content: content,
        summary: "Changing #{summary}"
      )
    end
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
    ['Year of birth missing', 'Date of birth missing', 'Place of birth missing']
  end
end

BLPCat.run
