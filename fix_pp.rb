$LOAD_PATH << '.'
require 'musikbot'

CATEGORY = 'Category:Wikipedia pages with incorrect protection templates'

module FixPP
  def self.run
    @mb = MusikBot::Session.new(inspect)

    pages = protect_info(category_members.join('|'))

    pages.to_a.each do |page|
      # don't try endlessly to fix the same page
      unless page.elements['revisions'][0].attributes['user'] == 'MusikBot'
        process_page(page)
      end
    end
  rescue => e
    @mb.report_error('Fatal error', e)
  end

  def self.process_page(page_obj)
    @page_obj = page_obj
    title = @page_obj.attributes['title']
    @content = @mb.get_page_props(title)
    @edit_summaries = []
    @is_template = title =~ /^Template:/

    if protected?(@page_obj) && (new_pps = repair_existing_pps).present?
      remove_pps

      if @is_template
        @content = noinclude_pp(new_pps)
      else
        @content = new_pps + "\n" + @content
      end

      @edit_summaries << 'repairing protection templates'
    else
      remove_pps
      @edit_summaries << 'removing protection templates from unprotected page'
    end

    @content.sub!(/\A\<noinclude\>\s*\<\/noinclude\>/, '') if @is_template

    # FIXME: if no changes have happened, attempt null edit

    @mb.edit(title,
      content: @content,
      conflicts: true,
      summary: @edit_summaries.join(', ')
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

  def self.noinclude_pp(pps)
    has_doc = @content =~ /\{\{\s*(?:Template\:)?(?:#{doc_templates.join('|')})\s*\}\}/
    has_collapsable_option = @content =~ /\{\{\s*(?:Template\:)?(?:#{collapsable_option_templates.join('|')})\}\}/

    return @content if has_doc || has_collapsable_option

    if @content.scan(/\A\<noinclude\>.*?\<\/noinclude\>/).any?
      @content.sub(/\A\<noinclude\>/, "<noinclude>#{pps}")
    else
      "<noinclude>#{pps}</noinclude>\n" + @content
    end
  end

  def self.repair_existing_pps
    new_pps = []
    needs_pp_added = false
    existing_types = []

    # find which templates they used and normalize them
    pp_hash.keys.each do |k|
      matches = @content.scan(/\{\{\s*(#{k})\s*(?:\|.*?(small\s*=\s*\w+)|\}\})/i).flatten
      next unless matches.any?

      pp_type = pp_hash[matches[0]]
      type = pp_protect_type[pp_type.to_sym]
      small = matches[1].present?

      # edge case with base Template:Pp
      if type.blank? && pp_type == 'pp'
        next unless protections(@page_obj) || flags(@page_obj)

        type = @content.scan(/\{\{\s*pp\s*(?:\|.*?action\s*\=\s*(.*?)\|?)\}\}/i).flatten.first

        # if a type couldn't be parsed, mark it as needing all templates to be added
        #   since they obviously don't know how to do it right
        needs_pp_added = true and next unless type

        if reason = @content.scan(/\{\{pp\s*\|(?:(?:1\=)?(\w+(?=\||\}\}))|.*?\|1\=(\w+))/).flatten.compact.first
          pp_type = "pp-#{reason}"
        end
      end

      expiry_key = type == 'flagged' ? 'protection_expiry' : 'expiry'
      expiry = protection_by_type(@page_obj, type)[expiry_key] if valid_pp = protection_by_type(@page_obj, type)

      # skip if wrong kind of template altogether
      # we won't try to add the correct template as they may not want a pp-template
      next unless valid_pp

      existing_types << type

      new_pps << build_pp_template(
        pp_type: pp_type,
        type: type,
        expiry: expiry,
        small: small
      )
    end

    new_pps.join(@is_template ? '' : "\n") + (needs_pp_added ? auto_pps(existing_types) : '')
  end

  def self.auto_pps(existing_types = [])
    new_pps = ''
    (%w(edit move flagged) - existing_types).each do |type|
      next unless settings = protection_by_type(@page_obj, type)

      if type == 'flagged'
        pp_type = "pp-pc#{settings['level'].to_i + 1}"
      elsif type == 'move'
        pp_type = 'pp-move'
      elsif @is_template
        pp_type = 'pp-template'
      else
        pp_type = 'pp'
      end

      expiry_key = type == 'flagged' ? 'protection_expiry' : 'expiry'
      new_pps += build_pp_template(
        type: type,
        pp_type: pp_type,
        expiry: settings[expiry_key],
        small: true # just assume small=yes
      )
    end

    new_pps
  end

  def self.build_pp_template(opts)
    new_pp = '{{'

    if opts[:expiry] == 'infinity'
      if opts[:type] == 'edit'
        opts[:pp_type] = 'pp-semi-indef'
      elsif opts[:type] == 'move'
        opts[:pp_type] = 'pp-move-indef'
      end
      new_pp += opts[:pp_type]
    else
      opts[:expiry] = DateTime.parse(opts[:expiry]).strftime('%H:%M, %-d %B %Y')
      new_pp += "#{opts[:pp_type]}|expiry=#{opts[:expiry]}"
      new_pp += "|action=#{opts[:type]}" if opts[:pp_type] == 'pp'
    end

    "#{new_pp}#{'|small=yes' if opts[:small]}}}"
  end

  def self.doc_templates
    %w(documentation doc docs)
  end

  def self.collapsable_option_templates
    ['cop', 'collapsable', 'collapsable option', 'collapsable_option']
  end

  def self.remove_pps
    @content.gsub!(/\{\{\s*(?:Template\:)?(?:#{pp_hash.keys.flatten.join('|')}).*?\}\}\n*/i, '')
  end

  # def self.blp?(page)
  #   @mb.gateway.custom_query(
  #     prop: 'categories',
  #     titles: page
  #   ).elements['pages'][0].elements['categories'].select { |c| c.attributes['title'] == 'Category:Living people' }
  # end

  def self.protections(page)
    page.elements['protection'].present? && page.elements['protection'][0].present? ? page.elements['protection'] : nil
  end

  def self.flags(page)
    page.elements['flagged'].present? ? page.elements['flagged'] : nil
  end

  def self.protection_by_type(page, type)
    if type == 'flagged'
      flags(page).attributes rescue nil
    else
      protections(page).select { |p| p.attributes['type'] == type }.first.attributes rescue nil
    end
  end

  def self.protected?(page)
    (protections(page) || flags(page)).present?
  end

  # protection types
  def self.pp_hash
    return @pp_hash if @pp_hash

    # cache on disk for one week
    @mb.disk_cache('pp_hash', 604_800) do
      @pp_hash = {}

      pp_types.each do |pp_type|
        redirects("Template:#{pp_type}").each { |r| @pp_hash[r.sub(/^Template:/, '').downcase] = pp_type }
      end

      @pp_hash
    end
  end

  def self.pp_protect_type
    {
      'pp': '',
      'pp-move': 'move',
      'pp-pc1': 'flagged',
      'pp-pc2': 'flagged',
      'pp-dispute': 'edit',
      'pp-move-dispute': 'move',
      'pp-office': 'edit',
      'pp-blp': 'edit',
      'pp-sock': 'edit',
      'pp-template': 'edit',
      'pp-usertalk': 'edit',
      'pp-vandalism': 'edit',
      'pp-move-vandalism': 'move',
      'permanently protected': 'edit',
      'temporarily protected': 'edit',
      'pp-semi-indef': 'edit',
      'pp-move-indef': 'move'
    }
  end

  def self.pp_types
    pp_protect_type.keys
  end

  # API-related
  def self.protect_info(titles)
    @mb.gateway.custom_query(
      prop: 'info|flagged|revisions',
      inprop: 'protection',
      rvprop: 'user',
      rvlimit: 1,
      titles: titles
    ).elements['pages']
  end

  def self.category_members
    return @category_members if @category_members
    @mb.gateway.purge(CATEGORY)
    @category_members = @mb.gateway.custom_query(
      list: 'categorymembers',
      cmtitle: CATEGORY,
      cmlimit: 5000,
      cmprop: 'title',
      cmtype: 'page'
    ).elements['categorymembers'].map { |cm| cm.attributes['title'] }
  end

  def self.redirects(title)
    ret = @mb.gateway.custom_query(
      prop: 'redirects',
      titles: title
    ).elements['pages'][0].elements['redirects']
    [title] + (ret ? ret.map { |r| r.attributes['title'] } : [])
  end
end

FixPP.run
