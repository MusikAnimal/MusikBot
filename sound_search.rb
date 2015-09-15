$LOAD_PATH << '.'

require 'mediawiki-gateway'
require 'auth.rb'
require 'pry'

MediaWiki::Gateway.default_user_agent = 'MusikBot/1.1 (https://en.wikipedia.org/wiki/User:MusikBot/)'
enWikiMW = MediaWiki::Gateway.new("https://en.wikipedia.org/w/api.php")
commonsMW = MediaWiki::Gateway.new("https://commons.wikimedia.org/w/api.php")

composerListPage = "List of composers by name"
composerListSource = enWikiMW.get(composerListPage)
composerFiles = {}

composerListSource.split(/==\w+==/).drop(1).each_with_index do |composerSet, index| #/
  character = (index + 65).chr

  # may contain pipes, e.g. "Mozart (composer)|Mozart"
  composerStrings = composerSet.scan(/^\*\s*\[\[(.*?)\]\]/i).flatten

  composerStrings.each do |composerString|
    composer, composer2 = composerString.split("|")

    sleep 0.5

    newComposerFiles = commonsMW.custom_query({
      list: "categorymembers",
      cmtitle: "Category:#{composer}",
      cmtype: "file",
      cmlimit: 500
    })[0]

    if composer2 && composer2 = composer2.scan(/(.*)\]\]/).flatten[0]
      sleep 0.5
      newComposerFiles += commonsMW.custom_query({
        list: "categorymembers",
        cmtitle: "Category:#{composer2}",
        cmtype: "file",
        cmlimit: 500
      })[0]
    end

    newComposerFiles = newComposerFiles.to_a.collect{|cf| cf.attributes["title"].gsub(/File\:/,"")}.keep_if{|cf| cf.scan(/\.(?:ogg|flac|midi)$/i).any?}
    # newComposerFiles = newComposerFiles.delete_if{|cf| soundList.include?(cf)}

    if newComposerFiles.any?
      composerFiles[character] ||= {}
      composerFiles[character][composer] = newComposerFiles
    end

    puts "#{composerString} #{'-- ' + newComposerFiles.length.to_s + ' found' if newComposerFiles.any?}"
  end

  puts "=== #{character} SET COMPLETE ==="
  sleep 3
# end

soundListPages = [
  "A",
  "Ba"
  "Bb–Bz",
  "C",
  "D–G",
  "H",
  "I–L",
  "M",
  "N–Q",
  "R",
  "S",
  "T–Z"
].collect{|p| "Wikipedia:Sound/list/"+p}

for soundListPage in soundListPages
  soundListSource = enWikiMW.get(soundListPage)
  soundList = soundListSource.scan(/\[\[media:\s*(.*?.(?:ogg|flac|midi))/i).flatten

  binding.pry

  composerFiles.each do |composerSet|
    composerSet.each do |composer, files|
      composerSet[composer] = files.delete_if{|file| soundList.include?(file)}
    end
  end
end
