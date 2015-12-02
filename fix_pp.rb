$LOAD_PATH << '.'
require 'musikbot'

CATEGORY = 'Category:Wikipedia pages with incorrect protection templates'

module FixPP
  def self.run
    @mb = MusikBot::Session.new(inspect)

    pages = protect_info(category_members)

    pages.each do |page|
      process_page(page)
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_page(page)
    title = page.attributes['title']
    @content = @mb.get_page_props(title)
    @matches = content.scan(/\{\{\s*(?:Template\:)?pp-.*?\}\}/).flatten

    # no protection whatsoever
    if protected?(page)
      if title =~ /^Template:/
        # for templates
        repair_template_page
      else
        # audit protection info and rebuild the templates
        auto_build
      end
    else
      remove_pp
    end

    @mb.edit(title,
      content: content,
      conflicts: true
    )
  rescue MediaWiki::APIError => e
    if throttle > 3
      @mb.report_error('Edit throttle hit', e)
    elsif e.code.to_s == 'editconflict'
      process_page(page, throttle + 1)
    else
      raise e
    end
  end

  def self.repair_template_page
    has_doc = @content =~ /\{\{\s*(?:Template\:)?(?:#{doc_templates.join('|')})\s*\}\}/
    has_collapsable_option = @content =~ /\{\{\s*(?:Template\:)?(?:#{collapsable_option_templates.join('|')})\}\}/

    if has_doc || has_collapsable_option
      remove_pp

      if @content.include?('<noinclude>')
        @content.sub('<noinclude>', "<noinclude>#{@matches.join}")
      else
        @content = "<noinclude>#{@matches.join}</noinclude>"
      end
    end
  end

  def self.doc_templates
    %w(documentation doc docs)
  end

  def self.collapsable_option_templates
    ['cop', 'collapsable', 'collapsable option', 'collapsable_option']
  end

  def self.pp_groups(content)
    content.scan(//)
  end

  def self.remove_pp
    # FIXME: make sure not to leave extra new lines!
    @matches.each { |match| @content.gsub(match, '') }
  end

  def self.category_members
    @mb.gateway.purge(CATEGORY)
    @mb.gateway.custom_query(
      list: 'categorymembers',
      cmtitle: CATEGORY,
      cmlimit: 5000,
      cmprop: 'title',
      cmtype: 'page'
    ).elements['categorymembers'].map { |cm| cm.attributes['title'] }
  end

  def self.blp?(page)
    @mb.gateway.custom_query(
      prop: 'categories',
      titles: page
    ).elements['pages'][0].elements['categories'].select { |c| c.attributes['title'] == 'Category:Living people' }
  end

  def self.protect_info(titles)
    @mb.gateway.custom_query(
      prop: 'info|flagged',
      inprop: 'protection',
      titles: titles
    ).elements['pages']
  end

  def self.protections(page)
    page.elements['protection'].present? && page.elements['protection'][0].present? ? page.elements['protection'] : nil
  end

  def self.flags(page)
    page.elements['flagged'].present? ? page.elements['flagged'] : nil
  end

  def self.protected?(page)
    protections(page) || flags(page)
  end
end

FixPP.run
