$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'
require 'open-uri'
require 'nokogiri'

module SPCodex
  def self.run
  	@mb = MusikBot::Session.new(inspect)
  	@local_storage = @mb.local_storage

  	import_show('The Smashing Pumpkins', '2008-10-31')
  end

  def self.import_show(artist, date)
  	old_splra_title = splra_title(artist, date)
  	response = HTTParty.get("http://www.splra.org/wiki/api.php?action=query&prop=revisions&titles=#{old_splra_title}&rvprop=content&format=json")
  	old_wikitext = response['query']['pages'][response['query']['pages'].keys[0]]['revisions'][0]['*']

  	parts = old_wikitext.split(/==\s*Setlist\s*==/i)
  	setlist_part = parts[1].split('==')[0]
  	setlist_part.sub!("\n----\n", '')

  	new_setlist = ''
  	setlist_part.split("\n").each do |line|
  		puts line
  		if line =~ /\s*(Set|Encore).*?:$/
  			heading = "\n=== #{line.chomp('').chomp(':').downcase.ucfirst} ===\n"
  			puts heading
  			new_setlist += heading
  			next
		end

		if line =~ /^\*+ \(/
			# Probably not a song
			new_setlist += line + "\n"
			next
		end

		level = line.scan(/^\*+/).flatten.first.length
		# input_song_name = line.scan(/\*[^\*]\s*(.*?)\s*([\[\n])/).flatten.first.to_s.chomp('')
		input_song_name = line.scan(/\*[^\*]\s*(.*?)\s*(?:\[.*)?$/).flatten.first.to_s.chomp('')
		page_title = nil

		song_matches = get_song_matches(input_song_name)
		if song_matches.length > 1
			puts "\n____________MULTIPLE POSSIBLE SONGS__________________"
			print 'song name? '
			song_name = gets.chomp('')
			print 'page title? '
			page_title = gets.chomp('')
			@local_storage['songs'][song_name.to_s] = page_title
			binding.pry
		elsif song_matches.length == 0
			puts "\n________________NO SONGS FOUND__________________"

			# Typo
			print "Typo? (y/n)"
			if 'y' == gets.chomp('')
				print "Correct name: "
				song_name = gets.chomp('')
				page_title = @local_storage['songs'][song_name.to_s]

				unless page_title
					print "Page title: "
					page_title = gets.chomp('')
					@local_storage['songs'][song_name.to_s] = page_title
				end

				binding.pry
				@local_storage['aliases'][input_song_name] = song_name
				@mb.local_storage(@local_storage)
			else
				song_name = input_song_name
			end
		else
			# Exact match.
			song_name = song_matches.keys.first
		end

		new_line = ('#' * level) + " {{live song|#{song_name}"

		# Song title
		if page_title && song_name != page_title
			new_line += "|title=#{page_title}"
		end

		# Tease?
		if line.include?('(tease)')
			line.sub!('(tease)', '')
			new_line += "|tease=1"
		end

		# Cover
		cover = line.scan(/\[(.*?)\]/).flatten.first.to_s.chomp('')
		if @local_storage['covers_aliases'][cover]
			cover = @local_storage['covers_aliases'][cover]
		end
		if cover.present? && @local_storage['covers'].keys.include?(cover)
			cover_wp = @local_storage['covers'][cover]
			new_line += "|cover=[[w:#{cover_wp}|#{cover}]]"
		elsif cover.present?
			puts "\n____________UNKNOWN COVER:________________"
			print "Artist (from input)? "
			cover_artist = gets.chomp('')
			print "Wikipedia article? "
			artist_wp = gets.chomp('')
			@local_storage['covers'][cover_artist.chomp('')] = artist_wp.chomp('')
			binding.pry
			@mb.local_storage(@local_storage)
			new_line += "|cover=[[w:#{artist_wp}|#{cover_artist}]]"
		end

		# Notes
		notes = line.scan(/\((.*?)\)$/).flatten.first.to_s.chomp('')
		if notes.present?
			new_line += "|notes=#{notes}"
		end
		new_line += "}}"

		puts new_line

		# Concat
		new_setlist += new_line + "\n"
  	end

  	binding.pry
  end

  def self.get_song_matches(input)
  	matches = {}
  	if @local_storage['aliases'] && @local_storage['aliases'][input]
  		input = @local_storage['aliases'][input]
  	end
  	@local_storage['songs'].each do |song_name, page_title|
  		if input.include?(song_name) && song_name.length >= input.length
  			matches[song_name] = page_title
  		end
  	end
  	# if matches.empty?
  	# 	matches = {
  	# 		"#{input}": input
  	# 	}
  	# end
  	return matches
  end

  def self.splra_title(artist, date)
  	prefix = if artist == 'The Smashing Pumpkins'
  		'Tsp'
  	elsif artist == 'James Iha'
  		'Ji'
  	elsif artist == 'Billy Corgan'
  		'Bc'
  	elsif artist == 'Jimmy Chamberlin Complex'
  		'Jcc'
  	else
  		artist
  	end

  	"#{prefix}#{date}"
  end

  def self.import_images(page)
  	ret = HTTParty.get("http://www.splra.org/wiki/api.php?action=query&prop=images&titles=#{page}&imlimit=500&format=json")
  	page_id = ret['query']['pages'].keys[0]
  	images = ret['query']['pages'][page_id]['images'].map { |i| i['title'] }

  	url_ret = HTTParty.get("http://www.splra.org/wiki/api.php?action=query&titles=#{images.join('|')}&prop=imageinfo&iiprop=url&format=json")
  	ids = url_ret['query']['pages'].keys
  	ids.each do |id|
  		url = url_ret['query']['pages'][id]['imageinfo'][0]['url']
  		source_file_url = url_ret['query']['pages'][id]['imageinfo'][0]['descriptionurl']
  		title = URI.decode(url.split('/').last)
  		puts title

  		@mb.gateway.upload(
  			nil,
  			'filename' => title,
  			'url' => url,
  			'comment' => "Imported from #{source_file_url}"
  		)
  	end
  rescue => e
  	binding.pry
  end

  def self.add_availability
  	songs = @mb.gateway.custom_query(
  		list: 'categorymembers',
  		cmtitle: 'Category:Songs',
  		cmprop: 'title',
  		cmtype: 'page',
  		cmlimit: 500
  	)[0].to_a.collect { |s| s['title'] }

  	songs.each do |song|
  		content = @mb.get(song)

  		next if content.include?('{{availability}}')

  		sections = content.scan(/==\s*(.*?)\s*==/).flatten

  		if sections.include?('References')
  			content.gsub!(
  				/==\s*References\s*==/,
  				"{{availability}}\n\n== References =="
  			)
  		elsif sections.include?('External links')
  			content.gsub!(
  				/==\s*External links\s*==/,
  				"{{availability}}\n\n== External links =="
  			)
  		else
  			content = content.chomp + "\n\n{{availability}}"
  		end

  		puts song

  		@mb.edit(song,
  			content: content,
  			summary: 'Adding {{availability}} section'
  		)
  	end
  end

  def self.purge_template_uses(template)
  	ret = @mb.gateway.custom_query(
  		prop: 'transcludedin',
  		titles: template,
  		tilimit: 5000
  	)

  	ret.elements['pages'][0].elements['transcludedin'].to_a.each do |transclusion|
  		title = transclusion['title']
  		puts title
  		content = @mb.get(title)
  		@mb.edit(title, content: content)
  	end
  end

  def self.import_shows
  	url = 'http://www.spfc.org/tours/date.html?tour_id='

  	for i in 1..100
  		content = Nokogiri::HTML(open("#{url}#{i}"))

  		binding.pry
  	end
  end

  def self.fix_spfc_links
  	songlist = Nokogiri::HTML(open("http://www.spfc.org/songs-releases/song.html?song_type=1").read).css('table table .small_white a')

  	songlist.each do |song_node|
  		url = song_node.attributes['href'].to_s
  		title = song_node.children[0].to_s
  		title.gsub!(/\[.*?\]$/, '')
		title.strip!

		puts "Processing \"#{title}\""

  		url = "http://www.spfc.org#{song_node.attributes['href'].to_s}"
  		spfc_id = url.scan(/song_id=(\d+)/).flatten.first

  		spc_content = @mb.get(title)

  		if spc_content.blank?
  			title.gsub!(/ \(song \)$/, '')
  			spc_content = @mb.get(title)

  			if spc_content.blank?
  				puts "  No article, skipping"
  				next
  			end
  		end

  		if spc_content.scan(/\{\{SPFC\|song\|(\d+)\}\}/).flatten.first == spfc_id
  			# puts "  Already present, skipping"
  			next
  		end

  		old = spc_content.scan(/\{\{SPFC.*?\}\}/).first
  		ext_links = spc_content.scan(/==\s*External links\s*==/).first

  		if old
  			spc_content.sub!(old, "{{SPFC|song|#{spfc_id}}}")
  			@mb.edit(title,
				content: spc_content,
				summary: 'Correcting SPFC ID'
			)
			next
  		elsif ext_links
  			spc_content.sub!(ext_links, "#{ext_links}\n\n* {{SPFC|song|#{spfc_id}}}")
  			@mb.edit(title,
				content: spc_content,
				summary: 'Adding link to SPFC entry'
			)
			next
  		elsif spc_content.include?("{{The Smashing Pumpkins}}")
  			spc_content.sub!("{{The Smashing Pumpkins}}", "== External links ==\n* {{SPFC|song|#{spfc_id}}}\n\n{{The Smashing Pumpkins}}")
  			summary = 'Adding external links section with link to SPFC entry'
  		elsif spc_content.include?("{{Smashing Pumpkins}}")
  			spc_content.sub!("{{Smashing Pumpkins}}", "== External links ==\n* {{SPFC|song|#{spfc_id}}}\n\n{{The Smashing Pumpkins}}")
  			summary = 'Adding external links section with link to SPFC entry'
  		else
  			puts "  Could not be fixed"
  			binding.pry
  			next
  		end

  		puts "    #{summary}"
  		skip = false

  		binding.pry

  		next if skip

  		@mb.edit(title,
			content: spc_content,
			summary: summary
		)
  	end
  end

  def self.import_sfpc(song)
  	studios = ['Chicago Recording Company', 'Sunset Sound']
  	albums = ['Adore', 'Cotillions', 'TheFutureEmbrace', 'Gish', "If All Goes Wrong", "Judas O", "Let It Come Down", "Life Begins Again", "Look to the Sky", "Lost Highway (soundtrack)", "Machina/The Machines of God", "Machina II/The Friends & Enemies of Modern Music", "Mellon Collie and the Infinite Sadness", "Monuments to an Elegy", "Oceania", "Ogilala", "The Parable", "Pisces Iscariot", "Rarities and B-Sides", "Rotten Apples", "Shiny and Oh So Bright, Vol. 1 / LP: No Past. No Future. No Sun.", "Siamese Dream", "Siamese Singles", "Greatest Hits Video Collection (1991–2000)", "The Smashing Pumpkins 1991–1998", "Teargarden by Kaleidyscope", "Vieuphoria", "Zeitgeist"]

  	songlist = Nokogiri::HTML(open("http://www.spfc.org/songs-releases/song.html?song_type=1").read).css('a')

  	song_node = songlist.find do |node|
  		url = node.attributes['href'].to_s

  		url.include?('/songs-releases') && node.children[0].to_s == song
  	end

  	song = Nokogiri::HTML(open("http://www.spfc.org#{song_node.attributes['href'].to_s}"))

  	lyrics = ''

  	song.css('img[alt="Lyrics"]')[0].parent.parent.css('.small_white')[0].children.each do |node|
  		if node.class.to_s == 'Nokogiri::XML::Text'
  			lyrics += node.to_s.split.join(' ') + "\n"
  		end
  	end

	studio_text = song.css('img[alt="Studio"]')[0].next.next.css('a')[0].children[0].to_s

  	binding.pry
  end

  def self.import_album_spfc(id, album, intro)
  	container = Nokogiri::HTML(open("http://www.spfc.org/songs-releases/discog.html?discog_id=#{id}").read)

  	tracks = container.css('img[alt="Tracks"]')[0].next.next.css('a')

  	tracks.each do |track|
  		title = track.children[0].to_s

  		# Special handling
		title.gsub!(/\[.*?\]$/, '')
		title.strip!

  		puts "Processing \"#{title}\""

  		url = "http://www.spfc.org#{track.attributes['href'].to_s}"
  		spfc_id = url.scan(/=(\d+)/).flatten.first

  		next if @mb.get(title).present?

  		song = Nokogiri::HTML(open(url))

  		lyrics = ''

	  	# song.css('img[alt="Lyrics"]')[0].parent.parent.css('.small_white')[0].children.each do |node|
	  	# 	if node.class.to_s == 'Nokogiri::XML::Text'
	  	# 		binding.pry
	  	# 		lyrics += node.to_s.split.join(' ') + "\n"
	  	# 	end
	  	# end
	  	lyrics = song.css('img[alt="Lyrics"]')[0].parent.parent.css('.small_white')[0].children.to_s
	  		.gsub("\r", '').gsub("\t", '').chomp('').gsub('<br>', "\n").gsub("\n\n", "\n").strip
	  	lyrics.strip!

	  	if song.css('img[alt="Studio"]')[0]
			studio_text = song.css('img[alt="Studio"]')[0].next.next.css('a').children.to_s
		else
			studio_text = ''
		end
		# studio_list = []
		# rec_list = []
		# if studio_text.include?('Reel Time')
		# 	studio_list << 'Reel Time'
		# 	rec_list << '1989'
		# end
		# binding.pry
		# if studio_list.include?('Smart Studios')
		# 	studio_list << 'Smart Studios'
		# 	rec_list << 'December 1990 – March 1991'
		# end
		# studio = studio_list.join(', ')
		# recorded = rec_list.join(', ')

		# print "Recorded date? "
		# recorded = gets
		# # recorded = 'December 1990 – March 1991' if recorded.blank?
		# recorded.strip!
		recorded = ''

		# print "Studio? "
		# studio = gets
		# # studio = 'Sadlands' if studio.blank?
		# studio.strip!
		studio = ''

		# print "Release date? "
		# released = gets
		# released = 'January 28, 2003' if released.blank?
		# released.strip!
		released = 'January 28, 2003'

		print "Length? "
		length = gets.strip
		# length = ''

		print "Writer? "
		# writer = gets.strip
		# writer = 'Billy Corgan' if writer.blank?
		writer = ''

		# print "Producer? "
		#gets.strip
		producer = ''

		# print "Spotify? "
		# spotify = gets.strip
		spotify = ''

		content = %{{{Infobox song
| type = song
| name = #{title}
| artist = Zwan
| album = Mary Star of the Sea
| spotify = #{spotify}
| lyrics = #{lyrics.blank? ? 'no' : 'yes'}
| recorded = #{recorded}
| released = #{released}
| studio = #{studio}
| length = #{length}
| writer = #{writer}
| producer = #{producer}
}}

#{intro.sub('$1', title)}

== Lyrics ==
{{lyrics|1=#{lyrics}}}

== External links ==
* {{SPFC|song|#{spfc_id}}}
}

		@mb.edit(title,
			content: content,
			summary: "Import from SPFC: #{url}"
		)
		binding.pry
  	end
  end

  def self.delink_cats(page)
  	content = @mb.get(page, rvsection: 0)

  	content.gsub!(/\[\[:Category:Songs (?:produced|written) by .*?\|(.*?)\]\]/, '\1')
  	@mb.edit(page,
  		content: content,
  		section: 0,
  		summary: 'Delinking categories in infoboxes'
  	)
  end

  def self.upload_image(page)
  	puts "Processing #{page}"

  	# convert_interwiki(page)

  	# Upload image
  	content = @mb.get(page)
  	image = content.scan(/\|\s*cover\s*\=\s*(?:\[\[)?(.*?)(?:\]\])?\n/).flatten.first

  	if @mb.get("File:#{image}").nil? && image.scan(/\.jpe?g/).present?
  		puts "  Importing image"
  		import_file(image)
  	end

  	# binding.pry

  	# # Get the labels
  	# labels = content.scan(/(\|\s*label\s*\=(.*?)\n)/).flatten
  	# orig = labels[0]
  	# labels = labels[1]
  	# labels.slice(1, labels.length - 1).each do |label|
  	# 	content.gsub!('[[')
  	# end

  	# binding.pry
  	# @mb.edit(page,
  	# 	content: content,
  	# 	summary: 'Cleanup'
  	# )
  end

  def self.fix_wp_links(page)
  	puts "Fixing WP links on #{page}"

  	content = @mb.get(page)
  	refs = content.scan(/(<ref(?: name=.*?)?>.*?<\/ref>)/).flatten

  	refs.each do |ref|
  		new_ref = ref.clone
  		while new_ref.scan(/\[\[(?!w:).*?\]\]/).present?
	  		group, match = new_ref.scan(/(\[\[(?!w:.*?\|)?(.*?)\]\])/i).flatten
	  		binding.pry if match.nil?
	  		new_ref.sub!(group, "[[w:#{match.split('|').first}|#{match.split('|').last}]]")
	  	end
	  	content.sub!(ref, new_ref)
  	end

  	@mb.edit(page,
  		content: content,
  		summary: 'Transforming Wikipedia links to interwiki links'
  	)
  end

  def self.remove_tags(page)
  	original_content = @mb.get(page)
  	content = original_content.clone
  	content.gsub!(/{{short description.*?}}\n?/i, '')
	content.gsub!(/{{use mdy dates.*?}}\n?/i, '')
	content.gsub!(/{{for\|.*?}}\n?/i, '')
	content.gsub!(/{{ref\s*improve\|.*?}}\n?/i, '')
	content.gsub!(/{{(citation needed|cn)\|.*?}}\n?/i, '')
	content.gsub!(/{{(Use American English|use mdy dates)(?:\s*\|\s*.*?)}}\n?/i, '')
	content.gsub!(/{{(good|featured) article}}\n?/i, '')

	return if content == original_content

	puts "  Removing templates"

	@mb.edit(page,
		content: content,
		summary: 'Removing irrelevant templates'
	)
  end

  def self.convert_interwiki(page)
  	original_content = @mb.get(page)
  	content = original_content.clone
  	content.gsub!(/(\[\[)(allmusic|rolling stone)(.*?\]\])/i, '\1w:\2\3')

  	return if content == original_content

  	puts "  Converting interwiki links"

  	@mb.edit(page,
  		content: content,
  		summary: 'Convering to interwiki links'
  	)
  end

  def self.import_file(image)
  	ret = HTTParty.get("https://en.wikipedia.org/w/api.php?action=query&prop=imageinfo&iiprop=url&titles=File:#{image}&format=json&formatversion=2")
  	begin
  		url = ret['query']['pages'][0]['imageinfo'][0]['url']
  	rescue => e
  		binding.pry
  		return
  	end

  	@mb.gateway.upload(nil,
  		'url' => url,
  		'comment' => 'Importing non-free file from Wikipedia',
  		'text' => "== Licensing ==\n\n{{Non-free album cover}}"
  	)
  end

  def self.discogs(title)
  	ret = HTTParty.get("https://api.discogs.com/database/search?type=release&artist=The Smashing Pumpkins&release_title=#{title}&token=XOoGsGLiQiJAsTsZqaqmuhhkzbJqqFcJIwjfKwbv")
  	return ret['results'][0]['id']
  end
end

SPCodex.run
