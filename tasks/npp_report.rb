$LOAD_PATH << '..'
require 'musikbot'

module NPPReport
  def self.run
    @mb = MusikBot::Session.new(inspect, true)
    @disk_cache = @mb.local_storage || {}

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
