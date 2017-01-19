$LOAD_PATH << '..'
require 'musikbot'

module MassPageMover
  @mb = MusikBot::Session.new(inspect, true)

  def self.run
    pages_to_move.each do |page|
      new_title = "Draft:#{page}"
      @mb.gateway.move(page, new_title,
        noredirect: true,
        movetalk: true,
        movesubpages: true, # just in case
        reason: 'Moving to the draft space per [[User:Aymatth2/SvG clean-up/Guidelines]]'
      )
      new_content = @mb.get(new_title).gsub(/\[\[Category:(.*?)\]\]/, '[[:Category:\1]]')
      @mb.edit(new_title,
        content: new_content,
        summary: 'Deactivating categories'
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
