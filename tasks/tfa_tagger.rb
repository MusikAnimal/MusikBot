$LOAD_PATH << '..'
require 'musikbot'

module TFATagger
  def self.run
    @mb = MusikBot::Session.new(inspect)

    # The Toolforge grid engine may delay the bot till some time after midnight.
    # As a workaround, it is also ran before midnight. This code makes sure it's actually
    # at or past midnight so that we know we're looking at the right TFAs.
    return unless @mb.now.hour.zero? or @mb.env == 'test'

    today = @mb.now.strftime('%B %-d, %Y')
    yesterday = (@mb.now - 1).strftime('%B %-d, %Y')

    template = @mb.get('User:MusikBot/TFATagger/Template')

    # Add to current TFA.
    current_tfa = @mb.get("Template:TFA title/#{today}")
    @mb.edit(current_tfa,
      content: @mb.get(current_tfa).chomp + "\n{{#{template}}}",
      summary: "Tagging as {{[[:Template:#{template}|#{template}]]}}"
    )

    # Remove from previous TFA.
    prev_tfa = @mb.get("Template:TFA title/#{yesterday}")
    @mb.edit(prev_tfa,
      content: @mb.get(prev_tfa).sub(/\n{{#{template}}}/, ''),
      summary: "Removing {{[[:Template:#{template}|#{template}]]}}"
    )
  end
end

TFATagger.run
