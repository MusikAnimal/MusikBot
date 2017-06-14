$LOAD_PATH << '..'
require 'musikbot'

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

    patroller_review_stats
    article_survival_stats
  end

  # ARTICLE SURVIVAL STATS

  def self.article_survival_stats
    stats = {
      created: 0,
      autoconfirmed: {
        created: 0,
        revdel: 0,
        deleted: {
          total: 0,
          speedy: 0,
          prod: 0,
          afd: 0,
          other: 0
        },
        now_redirect: 0
      },
      non_autoconfirmed: {
        created: 0,
        revdel: 0,
        deleted: {
          total: 0,
          speedy: 0,
          prod: 0,
          afd: 0,
          other: 0
        },
        now_redirect: 0
      }
    }

    num_pages = pages_created.length

    pages_processed = []

    pages_created.each_with_index do |page, i|
      next if page_was_redirect?(page) || pages_processed.include?(page['page_id'])

      pages_processed << page['page_id']

      stats_key = user_autoconfirmed?(
        page['user_id'], page['user_name'], page['timestamp']
      ) ? :autoconfirmed : :non_autoconfirmed

      puts "#{i} of #{num_pages}: #{page['title']} (#{page['deleted'] == 1 ? 'deleted, ' : ''}#{stats_key})"

      stats[:created] += 1
      stats[stats_key][:created] += 1

      # page_is_redirect comes from the page object, which only exists if the page is live
      if page['redirect'] == 1
        stats[stats_key][:now_redirect] += 1
      elsif page['deleted'] == 1
        deletion_key = deletion_reason(page['page_id'])
        stats[stats_key][:deleted][:total] += 1
        stats[stats_key][:deleted][deletion_key.to_sym] += 1
      end
    end

    @mb.local_storage(stats)

    puts stats
  end

  def self.page_was_redirect?(page_props)
    if page_props['deleted'] == 1
      !!(page_props['comment'] =~ /Redirected/i)
    else
      begin
        content = @mb.get_revision_at_date(page_props['title'], page_props['timestamp'])
        !!(content =~ /^#REDIRECT \[\[.*?\]\]/i)
      rescue => e
        # This sometimes happens if the page was so big that Rexml library breaks.
        # In such cases it's safe to assume the page was not a redirect.
        false
      end
    end
  end

  def self.user_autoconfirmed?(user_id, username, timestamp)
    # IPs may create articles through AfC
    return false if user_id == 0

    # Check if they were granted (semi|extended)confirmed prior to creating the article
    sql = %{
      SELECT COUNT(*) AS count
      FROM logging
      WHERE log_type = 'rights'
      AND log_title = ?
      AND log_params REGEXP ".*?confirmed"
      AND log_timestamp < ?
    }
    return true if @mb.repl_query(sql, username.score, timestamp).to_a.first['count'] > 0

    # Check if the account was under 4 days old at the time they created the article
    sql = %{
      SELECT user_registration
      FROM user
      WHERE user_name = ?
    }
    registration = @mb.repl_query(sql, username.descore).to_a.first['user_registration']

    # Some really old accounts mysteriously don't have a registration date
    # We'll just have to assume they made at least 10 edits
    return true if registration.nil?

    age_at_creation = (@mb.parse_date(timestamp.to_s) - @mb.parse_date(registration)).to_i
    return false if age_at_creation < 4

    # Check if the account has an edit count of less than 10 when they created the article
    sql = %{
      SELECT COUNT(*) AS count
      FROM revision
      WHERE rev_user = ?
      AND rev_timestamp BETWEEN #{registration} AND #{timestamp}
    }
    edits_at_creation = @mb.repl_query(sql, user_id).first['count']

    return false if edits_at_creation < 10

    true
  end

  def self.pages_created
    return @pages_created if @pages_created

    start_date = 20161101000000
    end_date = 20161108000000

    # Ask for pages between two IDs to speed up the query on revision
    # These were picked by looking at Special:NewPagesFeed
    #   and using the IDs of pages around the above date range
    lower_page_id = 52035284
    upper_page_id = 52532113

    sql = %{
      SELECT page_title AS title, rev_page AS page_id, rev_timestamp AS timestamp,
             rev_user AS user_id, rev_user_text AS user_name, 0 AS deleted,
             rev_comment AS comment, page_is_redirect AS redirect
      FROM revision
      JOIN page ON page_id = rev_page
      WHERE rev_page > #{lower_page_id}
      AND rev_page < #{upper_page_id}
      AND rev_parent_id = 0
      AND page_namespace = 0
      AND rev_timestamp BETWEEN #{start_date} AND #{end_date}
    }
    pages = @mb.repl.query(sql).to_a

    sql = %{
      SELECT ar_title AS title, ar_page_id AS page_id, ar_timestamp AS timestamp,
             ar_user AS user_id, ar_user_text AS user_name, 1 AS deleted,
             ar_comment AS comment, 0 AS redirect
      FROM archive
      WHERE ar_parent_id = 0
      AND ar_namespace = 0
      AND ar_timestamp BETWEEN #{start_date} AND #{end_date}
    }

    # Cache and return combined results of the two queries
    @pages_created = (pages + @mb.repl.query(sql).to_a).sort {|a, b| a['title'] <=> b['title']}
  end

  def self.deletion_reason(page_id)
    sql = %{
      SELECT log_comment
      FROM logging
      WHERE log_type = 'delete'
      AND log_page = #{page_id}
    }

    # rescue nil to handle pages where the revision or log entry was suppressed
    reason = @mb.repl.query(sql).to_a.first['log_comment'] rescue nil

    case reason
    when /\[\[WP:CSD#/
      'speedy'
    when /\[\[WP:(BLP)?PROD/
      'prod'
    when /\[\[(Wikipedia|WP):Articles for deletion\//
      'afd'
    else
      'other'
    end
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
end

NPPReport.run
