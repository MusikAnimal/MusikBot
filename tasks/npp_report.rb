$LOAD_PATH << '..'
require 'musikbot'
require 'json'

# Start and end of the date range to process
START_DATE = 20170210000000
END_DATE   = 20170211000000

# Ask for pages between two IDs to speed up the query on revision.
# These were picked by looking at Special:NewPagesFeed
#   and using the IDs of pages around the above date range.
LOWER_PAGE_ID = 52680222
UPPER_PAGE_ID = 53600142

module NPPReport
  def self.run
    @mb = MusikBot::Session.new(inspect, true)
    @disk_cache = @mb.local_storage || {}

    # This script can do two things:
    # 1) patroller_review_stats()
    #    Find the number of patrollers who edited a page before marking it as reviewed
    #    (see https://phabricator.wikimedia.org/P5480 for results)
    # 2) article_survival_stats()
    #    Find the percentage of articles created by autoconfirmed and non-autoconfirmed
    #    users, and the percentage of those that were ultimately deleted.
    # Call whichever function below

    # article_survival_stats
    export_data(@disk_cache.sort.to_h)
  end

  # ARTICLE SURVIVAL STATS

  def self.article_survival_stats
    # Set up timeline data structure, with an entry for each date in the date range.
    # @disk_cache pulls in data from the last run, as this script may be ran in chunks.
    stats = @disk_cache.present? ? @disk_cache : {}

    (Date.parse(START_DATE.to_s)..Date.parse(END_DATE.to_s)).each do |date|
      date_key = date.strftime('%Y-%m-%d')

      # Skip if we already have an entry for this date from the last run
      next if stats[date_key].present?

      # For each day, we record data for autopatrolled, autoconfirmed and non-autoconfirmed users.
      # The summation of the numbers for each user group will be the grand total.
      stats[date_key] = {
        # Use the same data structure for autoconfirmed and non-autoconfirmed users
        autoconfirmed: {
          created: 0,
          deleted: {
            speedy: 0,
            speedy_type: {
              a1: 0,
              a2: 0,
              a3: 0,
              a5: 0,
              a7: 0,
              a9: 0,
              a10: 0,
              a11: 0,
              g1: 0,
              g2: 0,
              g3: 0,
              g4: 0,
              g5: 0,
              g6: 0,
              g7: 0,
              g8: 0,
              g9: 0,
              g10: 0,
              g11: 0,
              g12: 0
            },
            prod: 0,
            afd: 0,
            other: 0
          },
          redirected: 0,
          revdel: 0
        },
        non_autoconfirmed: {
          created: 0,
          deleted: {
            speedy: 0,
            speedy_type: {
              a1: 0,
              a2: 0,
              a3: 0,
              a5: 0,
              a7: 0,
              a9: 0,
              a10: 0,
              a11: 0,
              g1: 0,
              g2: 0,
              g3: 0,
              g4: 0,
              g5: 0,
              g6: 0,
              g7: 0,
              g8: 0,
              g9: 0,
              g10: 0,
              g11: 0,
              g12: 0
            },
            prod: 0,
            afd: 0,
            other: 0
          },
          redirected: 0,
          revdel: 0
        }
      }
    end

    # Fetch pages in date range, cache the results, and store the length in num_pages
    num_pages = pages_created.length

    # This is more of a safeguard. The same page (with the same ID) should
    # theoretically not be processed more than once.
    pages_processed = []

    # Loop through each page and do our processing
    pages_created.each_with_index do |page, i|
      next if page_was_redirect?(page) || pages_processed.include?(page['page_id'])

      pages_processed << page['page_id']

      user_rights_key = user_rights_type(page['user_id'], page['user_name'], page['timestamp'])

      # Only interested in non-autopatrolled users
      next if user_rights_key == :autopatrolled

      # Log output to monitor progress and spot check for accuracy
      output = "#{i} of #{num_pages}: #{page['title']} (#{page['deleted'] == 1 ? 'deleted, ' : ''}#{user_rights_key}"

      # Do summations for this date in the timeline
      timeline_date = @mb.parse_date(page['timestamp']).strftime('%Y-%m-%d')
      stats[timeline_date][user_rights_key][:created] += 1

      # Check if the text was revdel'd or suppressed, and if so increment this count,
      #   just out of curiousity of how many times this happens
      if [1, 15].include?(page['revdel'].to_i)
        stats[timeline_date][user_rights_key][:revdel] += 1
      end

      # page_is_redirect comes from the page object, which only exists if the page is live
      if page['redirect'] == 1
        stats[timeline_date][user_rights_key][:redirected] += 1
        output += ", redirected"
      elsif page['deleted'] == 1
        deletion_key, deletion_timestamp, speedy_types = deletion_data(page['page_id'])

        speedy_types.each do |speedy_type|
          speedy_key = speedy_type.downcase.to_sym
          if stats[timeline_date][user_rights_key][:deleted][:speedy_type].keys.include?(speedy_key)
            stats[timeline_date][user_rights_key][:deleted][:speedy_type][speedy_key] += 1
          end
        end

        # increment count on the type of deletion
        stats[timeline_date][user_rights_key][:deleted][deletion_key.to_sym] += 1

        output += ", #{deletion_key}"
      end

      puts output + ")"
    end

    @mb.local_storage(stats)

    puts stats
  end

  # This returns the data in a format needed for Extension:Graph
  def self.export_data(stats)
    data = {
      line: {
        all: {
          backlog: "type,date,value\n",
          survival: "type,date,value\n",
          deletions: "type,date,value\n",
          speedy: "type,date,value\n"
        },
        autoconfirmed: {
          survival: "type,date,value\n",
          deletions: "type,date,value\n",
          speedy: "type,date,value\n"
        },
        non_autoconfirmed: {
          survival: "type,date,value\n",
          deletions: "type,date,value\n",
          speedy: "type,date,value\n"
        }
      },
      pie: {
        all: {
          backlog: [
            {x: 'Autoconfirmed', y: 0},
            {x: 'Non-autoconfirmed', y: 0}
          ],
          survival: [
            {x: 'Kept', y: 0},
            {x: 'Deleted', y: 0},
            {x: 'Redirected', y: 0}
          ],
          deletions: [
            {x: 'Speedy', y: 0},
            {x: 'PROD', y: 0},
            {x: 'AfD', y: 0},
            {x: 'Other', y: 0}
          ],
          speedy: {}
        },
        autoconfirmed: {
          survival: [
            {x: 'Kept', y: 0},
            {x: 'Deleted', y: 0},
            {x: 'Redirected', y: 0}
          ],
          deletions: [
            {x: 'Speedy', y: 0},
            {x: 'PROD', y: 0},
            {x: 'AfD', y: 0},
            {x: 'Other', y: 0}
          ],
          speedy: {}
        },
        non_autoconfirmed: {
          survival: [
            {x: 'Kept', y: 0},
            {x: 'Deleted', y: 0},
            {x: 'Redirected', y: 0}
          ],
          deletions: [
            {x: 'Speedy', y: 0},
            {x: 'PROD', y: 0},
            {x: 'AfD', y: 0},
            {x: 'Other', y: 0}
          ],
          speedy: {}
        }
      }
    }

    top_10_speedy = {
      all: {},
      autoconfirmed: {},
      non_autoconfirmed: {}
    }

    # First determine the top 10 most used speedy deletion types,
    # the values of which we can go ahead and store for use in the pie charts.
    # Later in the main loop we will only keep track of the top 9 + "other"
    # for use in the line charts.
    stats.each do |date, values|
      [:autoconfirmed, :non_autoconfirmed].each do |rights_key|
        values[rights_key][:deleted][:speedy_type].keys.each do |speedy_key|
          speedy_value = values[rights_key][:deleted][:speedy_type][speedy_key]
          speedy_key = speedy_key.upcase

          # Pie - All - Speedy
          if data[:pie][:all][:speedy][speedy_key]
            data[:pie][:all][:speedy][speedy_key] += speedy_value
          else
            data[:pie][:all][:speedy][speedy_key] = speedy_value
          end

          # Pie - (Non-)Autoconfirmed - Speedy
          if data[:pie][rights_key][:speedy][speedy_key]
            data[:pie][rights_key][:speedy][speedy_key] += speedy_value
          else
            data[:pie][rights_key][:speedy][speedy_key] = speedy_value
          end
        end
      end
    end

    # Do our sorts
    [:all, :autoconfirmed, :non_autoconfirmed].each do |rights_key|
      sorted_values = data[:pie][rights_key][:speedy].sort_by { |_key, value| value }.reverse
      data[:pie][rights_key][:speedy] = sorted_values.slice!(0, 9).to_h
      data[:pie][rights_key][:speedy][:other] = sorted_values.to_h.values.inject(:+)
    end

    # Now loop through stats by date and fill in all needed data structures
    stats.each do |date, values|
      date_value = Date.parse(date).strftime('%b %-d %Y')

      # Line - All - Backlog
      data[:line][:all][:backlog] += "All,#{date_value},#{values[:autoconfirmed][:created] + values[:non_autoconfirmed][:created]}\n" \
        "Autoconfirmed,#{date_value},#{values[:autoconfirmed][:created]}\n" \
        "Non-autoconfirmed,#{date_value},#{values[:non_autoconfirmed][:created]}\n"

      # Pie - All - Backlog
      data[:pie][:all][:backlog][0][:y] += values[:autoconfirmed][:created]
      data[:pie][:all][:backlog][1][:y] += values[:non_autoconfirmed][:created]

      # Data for Line - All - Survival
      total_kept = 0
      total_deleted = 0
      total_redirected = 0

      # Data for Line - All - Deletions
      totals_deletions = {
        'Speedy' => 0,
        'PROD' => 0,
        'AfD' => 0,
        'Other' => 0
      }

      # Data for Line - All - Speedy
      totals_speedy = { 'Other' => 0 }

      [:autoconfirmed, :non_autoconfirmed].each do |rights_key|
        deleted = 0
        ['Speedy', 'PROD', 'AfD', 'Other'].each_with_index do |del_type, i|
          deleted_value = values[rights_key][:deleted][del_type.downcase.to_sym]
          deleted += deleted_value

          # Line - (Non-)Autoconfirmed - Deletions
          data[:line][rights_key][:deletions] += "#{del_type},#{date_value},#{deleted_value}\n"

          # Pie - (Non-)Autoconfirmed - Deletions
          data[:pie][rights_key][:deletions][i][:y] += deleted_value

          # For Line - All - Deletions
          totals_deletions[del_type] += deleted_value

          # Pie - All - Deletions
          data[:pie][:all][:deletions][i][:y] += deleted_value
        end
        redirected = values[rights_key][:redirected]
        kept = values[rights_key][:created] - deleted - redirected

        # Update totals for Line - All - Survival
        total_kept += kept
        total_deleted += deleted
        total_redirected += redirected

        # Pie - All - Survival
        data[:pie][:all][:survival][0][:y] += kept
        data[:pie][:all][:survival][1][:y] += deleted
        data[:pie][:all][:survival][2][:y] += redirected

        # Line - (Non-)Autoconfirmed - Survival
        data[:line][rights_key][:survival] += "Kept,#{date_value},#{kept}\n"
        data[:line][rights_key][:survival] += "Deleted,#{date_value},#{deleted}\n"
        data[:line][rights_key][:survival] += "Redirected,#{date_value},#{redirected}\n"

        # Pie - (Non-)Autoconfirmed - Survival
        data[:pie][rights_key][:survival][0][:y] += kept
        data[:pie][rights_key][:survival][1][:y] += deleted
        data[:pie][rights_key][:survival][2][:y] += redirected

        # Loop through each type of speedy deletion and populate data structures
        values[rights_key][:deleted][:speedy_type].keys.each do |speedy_key|
          speedy_value = values[rights_key][:deleted][:speedy_type][speedy_key]
          speedy_key = speedy_key.upcase

          # Above in the first loop we got the top 10 speedy types of each user right type.
          # Here we'll keep track of the per-day values for the line charts, but only
          # for the top 10
          if data[:pie][rights_key][:speedy].keys.include?(speedy_key)
            data[:line][rights_key][:speedy] += "#{speedy_key},#{date_value},#{speedy_value}\n"
          else
            data[:line][rights_key][:speedy] += "Other,#{date_value},#{speedy_value}\n"
          end

          # Same logic as above but for All
          if data[:pie][:all][:speedy].keys.include?(speedy_key)
            if totals_speedy[speedy_key]
              totals_speedy[speedy_key] += speedy_value
            else
              totals_speedy[speedy_key] = speedy_value
            end
          else
            totals_speedy['Other'] += speedy_value
          end
        end
      end

      # Line - All - Survival
      data[:line][:all][:survival] += "Kept,#{date_value},#{total_kept}\n"
      data[:line][:all][:survival] += "Deleted,#{date_value},#{total_deleted}\n"
      data[:line][:all][:survival] += "Redirected,#{date_value},#{total_redirected}\n"

      # Line - All - Deletions
      data[:line][:all][:deletions] += "Speedy,#{date_value},#{totals_deletions['Speedy']}\n"
      data[:line][:all][:deletions] += "PROD,#{date_value},#{totals_deletions['PROD']}\n"
      data[:line][:all][:deletions] += "AfD,#{date_value},#{totals_deletions['AfD']}\n"
      data[:line][:all][:deletions] += "Other,#{date_value},#{totals_deletions['Other']}\n"

      # Line - All - Speedy
      totals_speedy.keys.each do |speedy_key|
        data[:line][:all][:speedy] += "#{speedy_key},#{date_value},#{totals_speedy[speedy_key]}\n"
      end
    end

    # Transform data structures for speedy types into what's needed for the pie charts
    [:all, :autoconfirmed, :non_autoconfirmed].each do |rights_key|
      new_speedy_data = []
      data[:pie][rights_key][:speedy].each do |speedy_type, speedy_value|
        new_speedy_data << {x: speedy_type.to_s.ucfirst, y: speedy_value}
      end
      data[:pie][rights_key][:speedy] = new_speedy_data
    end

    # Write to file
    write_report("all-backlog-line", data[:line][:all][:backlog])
    write_report("all-backlog-pie", data[:pie][:all][:backlog].to_json)
    [:all, :autoconfirmed, :non_autoconfirmed].each do |rights_key|
      write_report("#{rights_key}-survival-line", data[:line][rights_key][:survival])
      write_report("#{rights_key}-survival-pie", data[:pie][rights_key][:survival].to_json)
      write_report("#{rights_key}-deletions-line", data[:line][rights_key][:deletions])
      write_report("#{rights_key}-deletions-pie", data[:pie][rights_key][:deletions].to_json)
      write_report("#{rights_key}-speedy-line", data[:line][rights_key][:speedy])
      write_report("#{rights_key}-speedy-pie", data[:pie][rights_key][:speedy].to_json)
    end
  end

  def self.write_report(title, csv)
    file_path = File.dirname(__FILE__) + "/../disk_cache/#{title}"
    puts file_path
    File.open(file_path, 'w') { |file| file.write(csv) }
  end

  def self.page_was_redirect?(page_props)
    begin
      content = @mb.get_revision_at_date(page_props['title'], page_props['timestamp'],
        deleted: page_props['deleted'] == 1
      )
      !!(content =~ /^#REDIRECT/i)
    rescue => e
      # This sometimes happens if the page was so big that the Rexml library breaks.
      # In such cases it's safe to assume the page was not a redirect.
      false
    end
  end

  # Determine if the user was autopatrolled or autoconfirmed based on user rights,
  #   number of edits, and registration date at the time the page was created (timestamp)
  def self.user_rights_type(user_id, username, timestamp)
    # IPs may create articles through AfC
    return :non_autoconfirmed if user_id == 0

    # Get last user rights change before the page creation, which
    #   will tell us what user rights that had at that time.
    sql = %{
      SELECT log_params
      FROM logging
      WHERE log_type = 'rights'
      AND log_title = ?
      AND log_timestamp < ?
      ORDER BY log_timestamp DESC
      LIMIT 1
    }
    last_rights_change = repl_query(sql, username.score, timestamp).first
    if last_rights_change.present?
      # The current format of the log params is `oldgroups [groups] newgroups [groups]`
      #   where the old format just listed what they currently had at that time, e.g. `autoreviewer,rollback`
      # So we look at either the "newgroups" or any groups that aren't followed by the text "newgroups"
      autopatrolled_regex = /newgroups(?=.*?(autoreviewer|sysop))|(autoreviewer|sysop)(?!.*?newgroups)/

      # accounts for confirmed, autoconfirmed and extendedconfirmed (the latter implies (auto)confirmed is present)
      confirmed_regex = /newgroups(?=.*?confirmed)|confirmed(?!.*?newgroups)/

      return :autopatrolled if last_rights_change['log_params'] =~ autopatrolled_regex
      return :autoconfirmed if last_rights_change['log_params'] =~ confirmed_regex
    end

    # Check if the account was under 4 days old at the time they created the article
    sql = %{
      SELECT user_registration
      FROM user
      WHERE user_name = ?
    }
    registration = repl_query(sql, username.descore).first['user_registration']

    # Some really old accounts mysteriously don't have a registration date.
    # We'll just have to assume they made at least 10 edits.
    return :autoconfirmed if registration.nil?

    age_at_creation = (@mb.parse_date(timestamp.to_s) - @mb.parse_date(registration)).to_i
    return :non_autoconfirmed if age_at_creation < 4

    # Check if the account has an edit count of less than 10 when they created the article
    sql = %{
      SELECT 'live' AS source, COUNT(*) AS count
      FROM revision
      WHERE rev_user = ?
      AND rev_timestamp BETWEEN #{registration} AND #{timestamp}
      UNION
      SELECT 'del' AS source, COUNT(*) AS count
      FROM archive
      WHERE ar_user = ?
      AND ar_timestamp BETWEEN #{registration} AND #{timestamp}
    }
    result = repl_query(sql, user_id, user_id)
    edits_at_creation = result[0]['count'] + result[1]['count']

    return :non_autoconfirmed if edits_at_creation < 10

    :autoconfirmed
  end

  def self.pages_created
    return @pages_created if @pages_created

    sql = %{
      SELECT page_title AS title, rev_page AS page_id, rev_timestamp AS timestamp,
             rev_user AS user_id, rev_user_text AS user_name, 0 AS deleted,
             rev_deleted AS revdel, page_is_redirect AS redirect
      FROM revision
      JOIN page ON page_id = rev_page
      WHERE rev_page > #{LOWER_PAGE_ID}
      AND rev_page < #{UPPER_PAGE_ID}
      AND rev_parent_id = 0
      AND page_namespace = 0
      AND rev_timestamp BETWEEN #{START_DATE} AND #{END_DATE}
    }
    pages = @mb.repl.query(sql).to_a

    sql = %{
      SELECT ar_title AS title, ar_page_id AS page_id, ar_timestamp AS timestamp,
             ar_user AS user_id, ar_user_text AS user_name, 1 AS deleted,
             ar_deleted AS revdel, 0 AS redirect
      FROM archive
      WHERE ar_parent_id = 0
      AND ar_namespace = 0
      AND ar_timestamp BETWEEN #{START_DATE} AND #{END_DATE}
    }

    # Cache and return combined results of the two queries
    @pages_created = (pages + @mb.repl.query(sql).to_a).sort {|a, b| a['title'] <=> b['title']}
  end

  def self.deletion_data(page_id)
    sql = %{
      SELECT log_comment, log_timestamp
      FROM logging
      WHERE log_type = 'delete'
      AND log_page = #{page_id}
    }

    # rescue nil to handle pages where the revision or log entry was suppressed
    comment = @mb.repl.query(sql).to_a.first['log_comment'] rescue nil
    timestamp = @mb.repl.query(sql).to_a.first['log_timestamp'] rescue nil

    speedy_regex = /\[\[WP:CSD#((?:A|G)\d+)|\[\[WP:((?:A|G)\d+)\|/

    deletion_type = case comment
    when speedy_regex
      'speedy'
    when /\[\[WP:(BLP)?PROD/
      'prod'
    when /\[\[(Wikipedia|WP):Articles for deletion\//
      'afd'
    else
      'other'
    end

    speedy_type = []
    if deletion_type == 'speedy'
      speedy_type = comment.scan(speedy_regex).flatten.compact.uniq
      puts "  #{comment} = #{speedy_type}"
    end

    [deletion_type, timestamp, speedy_type]
  end

  # PATROLLER REVIEW STATS

  def self.patroller_review_stats
    total_page_count = 0

    # Only look for edits made by users who are known to have done reviews
    # This list is from https://quarry.wmflabs.org/query/10877 and https://quarry.wmflabs.org/query/18802
    reviewers = @disk_cache['reviewers'].uniq
    reviewers_sql = reviewers.map{ |r| "\"#{r}\"" }.join(',')

    pages = pages_to_check

    pages_with_reviewers = {}
    reviewed_and_unreviewed = 0

    num_pages = pages.length

    pages.each_with_index do |page, i|
      iteration_str = "#{i} of #{num_pages}"

      page_id = page['ptrp_page_id']
      page_is_unreviewed = page['ptrp_reviewed'].to_i == 0

      page_creator_user_id = page_creator(page_id)

      if is_page_creator_autopatrolled?(page_creator_user_id)
        next
      else
        total_page_count += 1
      end

      # get timestamp of first review of the page
      sql = %{
        SELECT MIN(log_timestamp) AS min_timestamp,
               MAX(log_timestamp) AS max_timestamp
        FROM logging_logindex
        WHERE log_page = #{page_id}
        AND (
          (
            log_type = 'patrol'
            AND log_params NOT LIKE '%::auto";i:1%'
          ) OR (
            log_type = 'pagetriage-curation'
            AND log_action = 'reviewed'
          )
        );
      }
      reviewed_at = @mb.repl.query(sql).to_a.first
      page_has_been_reviewed = reviewed_at['min_timestamp'].present?

      rev_timestamp_clause = ''

      if page_has_been_reviewed && page_is_unreviewed
        # check if there was only one reviewer, who evidently reviewed it and unreviewed it
        sql = %{
          SELECT COUNT(DISTINCT(log_user_text)) AS count
          FROM logging_logindex
          WHERE log_page = #{page_id}
          AND (
            (
              log_type = 'patrol'
              AND log_params NOT LIKE '%::auto";i:1%'
            ) OR (
              log_type = 'pagetriage-curation'
              AND log_action = 'reviewed'
            )
          );
        }
        num_reviewers = @mb.repl.query(sql).to_a.first['count']

        if num_reviewers == 1
          reviewed_and_unreviewed += 1
          puts "#{iteration_str} ~ -> #{page_id}: reviewer reviewed and unreviewed"
        else
          # More than one reviewer but the page is currently unreviewed.
          # This is likely because it used to be a redirect and is now an article,
          # so check for number of edits since the last review
          puts "#{iteration_str} ~ -> #{page_id} last reviewed at: #{reviewed_at['max_timestamp']}:"
          rev_timestamp_clause = "AND rev_timestamp > #{reviewed_at['max_timestamp']}"
        end
      elsif page_has_been_reviewed
        # Page has been reviewed, so only look at edits before the review took place
        puts "#{iteration_str} ~ -> #{page_id} first reviewed at: #{reviewed_at['max_timestamp']}:"
        rev_timestamp_clause = "AND rev_timestamp < #{reviewed_at['min_timestamp']}"
      end

      # Get revisions for the page leading up to when it was reviewed (if ever)
      sql = %{
        SELECT DISTINCT(rev_user_text) AS reviewer
        FROM revision_userindex
        WHERE rev_user_text IN (#{reviewers_sql})
        AND rev_page = #{page_id}
        #{rev_timestamp_clause}
      }
      reviewers = @mb.repl.query(sql).to_a.collect { |r| r['reviewer'] }

      # Don't count the page creator as a reviewer if they are themselves a reviewer
      reviewer_length = reviewers.length - (is_page_creator_a_patroller?(page_creator_user_id) ? 1 : 0)

      # There were edits by more than one reviewer. If the page is currently reviewed,
      # we're only accounting for edits that took place before the final review,
      # OR there were edits by a single reviewer, and the page is still unreviewed.
      if reviewers.length > 1 || (reviewers.length == 1 && page_is_unreviewed)
        page_title = get_page_name(page_id)
        pages_with_reviewers[page_title] = reviewers.length
        puts "#{iteration_str} ~ #{page_title} = #{reviewers.join(', ')} (#{reviewers.length})"
      end
    end

    @disk_cache['pages'] = pages_with_reviewers
    @disk_cache['total_pages_non_autopatrolled'] = total_page_count
    @disk_cache['pages_reviewed_and_unreviewed'] = reviewed_and_unreviewed

    @mb.local_storage(@disk_cache)
  end

  def self.get_page_name(page_id)
    sql = %{
      SELECT page_title
      FROM page
      WHERE page_id = #{page_id}
      AND page_namespace = 0
    }
    @mb.repl.query(sql).to_a.first['page_title']
  end

  def self.is_page_creator_autopatrolled?(user_id)
    autopatrolled_user_ids.include?(user_id)
  end

  def self.is_page_creator_a_patroller?(user_id)
    patroller_user_ids.include?(user_id)
  end

  def self.page_creator(page_id)
    sql = %{
      SELECT rev_user
      FROM revision_userindex
      WHERE rev_page = #{page_id}
      ORDER BY rev_id ASC
      LIMIT 1
    }
    @mb.repl.query(sql).to_a.first['rev_user']
  end

  def self.autopatrolled_user_ids
    return @autopatrolled_user_ids if @autopatrolled_user_ids
    sql = %{
      SELECT ug_user
      FROM user_groups
      WHERE ug_group = 'autoreviewer'
    }
    @autopatrolled_user_ids = @mb.repl.query(sql).to_a.collect { |ug| ug['ug_user'] }
  end

  def self.patroller_user_ids
    return @patroller_user_ids if @patroller_user_ids
    sql = %{
      SELECT ug_user
      FROM user_groups
      WHERE ug_group = 'patroller'
    }
    @patroller_user_ids = @mb.repl.query(sql).to_a.collect { |ug| ug['ug_user'] }
  end

  def self.pages_to_check
    sql = %{
      SELECT ptrp_page_id, ptrp_reviewed
      FROM pagetriage_page
      JOIN page ON page_id = ptrp_page_id
      WHERE page_is_redirect = 0
      AND page_namespace = 0
      AND ptrp_created BETWEEN 20170401000000 AND 20170501000000
    }
    @mb.repl.query(sql).to_a
  end

  def self.repl_query(sql, *values)
    statement = @mb.repl(replicas: false).prepare(sql)
    statement.execute(*values).to_a
  end
end

NPPReport.run
