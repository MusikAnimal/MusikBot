$LOAD_PATH << '..'
require 'musikbot'

module MassPageMover
  @mb = MusikBot::Session.new(inspect)

  def self.run
    pages_to_move.each do |page|
      @mb.gateway.move(page, "Draft:#{page}",
        noredirect: true,
        movetalk: true,
        movesubpages: true, # just in case
        reason: 'Moving [[WP:BLP|BLP]]s created by [[User:Sander.v.Ginkel]] to the draftspace per [[Special:PermaLink/759098518]]'
      )
    end
  end

  def self.pages_to_move
    @mb.repl.query("SELECT page_title FROM revision_userindex
      JOIN categorylinks
      JOIN page
      WHERE rev_user_text = 'Sander.v.Ginkel'
      AND rev_timestamp > 0
      AND rev_parent_id = 0
      AND page_namespace = 0
      AND page_is_redirect = 0
      AND cl_from = rev_page
      AND cl_to = 'Living_people'
      AND page_id = rev_page"
    ).to_a.collect { |a| a['page_title'] }
  end
end

MassPageMover.run
