$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'

# WishlistSurvey task
# boot with:
#   ruby wishlist_survey.rb --edition 3 --project meta.wikimedia --lang en
# --edition 3 instructs to use the 3rd set of credentials, in this case for Community_Tech_bot.
module WishlistSurvey
  def self.run
    @mb = MusikBot::Session.new(inspect)

    # Fetches from [[User:Community_Tech_bot/WishlistSurvey/config]].
    @survey_root = @mb.config[:survey_root]

    # Detect if this is the first run by simply checking if the total counts page exists.
    # If it doesn't, further down we'll create all the count pages with a value of 0.
    first_run = @mb.get("#{@survey_root}/Total votes").nil?

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
    rotation_needed = @mb.parse_date(last_rotation) < @mb.now - (@mb.config[:rotation_rate].to_f / 24)

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
        editors = get_editors_from_pages(proposals.keys)
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
          summary: 'Updating support vote count'
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

      rotate_proposals(category) if rotation_needed
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
      'last_rotation' => rotation_needed ? @mb.now.to_s : last_rotation.to_s
    )
  end

  def self.categories
    @mb.config[:categories]
  end

  # Get proposals within a given category.
  def self.get_proposals(category)
    # Return cache if present.
    @category_proposals ||= {}
    if @category_proposals[category]
      return @category_proposals[category]
    end

    category_path = "#{@survey_root.score}/#{category.score}"

    sql = %{
      SELECT
        page_id,
        REPLACE(REPLACE(page_title, "#{category_path}/", ""), "_", " ") AS page_title
      FROM metawiki_p.page
      WHERE page_namespace = 0
      AND page_title RLIKE "#{category_path}/"
      AND page_is_redirect = 0
    }

    proposal_map = {}

    @mb.repl.query(sql).to_a.each do |row|
      proposal_map[row['page_id']] = row['page_title']
    end

    # Cache and return.
    @category_proposals[category] = proposal_map
  end

  # Get usernames of editors to a given page ID.
  def self.get_editors_from_page(page_id)
    sql = 'SELECT DISTINCT(rev_user_text) AS editor ' \
        "FROM #{@mb.db}_p.revision_userindex WHERE rev_page = #{page_id}"
    @mb.repl.query(sql).to_a.collect { |row| row['editor'] }
  end

  # Get usernames of editors to a given set of page IDs.
  def self.get_editors_from_pages(page_ids)
    sql = 'SELECT DISTINCT(rev_user_text) AS editor ' \
        "FROM #{@mb.db}_p.revision_userindex WHERE rev_page IN (#{page_ids.join(',')})"
    @mb.repl.query(sql).to_a.collect { |row| row['editor'] }
  end

  # Rotate proposals by moving the top proposal to the bottom.
  def self.rotate_proposals(category, throttle = 0)
    content = get_page("#{@survey_root}/#{category}")
    proposals = content.scan(/#{@survey_root}\/#{category}\/(.*)}}/).flatten.uniq
    proposals_from_db = get_proposals(category).values

    # Remove any tranclusions of non-existent proposals.
    proposals.each do |proposal|
      proposals.delete(proposal) if !proposals_from_db.include?(proposal)
    end

    # Append any proposals that aren't transcluded but should be.
    proposals_from_db.each do |proposal|
      proposals << proposal.force_encoding('utf-8') if !proposals.include?(proposal)
    end

    # Rotate.
    proposals.shuffle!

    # Rebuild the list, stripping out whitespace and extraneous new lines.
    prev_cat = categories[categories.index(category) - 1]
    next_cat = categories[(categories.index(category) + 1) % categories.length]

    new_content = "{{:Community Wishlist Survey/Category header|#{prev_cat}|#{next_cat}" +
      "|year=#{@mb.config[:year]}|phase=#{@mb.config[:phase]}}}\n" +
      proposals.map { |p| "\n{{:#{@survey_root}/#{category}/#{p}}}" }.join

    @mb.edit("#{@survey_root}/#{category}",
      content: new_content,
      summary: "Shuffling proposals to ensure fair visibility",
      conflicts: true
    )
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
    proposal_content = get_page("#{@survey_root}/#{category}/#{proposal}")

    # Only used during voting phase.
    votes = {}

    proposer = proposal_content.scan(/\n\*\s*'''Proposer'''\s*:.*?\[\[.*?(?:User(?: talk)?:|Special:Contributions\/)(.*?)(?:\]\]|\|)/i).flatten.first

    if voting_phase?
      voting_section = proposal_content.scan(/\n===\s*Voting.*?\n(.*)/m).flatten.first || ''
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

    statement, discussion = proposal_content.split(/===\s*(?:Community )?Discussion\s*===/i)
    discussion ||= '' # If no discussion has started yet.

    phab_regex = "\\[\\[:?phab(?:ricator)?:(T\\d+)|.*?phabricator\\.wikimedia\\.org\\/(T\\d+)|\\{\\{phab\\|(T\\d+)\\}\\}"
    phab_tickets_section = statement.split(/''Phabricator tickets:?''':?/).last
    phabs = phab_tickets_section.scan(/#{phab_regex}/).flatten.compact
    related_phabs = statement.scan(/#{phab_regex}/).flatten.compact +
      discussion.scan(/#{phab_regex}/).flatten.compact - phabs

    votes = {
      proposer: proposer,
      phabs: phabs.uniq,
      related_phabs: related_phabs.uniq
    }

    if voting_phase?
      unless proposer_voted = lines.select { |l| l =~ proposer_sig }.length == 1
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

  def self.create_report(cats)
    content = "|-\n"
    content += "!Rank\n" if voting_phase?
    content += "!Proposal\n!Category\n!Proposer\n"
    content += "![[File:Symbol support vote.svg|15px]]\n" if voting_phase?
    content += "!Phabs\n"

    # Build array of proposal/category/votes for the report.
    rows = []
    cats.each do |category, proposals|
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
      rows = rows.sort_by { |_proposal, _category, _proposer, _phabs, _rel_phabs, support| -support }

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
    rows.each do |proposal, category, proposer, phabs, related_phabs, supports, neutrals, opposes|
      # if supports != old_support_count
      #   rank += 1
      #   old_support_count = supports
      # end
      rank += 1

      # Strip out links and nowiki tags from section title.
      # XXX: May not need to do this anymore.
      # proposal = proposal.gsub(/\<nowiki\>|\<\/nowiki\>|\[|\]/, '')

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

      phabs = phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join(', ')

      if related_phabs.any?
        related_phabs = related_phabs.map { |p| "[[phab:#{p}|#{p}]]" }.join(', ')
        phabs += "#{phabs.present? ? '<br/>' : ''}<small>Related: #{related_phabs}</small>"
      end

      # XXX: The proposal column used to have <nowiki> wrapped around #{proposal}.
      # We may not need to do this anymore.

      proposal = proposal.dup.force_encoding('utf-8')
      proposer_str = proposer_str.dup.force_encoding('utf-8')

      content += "|-\n"
      content += "| #{rank}\n" if voting_phase?
      content += "| [[#{@survey_root}/#{category}/#{proposal}|#{proposal}]]\n" \
        "| [[#{@survey_root}/#{category}|#{category}]]\n" \
        "| #{proposer_str}\n"
      content += "| #{supports}\n" if voting_phase?
      content += "| #{phabs}\n"
    end

    heading = voting_phase? ? 'Voting results' : 'Results'
    heading_content = "#{heading} as of ~~~~~\n\n{{/Heading}}\n\n" \
      "{| class='wikitable sortable'\n"
    heading_content += "!\n" if voting_phase?
    heading_content += "!#{rows.length} proposals\n!#{reported_categories.uniq.length} categories\n" \
      "!#{all_proposers.uniq.length} proposers\n"
    heading_content += "!#{total_supports}\n" if voting_phase?
    content = "#{heading_content}!#{all_phabs.uniq.length} phab tasks, #{all_related_phabs.uniq.length} related\n#{content}\n|}"

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

    # gateway ||= MediaWiki::Gateway.new('https://www.mediawiki.org/w/api.php',
    #   bot: true,
    #   retry_count: 5,
    #   user_agent: 'User:Community_Tech_bot/1.1 (https://www.mediawiki.org/wiki/User:Community_Tech_bot/)',
    #   ignorewarnings: true
    # )
    # credentials = YAML.load(
    #   File.open(
    #     File.dirname(__FILE__) + '/../config/application.yml'
    #   ).read
    # ).symbolize_keys
    # gateway.login(
    #   credentials[:api][:edition_3][:username],
    #   credentials[:api][:edition_3][:password]
    # )
    # gateway.edit('User:Community_Tech_bot/Survey_tracking', content,
    #   summary: 'Survey tracking - to be moved to Meta after a few days of voting'
    # )

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
    @mb.config[:phase] == 'voting'
  end

  #################### IDENTIFYING SOCKS/INELIGIBLE VOTERS AFTER VOTING PHASE HAS ENDED ####################

  def self.sock_check
    @mb = MusikBot::Session.new(inspect, true)
    @survey_root = @mb.config[:survey_root]

    @min_editcount = 500
    @min_days_tenure = 90

    @whitelist = @mb.local_storage['whitelist'] || []
    @user_cache = {}

    support = @mb.config[:support_templates]
    neutral = @mb.config[:neutral_templates]
    oppose = @mb.config[:oppose_templates]

    # FIXME: check for {{unsigned|(.*?)\|}}
    @voter_regex = /\{\{\s*(#{support}|#{neutral}|#{oppose})\s*\}\}.*(?:\[\[.*?(?:(?:[Uu]ser|Benutzer|Utilisateur|:it:s:Utente|:fr:Discussion utilisateur)(?:[_ ]talk)?:(.*?)(?:[\|\]]|\/talk))|\{\{\s*unsigned\|(.*?)[\||\}]).*?\b\d\d:\d\d, \d+ \w+ \d{4} \(UTC\)/i

    # sock_parse_votes('Wiktionary', 'Wikisource dictionaries for Wiktionary')

    categories.each do |category|
      get_proposals(category).each do |page_id, proposal|
        sock_parse_votes(category, proposal)

        @mb.local_storage(
          'whitelist' => @whitelist
        )
      end
    end

    puts @user_cache
    puts '------------------'

    filtered_users = @user_cache.select do |username, data|
      next(true) if data == false # Globally locked or is an IP.
      next(false) if data == true # Already determined to meet criteria.
      (data[:global_editcount] > @min_editcount && (@mb.now - data[:min_registration]) > @min_days_tenure)
    end

    build_sock_report(filtered_users)
  end

  def self.sock_parse_votes(category, proposal)
    puts "Parsing #{category}/#{proposal}"

    content = @mb.get("#{@survey_root}/#{category}/#{proposal}")

    voting_section = content.scan(/\n===\s*Voting.*?\n(.*)/m).flatten.first || ''
    lines = voting_section.scan(/^*[^:](.*?)(?:\n)?$/).flatten
    proposal_voters = []

    lines.each do |line|
      template, voter, unsigned = line.scan(@voter_regex).flatten

      # From {{unsigned}} template.
      voter = unsigned if voter.nil?

      if template.nil? # Just a comment, most likely.
        binding.pry
        next
      end

      if voter.nil?
        binding.pry
        next
      end

      voter = CGI.unescapeHTML(voter.force_encoding('utf-8').strip.ucfirst)

      # Duplicate vote
      if proposal_voters.include?(voter)
        puts "  ~~ DUPLICATE VOTE: #{voter}"
        binding.pry
        next
      end

      proposal_voters << voter

      if @whitelist.include?(voter)
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

      @user_cache[voter] = ret
      @user_cache[voter][:proposals] = [proposal]
    end
  end

  def self.build_sock_report(data)
    puts data
  end

  def self.get_voter_data(username)
    data = {
      global_editcount: 0,
      max_editcount: 0,
      max_editcount_wiki: 0,
      min_registration: nil
    }

    wikis = local_wikis(username)

    if wikis.empty?
      # Logged out
      return false
    end

    wikis.each do |wiki|
      if wiki['gu_locked'].to_i == 1
        puts "    ~~~ Globally locked"
        return false
      end

      editcount = user_editcount(wiki['lu_wiki'], username)
      data[:global_editcount] += editcount

      if data[:global_editcount] > @min_editcount
        @whitelist << username
        puts "    short-stopping, user meets qualifications (editcount)"
        return true
      end

      if editcount > data[:max_editcount]
        data[:max_editcount] = editcount
        data[:max_editcount_wiki] = wiki['lu_wiki']
      end

      reg_date = @mb.parse_date(wiki['lu_attached_timestamp'])

      if data[:min_registration].nil? || reg_date < data[:min_registration]
        data[:min_registration] = reg_date
      end
    end

    data
  end

  def self.user_editcount(dbname, username)
    sql = %{
      SELECT user_editcount
      FROM #{dbname}_p.user
      WHERE user_name = ?
    }
    statement = @mb.repl.prepare(sql)
    statement.execute(username.descore).to_a.first['user_editcount'].to_i
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

end

WishlistSurvey.run

# WishlistSurvey.sock_check
