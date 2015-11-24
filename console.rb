$LOAD_PATH << '.'
require 'musikbot'

module Console
  def self.run
    @mb = MusikBot::Session.new(inspect)

    binding.pry
  end
end

Console.run
