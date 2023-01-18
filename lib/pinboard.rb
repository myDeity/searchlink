class SearchLink
  def pinboard_bookmarks
    bookmarks = `/usr/bin/curl -sSL "https://api.pinboard.in/v1/posts/all?auth_token=#{@cfg['pinboard_api_key']}&format=json"`
    bookmarks = bookmarks.force_encoding('utf-8')
    bookmarks.gsub!(/[^[:ascii:]]/) do |non_ascii|
      non_ascii.force_encoding('utf-8')
               .encode('utf-16be')
               .unpack('H*')
               .gsub(/(....)/, '\u\1')
    end

    bookmarks.gsub!(/[\u{1F600}-\u{1F6FF}]/, '')

    bookmarks = JSON.parse(bookmarks)
    updated = Time.now
    { 'update_time' => updated, 'bookmarks' => bookmarks }
  end

  def save_pinboard_cache(cache)
    cachefile = PINBOARD_CACHE

    # file = File.new(cachefile,'w')
    # file = Zlib::GzipWriter.new(File.new(cachefile,'w'))
    begin
      File.open(cachefile, 'wb') {|f| f.write(Marshal.dump(cache))}
    rescue IOError
      add_error('Pinboard cache error', 'Failed to write stash to disk')
      return false
    end
    true
  end

  def get_pinboard_cache
    refresh_cache = false
    cachefile = PINBOARD_CACHE

    if File.exist?(cachefile)
      begin
        # file = IO.read(cachefile) # Zlib::GzipReader.open(cachefile)
        # cache = Marshal.load file
        cache = Marshal.load(File.binread(cachefile))
        # file.close
      rescue StandardError
        add_error('Error loading pinboard cache', "StandardError reading #{cachefile}")
        cache = pinboard_bookmarks
        save_pinboard_cache(cache)
      rescue IOError # Zlib::GzipFile::Error
        add_error('Error loading pinboard cache', "IOError reading #{cachefile}")
        cache = pinboard_bookmarks
        save_pinboard_cache(cache)
      end
      updated = JSON.parse(`/usr/bin/curl -sSL 'https://api.pinboard.in/v1/posts/update?auth_token=#{@cfg['pinboard_api_key']}&format=json'`)
      last_bookmark = Time.parse(updated['update_time'])
      if cache&.key?('update_time')
        last_update = cache['update_time']
        refresh_cache = true if last_update < last_bookmark
      else
        refresh_cache = true
      end
    else
      refresh_cache = true
    end

    if refresh_cache
      cache = pinboard_bookmarks
      save_pinboard_cache(cache)
    end

    cache
  end

  # Search pinboard bookmarks
  # Begin query with '' to force exact matching (including description text)
  # Regular matching searches for each word of query and scores the bookmarks
  # exact matches in title get highest score
  # exact matches in description get second highest score
  # other bookmarks are scored based on the number of words that match
  #
  # After sorting by score, bookmarks will be sorted by date and the most recent
  # will be returned
  #
  # Exact matching is case and punctuation insensitive
  def pinboard(terms)
    unless @cfg['pinboard_api_key']
      add_error('Missing Pinboard API token',
                'Find your api key at https://pinboard.in/settings/password and add it
                to your configuration (pinboard_api_key: YOURKEY)')
      return false
    end

    top = nil

    # If search terms start with ''term, only search for exact string matches
    if terms =~ /^ *'/
      exact_match = true
      terms.gsub!(/(^ *'+|'+ *$)/, '')
    else
      exact_match = false
    end

    cache = get_pinboard_cache
    # cache = pinboard_bookmarks
    bookmarks = cache['bookmarks']

    if exact_match
      bookmarks.each do |bm|
        text = [bm['description'], bm['extended'], bm['tags']].join(' ')

        return [bm['href'], bm['description']] if text.matches_exact(terms)
      end

      return false
    else
      matches = []
      bookmarks.each do |bm|
        title_tags = [bm['description'], bm['tags']].join(' ')
        full_text = [bm['description'], bm['extended'], bm['tags']].join(' ')
        score = 0

        score = if title_tags.matches_exact(terms)
                  14.0
                elsif full_text.matches_exact(terms)
                  13.0
                elsif full_text.matches_any(terms)
                  full_text.matches_score(terms)
                else
                  0
                end

        if score == 14
          return [bm['href'], bm['description']]
        elsif score.positive?
          matches.push({
            score: score,
            href: bm['href'],
            title: bm['description'],
            date: bm['time']
          })
        end
      end

      return false if matches.empty?

      top = matches.sort_by { |bm| [bm[:score], bm[:date]] }.last
    end

    return false unless top

    [top[:href], top[:title]]
  end
end
