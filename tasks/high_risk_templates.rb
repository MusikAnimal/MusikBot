$LOAD_PATH << '..'
require 'musikbot'

module HighRiskTemplates
  def self.run
    @mb = MusikBot::Session.new(inspect)

    threshold = 1_000

    highly_transcluded = []

    fetch_templates.each_with_index do |row, i|
      template = row['page_title']
      count = row['COUNT(*)']

      puts "#{template} = #{count}"

      if i % 100 == 0
        binding.pry
      end

      highly_transcluded << template
    end

    content = "<div style='font-size:24px'>Unprotected high-risk templates as of #{@mb.today.strftime('%-d %B %Y')}</div>\n" \
      "{{formatnum:#{highly_transcluded.length}}} templates with over {{formatnum:#{threshold}}} transclusions\n\n" \
      "{| class='wikitable sortable'\n! Template\n! Transclusions\n! Current protection\n" + content.chomp("|-\n") + "|}\n"

    @mb.edit('User:MusikBot/HighRiskTemplates/Report',
      content: content,
      summary: "Reporting #{highly_transcluded.length} unprotected templates",
      bot: false
    )
  end

  def self.fetch_templates
    sql = %{
      SELECT DISTINCT(page_title), COUNT(*)
      FROM page
      JOIN templatelinks ON page_title = tl_title
        AND page_namespace = tl_namespace
      LEFT JOIN page_restrictions ON pr_page = page_id
        AND pr_level IN ('autoconfirmed', 'templateeditor', 'extendedconfirmed', 'sysop')
        AND pr_type = 'edit'
      WHERE tl_namespace = 10
      AND pr_page IS NULL
      GROUP BY tl_title
      HAVING COUNT(*) >= 250 AND COUNT(*) <= 1000
      ORDER BY COUNT(*) DESC
    }
    @mb.repl.query(sql).to_a
  end

  def self.transclusion_count(title)
    title = @mb.repl.escape(title)
    sql = %{
      SELECT COUNT(*) AS count
      FROM templatelinks
      WHERE tl_title = '#{title}'
      AND tl_namespace IN (828)
    }
    @mb.repl.query(sql).to_a.first['count']
  end
end

HighRiskTemplates.run
