$LOAD_PATH << '..'
require 'musikbot'
require 'httparty'
require 'open-uri'
require 'nokogiri'

module SPCodex
  def self.run
  	@mb = MusikBot::Session.new(inspect)
  	@local_storage = @mb.local_storage

  	# import_show('The Smashing Pumpkins', '2008-10-31')
  	import_show('The Smashing Pumpkins', '1994-02-25')
  end

  def self.import_show(artist, date)
  	splra_title = splra_title(artist, date)
  	response = HTTParty.get("http://www.splra.org/wiki/api.php?action=query&prop=revisions&titles=#{splra_title}&rvprop=content&format=json")
  	old_wikitext = response['query']['pages'][response['query']['pages'].keys[0]]['revisions'][0]['*']

  	parts = old_wikitext.split(/==\s*Setlist\s*==/i)

  	setlist_part = parts[1].split('==')[0]
  	if parts[1] =~ /\=\s*Notes/i
	  	notes_part = parts[1].split(/==\s*Notes?\s*=+/)[1].split(/^==.*/)[0]
	  end
	  if parts[1] =~ /\=\s*Banter/i
	  	banter_part = parts[1].split(/=\s*Banter\s*=+/)[1].split(/^==/)[0]
	  end

    @infobox_data = {}
	  infobox, recordings = get_infobox_and_recordings(splra_title)

    content = infobox
	  content += "\n== Setlist ==\n"
	  content += get_setlist(setlist_part)
	  content += get_notes(notes_part)
    content += get_banter(banter_part)
    content += get_images(splra_title)
    content += recordings

    binding.pry

    if @infobox_data[:date].present? && @infobox_data[:location].present?
      new_title = @infobox_data[:date] + " – " + @infobox_data[:location].gsub(/, US$/, '')
      @mb.edit(new_title,
        content: content,
        summary: "Imported live show from http://www.splra.org/wiki/index.php?title=#{splra_title}"
      )
    else
      binding.pry
    end
  rescue => e
    binding.pry
  end

  def self.get_infobox_and_recordings(title)
  	table = Nokogiri::HTML(open("http://www.splra.org/wiki/index.php?title=#{title}")).css('table')[0]

  	infobox_data = {}
  	infobox_completed = false
  	recordings = {}
  	recordings_key = nil
    new_rec_data = {}

  	table.css('tr').each_with_index do |tr, _i|
  		label = tr.css('th').text.chomp('').strip.downcase
  		value = tr.css('td').text.chomp('').strip

      value = '' if value.downcase == 'unknown'

  		# Infobox
  		unless infobox_completed
  			if value.blank? && infobox_data.blank?
  				infobox_data[:artist] = table.css('th')[0].text.chomp('').strip
					next
				elsif label.include?('date')
	  			infobox_data[:date] = @mb.parse_date(value).strftime('%B %-d, %Y')
					next
        elsif label.include?('type')
          infobox_data[:venue_type] = value
          next
	  		elsif label.include?('venue')
	  			infobox_data[:venue] = value
					next
				elsif label.include?('location')
	  			infobox_data[:location] = value
					next
	  		elsif label.include?('capacity')
	  			infobox_data[:capacity] = value.sub('~', '').gsub(',', '')
					next
	  		elsif label.include?('lineup')
	  			infobox_data[:lineup] = value
					next
	  		elsif label.include?('order of bands')
	  			infobox_data[:bands] = value
					next
	  		else
	  			infobox_completed = true
				end
			end

      if value.blank? && new_rec_data.present? && (tr.to_s.include?('#ffe156') || tr.to_s.include?('#fff9de'))
        puts "Inserting into #{recordings_key}"
        recordings[recordings_key] << new_rec_data
        new_rec_data = {}
      end

			# Recording info: first detect when we first hit recording info
      if label.include?('unsurfaced record')
        puts "  cleared unsurfaced"
        recordings_key = :unsurfaced
        recordings[:unsurfaced] = []
        next
			elsif label.include?('surfaced record')
        puts "  cleared surfaced"
				recordings_key = :surfaced
				recordings[:surfaced] = []
        next
			elsif label.include?('circulating recording')
        puts "  cleared circulating"
				recordings_key = :circulating
				recordings[:circulating] = []
        next
			end

			value = '' if value.downcase == 'unknown'

			if label.include?('source')
        new_rec_data[:source] = value
        next
			elsif label.include?('format')
				new_rec_data[:format] = value
        next
			elsif label.include?('equipment')
				new_rec_data[:equipment] = value
        next
			elsif label.include?('length')
        if value.blank?
          new_rec_data[:length] = ''
        else
  				mins = value.scan(/\d+/).flatten.first.to_i
          mod = mins % 60
    			new_rec_data[:length] = "#{mins / 60}:#{mod < 10 ? '0' + mod.to_s : mod}:00"
        end
        next
			elsif label.include?('complete')
				new_rec_data[:complete] = value
        next
			elsif label.include?('lowest')
				new_rec_data[:lowest_gen] = value
        next
			elsif label.include?('archive')
        uri = URI.extract(tr.css('td').to_s).first rescue nil
        if uri.present?
          new_rec_data[:archive] = "[#{uri} #{value}]"
        end
        next
			elsif label.include?('notes')
				new_rec_data[:notes] = value
        next
			end
  	end

    if new_rec_data.present?
      recordings[recordings_key] << new_rec_data
    end

    @infobox_data = infobox_data

  	[get_infobox(infobox_data), get_recordings(recordings)]
  end

  def self.get_infobox(data)
    coords = get_coorindates(data[:venue])

  	%{{{infobox live show
| artist = #{data[:artist]}
| date = #{data[:date]}
| venue = [[w:#{data[:venue]}|#{data[:venue]}]]
| location = #{data[:location]}
| venue_type = #{data[:venue_type]}
| location = #{data[:location]}
| lat = #{coords.present? ? coords[:lat] : ''}
| lng = #{coords.present? ? coords[:lng] : ''}
| capacity = #{data[:capacity]}
| lineup = #{data[:lineup]}
| bands = #{data[:bands]}
}}
}
  end

  def self.get_coorindates(venue)
    ret = HTTParty.get("https://en.wikipedia.org/w/api.php?action=query&prop=coordinates&titles=#{venue}&redirects=1&format=json&formatversion=2")

    return nil unless ret['query']['pages'][0] && ret['query']['pages'][0]['coordinates']
    coords = ret['query']['pages'][0]['coordinates'][0]

    {
      lat: coords['lat'],
      lng: coords['lon']
    }
  end

  def self.get_recordings(data)
  	out = "== Recordings ==\n"

  	data.keys.each do |type|
  		out += "\n=== #{type.to_s.ucfirst} ==="
      out += "\n{{live recordings top" + (type == :unsurfaced ? "|unsurfaced=yes" : "") + "}}"

  		data[type].each do |datum|
  			out += "\n{{live recording|source=#{datum[:source]}|format=#{datum[:format]}|equipment=#{datum[:equipment]}|length=#{datum[:length]}|complete=#{datum[:complete]}"
  			if [:circulating, :surfaced].include?(type)
  				out += "|lowest_gen=#{datum[:lowest_gen]}|archive=#{datum[:archive]}"
  			end
  			out += "|notes=#{datum[:notes]}}}"
  		end

      out += "\n{{live recordings bottom}}\n"
  	end

  	out
  end

  def self.get_banter(banter_part)
  	banter_part.sub!('<blockquote>', '{{banter|1=')
  	banter_part.sub!('</blockquote>', '}}')
  	banter_part.gsub!(/<\s*br\s*\/?\s*>/, '')
  	banter_part.gsub!(/\n+/, "\n")
    banter_part.scan(/<b>(.*?)<\/b>/m).flatten.each do |part|
      new_part = ''
      part.split("\n").each do |song|
        new_part += "'''#{song}'''\n"
      end
      banter_part.sub!(part, new_part)
    end
    banter_part.gsub!(/<\/?b>/, '')
    banter_part.gsub!(/\n+/, "\n")
  	"\n== Banter ==\n" + banter_part
  end

  def self.get_notes(notes_part) #, songs)
  	# songs.each do |song|
  	# 	notes_part.gsub!(song, "\"#{song}\"")
  	# end
  	"\n=== Notes ===\n" + notes_part.chomp('') + "\n"
  end

  def self.get_setlist(setlist_part)
  	setlist_part.sub!("\n----\n", '')
  	new_setlist = ''
  	songs = []
  	setlist_part.split("\n").each do |line|
  		if line =~ /\s*(Set|Encore).*?:$/
        heading_text = line.chomp('').chomp(':').downcase.ucfirst
        next if heading_text == 'Set' # redundant

  			heading = "\n=== #{heading_text} ===\n"
  			puts heading
  			new_setlist += heading
  			next
		  end

      level = line.scan(/^\*+/).flatten.first.length

  		if line =~ /^\*+ \(/
  			# Probably not a song
  			new_setlist += line.gsub(/^\*+/, '#' * level) + "\n"
  			next
  		end

  		# input_song_name = line.scan(/\*[^\*]\s*(.*?)\s*([\[\n])/).flatten.first.to_s.chomp('')
  		input_song_name = line.scan(/\*[^\*]\s*(.*?)\s*(?:\[.*)?$/).flatten.first.to_s.chomp('')
        .sub(' (tease)', '')
  		page_title = nil

  		song_matches = get_song_matches(input_song_name)
  		if song_matches.length > 1
  			puts "\n____________MULTIPLE POSSIBLE SONGS__________________ (#{input_song_name})"
  			print 'song name? '
  			song_name = gets.chomp('')
  			print 'page title? '
  			page_title = gets.chomp('')
  			@local_storage['songs'][song_name.to_s] = page_title
  		elsif song_matches.length == 0
  			puts "\n________________NO SONGS FOUND__________________ (#{input_song_name})"

  			print "Is a song? (y/n) "
  			if 'n' == gets.chomp('')
  				new_setlist += line + "\n"
  				next
  			end

  			# Ask for fixes, just in case.
  			print "Correct name: "
  			song_name = gets.chomp('')
  			page_title = @local_storage['songs'][song_name.to_s]

  			unless page_title
  				print "Page title: "
  				page_title = gets.chomp('')
  				@local_storage['songs'][song_name.to_s] = page_title
  			end

  			# Save this alias, if needed.
  			if input_song_name != song_name
  				@local_storage['aliases'][input_song_name] = song_name
  			end

  			# Save!
  			@mb.local_storage(@local_storage)
		  else
        # Exact match.
        song_name = song_matches.keys.first
		  end

  		new_line = ('#' * level) + " {{live song|#{song_name}"
  		songs << song_name

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
  		# NOTE: intentionally trimming the song durations (which also use [] syntax), for now...
  		elsif cover.present? && !cover =~ /(?:\d+)?:\d+(?:\d+)?/
  			puts "\n____________UNKNOWN COVER:________________ (#{cover})"
  			print "Artist (from input)? "
  			cover_artist = gets.chomp('')
  			print "Wikipedia article? "
  			artist_wp = gets.chomp('')
  			@local_storage['covers'][cover_artist.chomp('')] = artist_wp.chomp('')
  			@mb.local_storage(@local_storage)
  			new_line += "|cover=[[w:#{artist_wp}|#{cover_artist}]]"
  		end

      # Length
      length = line.scan(/\[(\d+:\d+)\]/).flatten.first
      if length
        new_line += "|length=#{length}"
      end

  		# Note
  		note = line.sub(song_name, '').scan(/\((.*?)\)/).flatten.first.to_s.chomp('')
  		if note.present?
  			new_line += "|note=#{note}"
  		end
  		new_line += "}}"

  		puts new_line

  		# Concat
  		new_setlist += new_line + "\n"
  	end

  	return new_setlist#, songs
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

  def self.get_images(page)
    images = import_images(page)
    return '' unless images.present?
    "\n== Photos and memorabilia ==\n<gallery mode=\"packed\">\n#{images.join("\n")}\n</gallery>\n\n"
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

    images
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
