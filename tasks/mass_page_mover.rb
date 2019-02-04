$LOAD_PATH << '..'
require 'musikbot'

module MassPageMover
  @mb = MusikBot::Session.new(inspect)

  def self.run
    counter = 0

    binding.pry

    while counter < 15 do
      counter += 1

      begin
        page = pages_to_move.pop
        new_title = "Draft:#{page}"
        failed_pages = []

        puts "#{counter} | #{page}"

        sleep 1

        @mb.gateway.move(page, new_title,
          noredirect: true,
          movetalk: true,
          movesubpages: true, # just in case
          reason: 'Moving to the draft space per [[User:Aymatth2/SvG clean-up/Guidelines]]'
        )
        sleep 1
        new_content = @mb.get(new_title).gsub(/\[\[Category:(.*?)\]\]/, '[[:Category:\1]]')
        @mb.edit(new_title,
          content: new_content,
          summary: 'Deactivating categories'
        )
      rescue => e
        print "\a" # ring a bell
        puts e.inspect
        failed_pages << page unless e.is_a?(MediaWiki::APIError) && e.code.to_s == 'missingtitle'
        next
      end
    end

    puts failed_pages

    binding.pry

    @mb.local_storage(pages_to_move)
  end

  def self.pages_to_move
    @pages_to_move ||= @mb.local_storage || @mb.repl.query("SELECT page_title FROM revision_userindex
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
