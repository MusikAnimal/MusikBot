$LOAD_PATH << '..'
require 'musikbot'

module RescueTranslations
  @mb = MusikBot::Session.new(inspect, true)

  # CATS = ['Admins and stewards', 'Anti-harassment', 'Bots and gadgets', 'Citations', 'Editing', 'Miscellaneous', 'Mobile and apps', 'Multimedia and Commons', 'Programs and events', 'Reading', 'Search', 'Watchlists', 'Wikidata', 'Wikisource', 'Wiktionary']
  CATS = ['Bots and gadgets', 'Citations', 'Editing', 'Miscellaneous', 'Mobile and apps', 'Multimedia and Commons', 'Programs and events', 'Reading', 'Search', 'Watchlists', 'Wikidata', 'Wikisource', 'Wiktionary']
  LANGS = ['id', 'de', 'eo', 'ga', 'nl', 'vi', 'tr', 'az', 'ca', 'da', 'et', 'es', 'fr', 'gl', 'hr', 'it', 'lt', 'hu', 'nb', 'oc', 'pl', 'pt', 'pt-br', 'ro', 'fi', 'sv', 'cs', 'el', 'bg', 'ru', 'sr', 'uk', 'yi', 'ar', 'sd', 'fa', 'arz', 'ne', 'bn', 'pa', 'ta', 'th', 'zh', 'ja', 'ko']

  SURVEY_SOUCE = '2017 Community Wishlist Survey/Results'

  # def self.run
  #   content = @mb.get("Community Wishlist Survey 2017/Archive")

  #   rows = content.split("\n")

  #   rows.each do |row|
  #     next unless row.include?(":2017 Community Wishlist Survey")

  #     title = row.scan(/{{:?(.*?)}}/).flatten.first
  #     new_title = title.sub('2017 Community Wishlist Survey', 'Community Wishlist Survey 2017')

  #     binding.pry

  #     @mb.edit(title,
  #       content: "#REDIRECT [[#{new_title}]]",
  #       summary: "Redirecting to new location following renaming of survey"
  #     )
  #   end
  # end

  # def self.run
  #   sql = %{
  #     SELECT cl_from
  #     FROM metawiki_p.categorylinks
  #     WHERE cl_to = 'Community_Wishlist_Survey_2019/Proposals'
  #   }
  #   page_ids = @mb.repl.query(sql).to_a.map {|row| row['cl_from']}

  #   sql = %{
  #     SELECT DISTINCT(page_title) AS title
  #     FROM metawiki_p.page
  #     WHERE page_id IN (#{page_ids.join(',')})
  #   }
  #   page_titles = @mb.repl.query(sql).to_a.map {|row| row['title']}

  #   page_titles.each do |page_title|
  #     next unless page_title.include?('2017')
  #     content = @mb.get(page_title)

  #     if content.nil?
  #       puts ">>>>>>>>>>>>> #{page_title.force_encoding('utf-8')}"
  #       next
  #     end

  #     content.sub!('{{:Community Wishlist Survey/Proposal header', '{{:Community Wishlist Survey/Proposal header|year=2017')

  #     @mb.edit(page_title,
  #       content: content,
  #       summary: 'Append year to proposal header of previous survey'
  #     )
  #   end
  # #   puts users
  # end

  # def self.get_proposals(category)
  #   # Return cache if present.
  #   @category_proposals ||= {}
  #   if @category_proposals[category]
  #     return @category_proposals[category]
  #   end

  #   category_path = "Community_Wishlist_Survey_2017/#{category.score}"

  #   sql = %{
  #     SELECT
  #       page_id,
  #       REPLACE(REPLACE(page_title, "#{category_path}/", ""), "_", " ") AS page_title
  #     FROM metawiki_p.page
  #     WHERE page_namespace = 0
  #     AND page_title RLIKE "#{category_path}/"
  #     AND page_is_redirect = 0
  #   }

  #   proposal_map = {}

  #   @mb.repl.query(sql).to_a.each do |row|
  #     proposal_map[row['page_id']] = row['page_title']
  #   end

  #   # Cache and return.
  #   @category_proposals[category] = proposal_map
  # end

  def self.run
    english = @mb.get('Translations:Community Wishlist Survey/heading-categories-desc-proposal-phase/1/en')

    LANGS.each do |lang|
      # CATS.each do |cat, ids|
        cat = 'heading-proposal-phase-ended'
        [118].each do |id|
          # puts "   --- #{lang}:#{cat}:#{id} ---"
          source_page = "Translations:Community Wishlist Survey 2017/#{id}/#{lang}"
          target_page = "Translations:Community Wishlist Survey/#{cat}/1/#{lang}"

          # Exists already?
          if @mb.get(target_page).present?
            puts '      (skipped)'
            next
          end

          translation = @mb.get(source_page)

          # if translation.nil?
          #   translation = @mb.get("Translations:2017 Community Wishlist Survey/10/#{lang}")
          # end

          if translation == english
            puts '     (untranslated)'
            next
          elsif translation.nil?
            puts '     (none available)'
            next
          elsif translation.include?('fuzzy')
            puts '     (outdated)'
            next
          end

          # translation.sub!('#learnmore', '#proposalsphase')

          skip = false

          binding.pry

          next if skip

          @mb.edit(target_page,
            content: translation,
            summary: 'Importing identical messages from older surveys (script-assisted)'
          )
        end
      # end
    end
  end

  # "Translations:Community Wishlist Survey 2016/1/hu"

  def self.get_translation(id)
    # content.scan(/Category button\|#{cat}\|(.*?)}}$/).flatten.first
    # content.scan(/<div>'''(.*?)'''<\/div>\n<\!-- DO NOT/m).flatten.first
    @mb.get("Translations:2017 Community Wishlist Survey/#{id}/#{lang}")
  end

  # def self.edit_translation(content, cat, lang)
  #   @mb.edit("Translations:Community Wishlist Survey/#{cat}/1/#{lang}",
  #     content: content,
  #     summary: 'Importing identical messages from older surveys (script assisted)'
  #   )
  # end
end

RescueTranslations.run
