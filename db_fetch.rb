$LOAD_PATH << '.'
require 'auth.rb'

module DbFetch
  client = Mysql.new("enwiki.labsdb", Auth.username, Auth.password, "enwiki_p")

  def self.countAutomatedEdits(userName)
    toolRegexes = [
      "(?=WP:HG\|HG\|WP:Huggle)",                   # Huggle
      "WP:TW",                                      # Twinkle
      "WP:STiki",                                   # STiki
      "WP:GLOO",                                    # Igloo
      "Wikipedia:Tools\/Navigation_popups\|popups", # Popups
      "\(\[\[WP:AFCH\|AFCH\]\]\)",                  # AFCH
      "(?=Project:AWB\|AWB|WP:AWB)",                # AWB
      "\[\[(?:\:en\:)*WP:CLEANER\|WPCleaner\]\]",   # WP Cleaner
      "\(using \[\[WP:HOTCAT\|HotCat\]\]\)",        # HotCat
      "WP:REFILL"                                   # reFill
    ]

    res = client.query("SELECT count(*) FROM enwiki_p.revision_userindex WHERE rev_user_text=\"#{userName}\" " +
      "AND rev_comment rlike \"#{toolRegexes.join("|")}\"").fetch_row[0].to_i
  end
end