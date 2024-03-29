$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'
require 'resolv'
require 'nokogiri'

# WishlistSurvey task
# boot with:
#   ruby wishlist_survey.rb --edition 3 --project meta.wikimedia --lang en [--some-specific-task]
#
# Pass --help to see the other available scripts.
# By default, the --main task is ran, but this probably not what you want if you're calling this script directly.
#
# --edition 3 instructs to use the 3rd set of credentials, in this case for Community_Tech_bot.
module WishlistSurvey
  def self.run
    task = :main

    @mb = MusikBot::Session.new(inspect) do |args|
      args.banner = 'Usage: wishlist_survey.rb [options]'
      args.on(nil, '--main', 'Main WishlistSurvey task. Counts proposals/votes, rotates proposals, and updates the results page.') { task = :main }
      args.on(nil, '--add-category-pages', 'Creates the category pages according to the bot\'s configuration.') { task = :add_category_pages }
      args.on(nil, '--import-translations', 'Imports translations of the title from previous year\'s survey.') { task = :import_translations }
      args.on(nil, '--fix-proposal-headers', 'Loops through proposals and enter debugger when an invalid proposal header is encountered.') { task = :fix_proposal_headers }
      args.on(nil, '--add-voting-sections', 'Adds the voting sections to the proposal. To be ran just before voting starts.') { task = :add_voting_sections }
      args.on(nil, '--get-participants', 'Script to fetch a list of participants, going off the bot\'s current configuration.') { task = :get_participants }
      args.on(nil, '--analyze-participants', 'Script to report global edit counts and registration dates of participants.') { task = :analyze_participants }
      args.on(nil, '--sock-check', 'Generates a report of new-ish users to the survey, for manual review of sock votes.') { task = :sock_check }
      args.on(nil, '--group-proposal-msgs', 'Creates and writes to an aggregate group containing all of the translatable proposals.') { |v| task = :group_proposal_msgs }
      args.on(nil, '--late-votes', 'Show a list of possible late votes.') { |v| task = :late_votes }
      args.on(nil, '--prose-stats', 'Count prose stats for the whole survey.') { |v| task = :prose_stats }
      args.on(nil, '--results', 'Create the Result pages and redirect the Tracking pages.') { |v| task = :results }
    end

    # Fetches from [[User:Community_Tech_bot/WishlistSurvey/config]].
    @survey_root = @mb.config[:survey_root]

    self.public_send(task)
  end

  def self.main
    # Detect if this is the first run by simply checking if the total counts page exists.
    # If it doesn't, further down we'll create all the count pages with a value of 0.
    first_run = @mb.get("#{@survey_root}/Total editors").nil?

    # Get counts from previous run, with defaults if they haven't been set yet.
    cached_counts = {
      'total_proposals' => 0,
      'total_editors' => 0
    }
    if voting_phase?
      cached_counts['total_support_votes'] = 0
      cached_counts['total_votes'] = 0
    end
    cached_counts.merge!(@mb.local_storage['counts'] || {})

    # Rotate the proposals every N hours (as specified by rotation_rate in config).
    last_rotation = @mb.local_storage['last_rotation'] || @mb.now
    rotation_needed = @mb.config[:rotation_rate].to_i > 0 && @mb.parse_date(last_rotation) < (@mb.now - (@mb.config[:rotation_rate].to_f / 24))

    total_proposals = 0
    all_editors = []
    all_votes = {}

    # Only used during voting phase.
    total_votes = 0
    total_support_votes = 0

    categories.each do |category|
      proposals = get_proposals(category)
      editors = []

      # No proposals, nothing to do, unless it's the first_run,
      # where we want to put 0 values for all the count pages.
      next if proposals.empty? && !first_run

      # Skip all of this if it's the first run.
      unless first_run
        editors = get_editors_from_pages(proposals.keys) - [@mb.username]
        total_proposals += proposals.length
        all_editors += editors

        # Get votes for this category.
        category_votes = parse_category(category)

        if voting_phase?
          # Sort proposals by number of support votes.
          category_votes = category_votes.sort_by {|_k, v| -v[:support]}.to_h

          # Total votes for this category.
          support_votes = category_votes.values.map { |v| v[:support] }.inject(:+)
          neutral_votes = category_votes.values.map { |v| v[:neutral] }.inject(:+)
          oppose_votes = category_votes.values.map { |v| v[:oppose] }.inject(:+)
          total_votes += support_votes + neutral_votes + oppose_votes
          total_support_votes += support_votes
        end

        # Store votes in the category's hash.
        all_votes[category] = category_votes
      end

      # Get counts for this category from previous run, with defaults if they haven't been set yet.
      cached_counts[category] = {
        'proposals' => 0,
        'editors' => 0,
        'votes' => 0
      }.merge(cached_counts[category] || {})

      # Only attempt to edit if there's a change in the counts, or if this is the first run.
      # (First run would only apply to the proposals/pending phase, not voting).

      if voting_phase? && cached_counts[category]['votes'] != support_votes
        @mb.edit("#{@survey_root}/Vote counts/#{category}",
          content: support_votes,
          summary: "Updating support vote count (#{support_votes})"
        )
        cached_counts[category]['votes'] = support_votes
      end

      if first_run || cached_counts[category]['proposals'] != proposals.length
        @mb.edit("#{@survey_root}/Proposal counts/#{category}",
          content: proposals.length,
          summary: "Updating proposal count (#{proposals.length})"
        )
        cached_counts[category]['proposals'] = proposals.length
      end

      if first_run || cached_counts[category]['editors'] != editors.length
        @mb.edit("#{@survey_root}/Editor counts/#{category}",
          content: editors.length,
          summary: "Updating editor count (#{editors.length})"
        )
        cached_counts[category]['editors'] = editors.length
      end

      sanitize_category(category, rotation_needed)
    end

    @total_editors = all_editors.uniq.length

    report_needs_update = false

    # Only attempt to edit if there's a change in the counts.
    if voting_phase? && cached_counts['total_votes'] != total_support_votes
      @mb.edit("#{@survey_root}/Total votes",
        content: total_support_votes,
        summary: "Updating total vote count (#{total_support_votes})"
      )
      cached_counts['total_votes'] = total_support_votes
      report_needs_update = voting_phase?
    end

    if first_run || cached_counts['total_proposals'] != total_proposals
      @mb.edit("#{@survey_root}/Total proposals",
        content: total_proposals,
        summary: "Updating total proposal count (#{total_proposals})"
      )
      cached_counts['total_proposals'] = total_proposals
      report_needs_update = true
    end

    if first_run || cached_counts['total_editors'] != @total_editors
      @mb.edit("#{@survey_root}/Total editors",
        content: @total_editors,
        summary: "Updating total editor count (#{@total_editors})"
      )
      cached_counts['total_editors'] = @total_editors
      report_needs_update = true
    end

    @untranslated = get_proposals('Untranslated')
    if first_run || cached_counts['untranslated'] != @untranslated.length
      cached_counts['untranslated'] = @untranslated.length
      report_needs_update = true
    end

    create_report(all_votes) if report_needs_update

    @mb.local_storage(
      'counts' => cached_counts,
      'language_codes' => language_codes,
      'last_rotation' => rotation_needed ? @mb.now.to_s : last_rotation.to_s
    )
  end

  def self.categories
    @mb.config[:categories] + ['Larger suggestions']
  end

  def self.language_codes
    codes = @mb.local_storage['language_codes']
    return codes if codes.present?

    @mb.gateway.custom_query(
      meta: 'siteinfo',
      siprop: 'languages',
    ).elements['languages'].map { |l| l.attributes['code'] }
  end

  # Get proposals within a given category.
  def self.get_proposals(category)
    # Return cache if present.
    @category_proposals ||= {}
    if @category_proposals[category]
      return @category_proposals[category]
    end

    category_path = "#{@survey_root.score}/#{category.score}"
    category_path.slice!('User:')

    namespace = @survey_root =~ /^User:/ ? 2 : 0
    sql = %{
      SELECT
        page_id,
        REPLACE(REPLACE(page_title, "#{category_path}/", ""), "_", " ") AS page_title
      FROM metawiki_p.page
      WHERE page_namespace = ?
      AND page_title LIKE ?
      AND page_is_redirect = 0
    }

    proposal_map = {}

    @mb.repl_query(sql, namespace, "#{category_path}/%").to_a.each do |row|
      next if row['page_title'] =~ /.*?\/Proposal/
      proposal_map[row['page_id']] = row['page_title']
    end

    # Cache and return.
    @category_proposals[category] = proposal_map
  end

  # Get usernames of editors to a given set of page IDs.
  def self.get_editors_from_pages(page_ids)
    sql = %{
      SELECT DISTINCT(actor_name) AS editor
      FROM #{@mb.db}_p.revision_userindex
      JOIN #{@mb.db}_p.actor ON actor_id = rev_actor
      WHERE rev_page IN (#{page_ids.join(',')})
    }
    @mb.repl.query(sql).to_a.collect { |row| row['editor'] }
  end

  # Pick up any orphaned proposals that are't transcluded,
  # and remove transclusions that aren't a subpage of the given category.
  # Also shuffles proposals according to the rotation_rate in the config.
  def self.sanitize_category(category, rotation_needed = false, throttle = 0)
    content = get_page("#{@survey_root}/#{category}")
    proposals = content.scan(/#{@survey_root}\/#{category}\/(.*)}}/).flatten.uniq
    original_proposal_count = proposals.length
    proposals_from_db = get_proposals(category).values

    # Remove any tranclusions of non-existent proposals.
    proposals.each do |proposal|
      proposals.delete(proposal) if !proposals_from_db.include?(proposal)
    end

    # Append any orphaned proposals that aren't transcluded but should be.
    proposals_from_db.each do |proposal|
      subpage_name = proposal.split('/').last
      # Last two conditions prevent translation subpages from being transcluded.
      if !proposals.include?(proposal) && !language_codes.include?(subpage_name) && subpage_name != 'Proposal'
        proposals << proposal.force_encoding('utf-8')
      end
    end

    edit_summary = "Cleanup"

    if proposals.length > original_proposal_count
      edit_summary += "; rescuing orphaned proposals"
    end

    # Suffle if necessary.
    if rotation_needed
      proposals.shuffle!
      edit_summary += "; shuffling proposals to ensure fair visibility"
    end

    # Rebuild the list, stripping out whitespace and extraneous new lines.
    prev_cat = categories[categories.index(category) - 1]
    next_cat = categories[(categories.index(category) + 1) % categories.length]

    new_content = "{{Community Wishlist Survey/Category header|#{prev_cat}|#{next_cat}}}\n" +
      proposals.map { |p| "\n{{:#{@survey_root}/#{category}/#{p}}}" }.join

    if content != new_content
      @mb.edit("#{@survey_root}/#{category}",
        content: new_content,
        summary: edit_summary,
        conflicts: true
      )
    end
  end

  # Process all proposals within a category.
  def self.parse_category(category)
    category_votes = {}

    get_proposals(category).each do |id, title|
      category_votes[title] = parse_proposal(category, title)
    end

    category_votes
  end

  def self.parse_proposal(category, proposal)
    phab_regex = "\\[\\[:?phab(?:ricator)?:(T\\d+)|.*?phabricator\\.wikimedia\\.org\\/(T\\d+)|\\{\\{phab\\|(T\\d+)\\}\\}"
    username_sig_regex = "\\[\\[.*?(?:User(?: talk)?:|Special:Contributions\\/)(.*?)(?:\\]\\]|\\|)"
    discussion_regex = /===\s*{{dynamite\|title=Community Wishlist Survey\/Discussion\|t=yes}}\s*===/i

    subpage_content = get_page("#{@survey_root}/#{category}/#{proposal}/Proposal")
    proposal_content = get_page("#{@survey_root}/#{category}/#{proposal}")
    translatable = false

    if subpage_content.present?
      # Proposal that has been set up for translation.
      translatable = true
      proposer = subpage_content.scan(/\n\|\s*proposer\s*=.*?#{username_sig_regex}/i).flatten.first
      statement = subpage_content # We only use this to look for related phab tickets, see where related_phabs is init'd below.
      discussion = proposal_content.split(discussion_regex).last
      phab_tickets_section = subpage_content.split(/\n\|\s*phab\s*=/).last
    else
      proposer = proposal_content.scan(/\n\*\s*'''Proposer'''\s*:.*?#{username_sig_regex}/i).flatten.first
      statement, discussion = proposal_content.split(discussion_regex)
      phab_tickets_section = statement.split(/''Phabricator tickets:?''':?/).last
    end

    if voting_phase?
      voting_section = proposal_content.scan(/\n===\s*\{\{dynamite\|title=Community Wishlist Survey\/Discussion\|t=yes}}.*?\n(.*)/m).flatten.first || ''
      lines = voting_section.scan(/^*[^:](.*?)(?:\n)?$/).flatten

      supports = proposal_content.downcase.scan(/\{\{\s*(#{@mb.config[:support_templates]})(?:\s*\|.*?)?\s*\}\}/).flatten.length
      neutrals = proposal_content.downcase.scan(/\{\{\s*(#{@mb.config[:neutral_templates]})(?:\s*\|.*?)?\s*\}\}/).flatten.length
      opposes = proposal_content.downcase.scan(/\{\{\s*(#{@mb.config[:oppose_templates]})(?:\s*\|.*?)?\s*\}\}/).flatten.length
    else
      supports = '-'
      neutrals = '-'
      opposes = '-'
    end

    proposer_sig = /\{\{\s*(#{@mb.config[:support_templates]})\s*\}\}.*?\[\[.*?(?:User(?: talk)?:|Special:Contributions\/)#{proposer}(?:\]\]|\|).*?\b\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/

    discussion ||= '' # If no discussion has started yet.

    phabs = phab_tickets_section.scan(/#{phab_regex}/).flatten.compact
    related_phabs = statement.scan(/#{phab_regex}/).flatten.compact +
      discussion.scan(/#{phab_regex}/).flatten.compact - phabs

    votes = {
      proposer: proposer,
      phabs: phabs.uniq,
      related_phabs: related_phabs.uniq,
      translatable: translatable
    }

    if voting_phase?
      unless lines.select { |l| l =~ proposer_sig }.length == 1
        supports += 1
      end
      votes.merge!(
        support: supports,
        neutral: neutrals,
        oppose: opposes
      )
    else
      votes.merge!(
        support: '-',
        neutral: '-',
        oppose: '-'
      )
    end

    votes
  end

  def self.create_report_category(category_name, proposals)
    content = "|-\n"
    content += "!Rank\n" if voting_phase?
    content += "!Proposal\n!Proposer\n"
    content += "![[File:Symbol support vote.svg|15px]]\n" if voting_phase?
    content += "!Phabs\n"

    # Build array of proposal/category/votes for the report.
    rows = []
    proposals.sort.to_h.each do |proposal, count|
      rows << [proposal, category_name] + count.values
    end

    rank = 0
    all_proposers = []
    all_phabs = []
    all_related_phabs = []

    if voting_phase?
      # Sort all rows by count, descending.
      rows = rows.sort_by { |_proposal, _category, _proposer, _phabs, _rel_phabs, _translatable, support| -support }

      # Initialize counts.
      total_supports = 0
      total_neutrals = 0
      total_opposes = 0
    else
      total_supports = '-'
      total_neutrals = '-'
      total_opposes = '-'
    end

    # Build markup.
    rows.each do |proposal, _category, proposer, phabs, related_phabs, translatable, supports, neutrals, opposes|
      rank += 1

      all_proposers << proposer if proposer.present?
      all_phabs += phabs
      all_related_phabs += related_phabs

      if voting_phase?
        total_supports += supports
        total_neutrals += neutrals
        total_opposes += opposes
      end

      proposer_str = proposer ? "[[User:#{proposer}|#{proposer}]]" : '???'
      phabs = phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join(', ')

      if related_phabs.any?
        related_phabs = related_phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join(', ')
        phabs += "#{phabs.present? ? '<br/>' : ''}<small>Related: #{related_phabs}</small>"
      end

      proposal = proposal.dup.force_encoding('utf-8')
      proposer_str = proposer_str.dup.force_encoding('utf-8')
      proposal_name = translatable ? "{{TNT|#{@survey_root}/#{category_name}/#{proposal}/Proposal|titleonly=yes|uselang={{int:lang}}}}" : proposal

      content += "|-\n"
      content += "| #{rank}\n" if voting_phase?
      content += "| [[#{@survey_root}/#{category_name}/#{proposal}|#{proposal_name}]]\n" \
        "| #{proposer_str}\n"
      content += "| #{supports}\n" if voting_phase?
      content += "| #{phabs}\n"
    end

    heading_content = "{{TNT|Community Wishlist Survey/Results as of|2=~~~~~|uselang={{int:lang}}}}\n\n" \
      "{| class='wikitable sortable'\n"
    heading_content += "!\n" if voting_phase?
    heading_content += "!{{TNT|Community Wishlist Survey/Num proposals|2=#{rows.length}|uselang={{int:lang}}}}\n" \
      "!{{TNT|Community Wishlist Survey/Num proposers|2=#{all_proposers.uniq.length}|uselang={{int:lang}}}}\n"
    heading_content += "!#{total_supports}\n" if voting_phase?
    content = heading_content +
      "!{{TNT|Community Wishlist Survey/Num tasks|2=#{all_phabs.uniq.length}|3=#{all_related_phabs.uniq.length}|uselang={{int:lang}}}}\n" +
      "#{content}|}"
    unless @survey_root =~ /^User:/
      content += "\n\n[[Category:#{@survey_root}]]"
    end

    @mb.edit("#{@survey_root}/Tracking/#{category_name}",
      content: content,
      summary: "Updating voting results (#{rows.length} proposals, #{total_supports} support votes)"
    )
  end

  def self.create_report(cats)
    content = "|-\n"
    content += "!Rank\n" if voting_phase?
    content += "!Proposal\n!Category\n!Proposer\n"
    content += "![[File:Symbol support vote.svg|15px]]\n" if voting_phase?
    content += "!Phabs\n"

    # Build array of proposal/category/votes for the report.
    rows = []
    cats.each do |category, proposals|
      create_report_category(category, proposals)

      # Larger suggestions shouldn't be bundled with in-scope proposals.
      next if category == 'Larger suggestions'

      proposals.sort.to_h.each do |proposal, count|
        rows << [proposal, category] + count.values
      end
    end

    rank = 0
    all_proposers = []
    all_phabs = []
    all_related_phabs = []
    reported_categories = []

    if voting_phase?
      # Sort all rows by count, descending.
      rows = rows.sort_by { |_proposal, _category, _proposer, _phabs, _rel_phabs, _translatable, support| -support }

      # Initialize counts.
      total_supports = 0
      total_neutrals = 0
      total_opposes = 0
    else
      total_supports = '-'
      total_neutrals = '-'
      total_opposes = '-'
    end

    old_support_count = 0

    # Build markup.
    rows.each do |proposal, category, proposer, phabs, related_phabs, translatable, supports, neutrals, opposes|
      rank += 1

      all_proposers << proposer if proposer.present?
      all_phabs += phabs
      all_related_phabs += related_phabs
      reported_categories << category

      if voting_phase?
        total_supports += supports
        total_neutrals += neutrals
        total_opposes += opposes
      end

      proposer_str = proposer ? "[[User:#{proposer}|#{proposer}]]" : '???'

      phabs = phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join('{{int:comma-separator}}')

      if related_phabs.any?
        related_phabs = related_phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join('{{int:comma-separator}}')
        phabs += "#{phabs.present? ? '<br/>' : ''}<small>Related: #{related_phabs}</small>"
      end

      # XXX: The proposal column used to have <nowiki> wrapped around #{proposal}.
      # We may not need to do this anymore.

      proposal = proposal.dup.force_encoding('utf-8')
      proposer_str = proposer_str.dup.force_encoding('utf-8')

      # This can't use {{TNT}} becuase eventually the list becomes too long
      # and there are too many expensive Lua calls. Instead we transclude, and when the page is marked
      # for translation, it will display in the correct language thanks to transclusion-awareness.
      proposal_name = translatable ? "{{:#{@survey_root}/#{category}/#{proposal}/Proposal|titleonly=yes}}" : proposal

      content += "|-\n"
      content += "| #{rank}\n" if voting_phase?
      content += "| [[#{@survey_root}/#{category}/#{proposal}|#{proposal_name}]]\n" \
        "| [[#{@survey_root}/#{category}|{{dynamite|title=Community Wishlist Survey/#{category}|t=yes}}]]\n" \
        "| #{proposer_str}\n"
      content += "| #{supports}\n" if voting_phase?
      content += "| #{phabs}\n"
    end

    heading_content = "{{TNT|Community Wishlist Survey/Results as of|2=~~~~~|uselang={{int:lang}}}}\n\n{{/Heading}}\n\n" \
      "{| class='wikitable sortable'\n"
    heading_content += "!\n" if voting_phase?
    heading_content += "!{{TNT|Community Wishlist Survey/Num proposals|2=#{rows.length}|uselang={{int:lang}}}}\n" \
      "!{{TNT|Community Wishlist Survey/Num categories|2=#{reported_categories.uniq.length}|uselang={{int:lang}}}}\n" \
      "!{{TNT|Community Wishlist Survey/Num proposers|2=#{all_proposers.uniq.length}|uselang={{int:lang}}}}\n"
    heading_content += "!#{total_supports}\n" if voting_phase?
    content = heading_content +
      "!{{TNT|Community Wishlist Survey/Num tasks|2=#{all_phabs.uniq.length}|3=#{all_related_phabs.uniq.length}|uselang={{int:lang}}}}\n" +
      "\n#{content}\n|}"

    larger_suggestions = get_proposals('Larger suggestions')
    if larger_suggestions.any?
      content += "\n\n[[#{@survey_root}/Larger suggestions|Larger suggestions]] (#{larger_suggestions.length})"
    end

    archived_proposals = get_proposals('Archive')
    if archived_proposals.any?
      content += "\n\n[[#{@survey_root}/Archive|Archived proposals]] (#{archived_proposals.length})"
    end

    # List of untranslated proposals.
    if @untranslated.any?
      content += "\n\n=== Untranslated ==="
      @untranslated.values.each do |proposal|
        proposal = proposal.force_encoding('utf-8')
        content += "\n* [[#{@survey_root}/Untranslated/#{proposal}|#{proposal}]]"
      end
    end

    content += "\n\n[[Category:#{@survey_root}]]"

    @mb.edit("#{@survey_root}/Tracking",
      content: content,
      summary: "Updating voting results (#{rows.length} proposals, #{@total_editors} editors, #{total_supports} support votes)"
    )
  end

  # Get page ID for given page title, necessary to query revision table.
  def self.page_id(title)
    @mb.gateway.custom_query(
      titles: title,
      prop: 'info'
    ).elements['pages'].first.attributes['pageid']
  end

  # Get contents of a page and cache it for this run.
  # This is called when looping through the proposal pages.
  def self.get_page(page)
    @page_cache ||= {}
    @page_cache[page] ||= @mb.get(page)
  end

  def self.voting_phase?
    @mb.config[:phase] == 'voting' || @mb.config[:phase] == 'closed'
  end

  # Identifying socks/ineligible voters after voting phase has ended.
  def self.sock_check
    @min_editcount = 500
    @min_days_tenure = 90

    @allowlist = @mb.local_storage['allowlist'] || []
    @user_cache = {}

    support = @mb.config[:support_templates]
    neutral = @mb.config[:neutral_templates]
    oppose = @mb.config[:oppose_templates]

    # FIXME: check for {{unsigned|(.*?)\|}}
    @voter_regex = /\{\{\s*(#{support}|#{neutral}|#{oppose}|doubtful)(?:\s*\|.*?)?\s*\}\}.*(?:\[\[.*?(?:(?:[Uu]ser|Benutzer|Utilisateur|:it:s:Utente|:fr:Discussion utilisateur)(?:[_ ]talk)?:(.*?)(?:[\|\]]|\/talk))|\{\{\s*unsigned\|(.*?)[\||\}]).*?\b\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/i

    categories.each do |category|
      get_proposals(category).each do |page_id, proposal|
        sock_parse_votes(category, proposal)

        @mb.local_storage(
          'allowlist' => @allowlist
        )
      end
    end

    filtered_users = @user_cache.select do |username, data|
      next(true) if data == false # Globally locked or is an IP.
      next(false) if data == true # Already determined to meet criteria.

      # Users who are very new or have a low-ish edit count.
      is_new = (@mb.now - data[:min_registration]).to_i < @min_days_tenure
      is_new || (is_new && data[:global_editcount] < @min_editcount)
    end

    build_sock_report(filtered_users)
  end

  def self.sock_parse_votes(category, proposal)
    puts "Parsing #{category}/#{proposal}"

    content = @mb.get("#{@survey_root}/#{category}/#{proposal}")

    voting_section = content.scan(/\n===\s*\{\{dynamite\|title=Community Wishlist Survey\/Voting\|t=yes}}.*?\n(.*)/m).flatten.first || ''
    lines = voting_section.scan(/^*[^:](.*?)(?:\n)?$/).flatten
    proposal_voters = []

    lines.each do |line|
      template, voter, unsigned = line.scan(@voter_regex).flatten

      # From {{unsigned}} template.
      voter = unsigned if voter.nil?

      # Just a comment, most likely.
      if template.nil?
        # Skip for things that are for sure comments.
        next if line =~ /^(?:\*+|\**:+).*?\b\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)$/

        binding.pry
        next
      end

      if voter.nil?
        binding.pry
        next
      end

      voter = CGI.unescapeHTML(voter.force_encoding('utf-8').strip.ucfirst.gsub(/(‪|‬|#top$)/i, ''))

      # Duplicate vote
      if proposal_voters.include?(voter)
        puts "  ~~ DUPLICATE VOTE: #{voter}"
        binding.pry
        next
      end

      proposal_voters << voter

      if @allowlist.include?(voter)
        puts "  >> User:#{voter} meets criteria, from cache"
        next
      end

      # Already fetched data for this user
      if !@user_cache[voter].nil?
        puts "  ======== Already fetched data for #{voter}"
        next
      end

      puts "  ******* Fetching data for #{voter}"
      ret = get_voter_data(voter)

      # Globally locked or logged out.
      if ret == false
        puts "  ~~ GLOBALLY LOCKED / LOGGED OUT: #{voter}"
        binding.pry
        @user_cache[voter] = false
        next
      end

      # Short-stop if they already meet qualifications.
      if ret == true
        next
      end

      # In case user was renamed
      voter = ret[:username]

      @user_cache[voter] ||= ret
      @user_cache[voter][:proposals] ||= []
      @user_cache[voter][:proposals] << {
        category: category,
        proposal: proposal
      }
    end
  end

  def self.build_sock_report(user_cache)
    content = <<~EOS
      {| class="wikitable sortable"
      ! Username
      ! Global ec
      ! Registration
      ! Age in days
      ! Proposals
    EOS

    user_cache.each do |username, data|
      proposal_links = data[:proposals].map do |item|
        "[[meta:#{@survey_root}/#{item[:category]}/#{item[:proposal]}|#{item[:proposal]}]]"
      end

      content += <<~EOS
        |-
        | [[meta:Special:CentralAuth/#{username}|#{username}]]
        | #{data[:global_editcount]}
        | #{data[:min_registration].strftime('%Y-%m-%d')}
        | #{(@mb.now - data[:min_registration]).to_i}
        | #{proposal_links.join("\n")}
      EOS
    end

    puts content + "|}"
  end

  def self.get_voter_data(username)
    data = {
      username: username,
      global_editcount: 0,
      min_registration: nil
    }

    wikis = local_wikis(username)

    if wikis.empty?
      # Check if user was renamed
      new_username = moved_user_info(username)
      if new_username.present? && username != new_username
        puts "    #{username} was renamed to #{new_username}"
        data[:username] = username = new_username
        # Query again
        wikis = local_wikis(username)
      else
        # Must be logged out.
        return false
      end
    end

    parser = URI::Parser.new
    ret = @mb.http_get("https://meta.wikimedia.org/w/api.php?" \
        "action=query&meta=globaluserinfo&guiuser=#{parser.escape(username.to_s)}&" \
        "guiprop=editcount&format=json&formatversion=2")['query']['globaluserinfo']
    
    data[:global_editcount] = ret['editcount']
    if data[:global_editcount] > @min_editcount
      @allowlist << username
      puts "    short-stopping, user meets qualifications (editcount)"
      return true
    end

    wikis.each do |wiki|
      if wiki['gu_locked'].to_i == 1
        puts "    ~~~ Globally locked"
        return false
      end

      reg_date = @mb.parse_date(wiki['lu_attached_timestamp'])

      if data[:min_registration].nil? || reg_date < data[:min_registration]
        data[:min_registration] = reg_date
      end
    end

    data
  end

  def self.moved_user_info(username)
    log_entries = @mb.repl.query(%{
      SELECT log_timestamp, log_params FROM metawiki_p.logging
      WHERE log_type = 'gblrename' AND log_params LIKE '%\"#{username.descore.sub("'"){ "\\'" }}\"%'
    }).to_a

    return nil if log_entries.blank?

    log_entry = log_entries.first

    if log_entries.length > 1 && log_entries.first['log_params'].scan(/olduser";s:\d*:"(.*?)";/).flatten.first
      # User was renamed multiple times, so we'll just go with the last entry.
      log_entry = log_entries.last
    elsif username != log_entry['log_params'].scan(/olduser";s:\d*:"(.*?)";/).flatten.first
      # something went wrong and this wasn't for the user we thought it was, so just bail out forcing manual review
      return nil
    end

    log_entry['log_params'].scan(/newuser";s:\d*:"(.*?)";/).flatten.first
  end

  def self.local_wikis(username)
    sql = %{
      SELECT lu_wiki, lu_attached_timestamp, gu_locked
      FROM centralauth_p.localuser
      JOIN centralauth_p.globaluser ON lu_global_id = gu_id
      WHERE lu_name = ?
    }
    statement = @mb.repl.prepare(sql)
    statement.execute(username.descore).to_a
  end

  # Imports the page title translations of last year's survey to the current one, since
  # the Translate extension otherwise won't show the transcluded translations we already have.
  # This simply replaces the last year with the current one, so some languages that don't
  # use Western Arabic numerals (0-9) won't get copied over. Not much we can do about that.
  # The account that runs this script must be a translation admin.
  def self.import_translations
    last_year = (DateTime.now.year - 1).to_s
    this_year = DateTime.now.year.to_s

    # Get last year's page title translations
    old_titles = @mb.gateway.custom_query(
      list: 'prefixsearch',
      pssearch: "Translations:Community Wishlist Survey #{last_year}/Page display title/",
      pslimit: 5000
    ).elements['prefixsearch'].to_a.collect { |t| t['title'] }

    # Loop through and copy to this year, replacing the year.
    old_titles.each do |title|
      lang = title.split('/').last
      translation = @mb.get(title)
      new_title = "Translations:Community Wishlist Survey #{this_year}/Page display title/#{lang}"

      # Skip if year is apparently missing, or translation for this year exists.
      next if !translation.include?(last_year) || @mb.get(new_title).present?

      # Write new translation, replacing the old year with new one.
      @mb.edit(new_title,
        content: translation.sub(last_year, this_year),
        summary: "Importing translations from last year's survey"
      )
    end
  end

  def self.templatize_translations
    @mb = MusikBot::Session.new(inspect)
    source_page = 'Translations:Community Wishlist Survey 2022/11'
    target_page = 'Translations:Template:Community Wishlist Survey/Resources/Cards/8'

    old_titles = @mb.gateway.custom_query(
      list: 'prefixsearch',
      pssearch: source_page + '/',
      pslimit: 500
    ).elements['prefixsearch'].to_a.collect { |t| t['title'] }

    old_titles.each do |title|
      lang = title.split('/').last
      translation = @mb.get(title)
      new_title = target_page + '/' + lang

      @mb.edit(new_title,
        content: translation,
        summary: "Moving translations to template so that they can be reused year-to-year"
      )
    end
  end

  # This uses the current bot config, so run just before starting a new survey.
  def self.get_participants(stdout = true)
    usernames = []

    categories.each do |cat|
      proposals = get_proposals(cat)
      usernames += get_editors_from_pages(proposals.keys)
    end

    result = (usernames - [@mb.username]).uniq.sort
      # Exclude WMF accounts
      .reject { |u| u.include?('(WMF)') || u.include?('-WMF') }
      # Filter out IPs
      .reject { |u| u =~ Resolv::IPv4::Regex || u =~ Resolv::IPv6::Regex }

    if stdout
      puts "----------- LIST OF #{@survey_root.descore} PARTICIPANTS -----------"
      puts result
    else
      result
    end
  end

  def self.add_voting_sections
    categories.each do |category|
      proposals = get_proposals(category)

      proposals.each do |proposal|
        proposal_title = proposal[1]
        proposal_path = "#{@survey_root}/#{category}/#{proposal_title}"
        content = @mb.get(proposal_path)

        unless content.include?("=== {{dynamite|title=Community Wishlist Survey/Voting|t=yes}} ===")
          content += "\n\n=== {{dynamite|title=Community Wishlist Survey/Voting|t=yes}} ==="
          @mb.edit(proposal_path,
            content: content,
            summary: "Adding voting section"
          )
        end
      end
    end
  end

  def self.add_category_pages
    talk_page_root = @survey_root =~ /^User:/ ?
      "User talk:" + @survey_root.sub('User:', '') :
      "Talk:" + @survey_root

    categories.each_with_index do |category, i|
      prev_cat = categories[i - 1]
      next_cat = categories[i + 1] || categories[0]
      content = "{{Community Wishlist Survey/Category header|#{prev_cat}|#{next_cat}}}\n"
      @mb.edit("#{@survey_root}/#{category}",
        content: content,
        summary: "Creating category pages for [[#{@mb.config[:survey_root]}]]"
      )

      # Create talk page that redirects to main CWS talk page.
      @mb.edit("#{talk_page_root}/#{category}",
         content: "#REDIRECT [[Talk:Community Wishlist Survey]]",
         summary: "Redirecting to [[Talk:Community Wishlist Survey]]"
      )
    end

    # Purge so links are up-to-date
    categories.each do |category|
      @mb.gateway.purge("#{@survey_root}/#{category}")
    end
  end

  def self.fix_proposal_headers
    categories.each do |category|
      puts category
      proposals = get_proposals(category)
      proposals.each do |page_id, title|
        puts "> #{title}"
        content = @mb.get("#{@survey_root}/#{category}/#{title}")
        header_title = content.scan(/\{\{:Community Wishlist Survey\/Proposal header|1=(.*?)\}\}/).flatten[1]
        if header_title != title.force_encoding('utf-8')
          binding.pry
        end
      end
    end
  end

  def self.analyze_participants
    contributors = get_participants(false)

    contributors.each_with_index do |user_name, i|
      # Wikidata + Commons edit counts
      ret = @mb.http_get("https://commons.wikimedia.org/w/api.php?" \
        "action=query&list=users&ususers=#{URI.escape(user_name.to_s)}&" \
        "usprop=editcount&format=json&formatversion=2"
      )
      commons_editcount = ret['query']['users'][0]['editcount'] || 0
      ret = @mb.http_get("https://www.wikidata.org/w/api.php?" \
        "action=query&list=users&ususers=#{URI.escape(user_name.to_s)}&" \
        "usprop=editcount&format=json&formatversion=2"
      )
      wikidata_editcount = ret['query']['users'][0]['editcount'] || 0

      # Global edit count
      ret = @mb.http_get("https://meta.wikimedia.org/w/api.php?" \
        "action=query&meta=globaluserinfo&guiuser=#{URI.escape(user_name.to_s)}&" \
        "guiprop=editcount&format=json&formatversion=2")['query']['globaluserinfo']

      puts "#{i}\t#{user_name}\t#{ret['home']}\t#{ret['registration']}\t#{ret['editcount']}\t#{commons_editcount}\t#{wikidata_editcount}"
    end
  end

  def self.late_votes
    categories.each do |category|
      proposals = get_proposals(category)

      proposals.each do |_proposal_id, proposal|
        proposal_content = @mb.get("#{@survey_root}/#{category}/#{proposal}")
        voting_section = proposal_content.scan(/\n===\s*\{\{dynamite\|title=Community Wishlist Survey\/Voting\|t=yes}}.*?\n(.*)/m).flatten.first || ''
        lines = voting_section.scan(/^*[^:](.*?)(?:\n)?$/).flatten

        lines.each do |line|
          datestamps = line.scan(/\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/)
          datestamp = nil
          begin
            datestamp = datestamps ? @mb.parse_date(datestamps[0]) : nil
          rescue => e
            # Something weird going on
            binding.pry
          end

          if datestamp && datestamp > @mb.parse_date('18:00, February 11 2022 (UTC)')
            puts "#{category}/#{proposal}"
            binding.pry
          end
        end
      end
    end
  end

  def self.prose_stats
    total_words = 0
    total_chars = 0
    (categories + ['Archive']).each do |category|
      puts "Processing #{category}..."
      ret = @mb.http_get("https://meta.wikimedia.org/api/rest_v1/page/html/#{@survey_root.score}%2F#{category.score}")
      Nokogiri::XML(ret).css('.mw-parser-output').children.drop(1).each do |child|
        words = child.text
          # Remove timestamps
          .gsub(/\d{1,2}:\d{2}, \d+ \w+ \d{4} \(UTC\)/, '')
          # Extract out only words
          .split

        total_words += words.length
        total_chars += words.join.length
      end
    end

    puts "Total words: #{total_words}\nTotal characters: #{total_chars}"
  end

end

WishlistSurvey.run
