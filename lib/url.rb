class SearchLink
  def valid_link?(uri_str, limit = 5)
    notify('Validating', uri_str)
    return false if limit.zero?

    url = URI(uri_str)
    return true unless url.scheme

    url.path = '/' if url.path == ''
    # response = Net::HTTP.get_response(URI(uri_str))
    response = false

    Net::HTTP.start(url.host, url.port, use_ssl: url.scheme == 'https') do |http|
      response = http.request_head(url.path)
    end

    case response
    when Net::HTTPMethodNotAllowed, Net::HTTPServiceUnavailable
      unless /amazon\.com/ =~ url.host
        add_error('link validation', "Validation blocked: #{uri_str} (#{e})")
      end
      notify('Error validating', uri_str)
      true
    when Net::HTTPSuccess
      true
    when Net::HTTPRedirection
      location = response['location']
      valid_link?(location, limit - 1)
    else
      notify('Error validating', uri_str)
      false
    end
  rescue StandardError => e
    notify('Error validating', uri_str)
    add_error('link validation', "Possibly invalid => #{uri_str} (#{e})")
    true
  end

  def url?(input)
    input =~ %r{^(#.*|https?://\S+|/\S+|\S+/|[^!]\S+\.\S+)(\s+".*?")?$}
  end

  def only_url?(input)
    input =~ %r{(?i)^((http|https)://)?([\w\-_]+(\.[\w\-_]+)+)([\w\-.,@?^=%&amp;:/~+#]*[\w\-@^=%&amp;/~+#])?$}
  end

  def ref_title_for_url(url)
    url = URI.parse(url) if url.is_a?(String)

    parts = url.hostname.split(/\./)
    domain = if parts.count > 1
               parts.slice(-2, 1).join('')
             else
               parts.join('')
             end

    path = url.path.split(%r{/}).last
    if path
      path.gsub!(/-/, ' ').gsub!(/\.\w{2-4}$/, '')
    else
      path = domain
    end

    path.length > domain.length ? path : domain
  end

  def url_to_link(input, type)
    if only_url?(input)
      input.sub!(%r{(?mi)^(?!https?://)(.*?)$}, 'https://\1')
      url = URI.parse(input.downcase)

      title = if type == 'ref_title'
                ref_title_for_url(url)
              else
                titleize(url.to_s) || input.sub(%r{^https?://}, '')
              end

      return [url.to_s, title] if url.hostname
    end
    false
  end

  def amazon_affiliatize(url, amazon_partner)
    return url if amazon_partner.nil? || amazon_partner.empty?

    return [url, ''] unless url =~ %r{https?://(?:.*?)amazon.com/(?:(.*?)/)?([dg])p/([^?]+)}

    m = Regexp.last_match
    title = m[1]
    type = m[2]
    id = m[3]
    az_url = "http://www.amazon.com/#{type}p/product/#{id}/ref=as_li_ss_tl?ie=UTF8&linkCode=ll1&tag=#{amazon_partner}"
    [az_url, title]
  end

  def titleize(url)
    title = nil

    gather = false
    ['/usr/local/bin', '/opt/homebrew/bin'].each do |root|
      if File.exist?(File.join(root, 'gather')) && File.executable?(File.join(root, 'gather'))
        gather = File.join(root, 'gather')
        break
      end
    end

    if gather
      title = `#{gather} --title-only '#{url.strip}' --fallback-title 'Unkown'`
      return title.gsub(/\n+/, ' ').gsub(/ +/, ' ')
    end

    begin
      # source = %x{/usr/bin/curl -sSL '#{url.strip}'}

      uri = URI.parse(url)
      res = Net::HTTP.get_response(uri)

      if res.code.to_i == 200
        source = res.body
        title = source ? source.match(%r{<title>(.*)</title>}im) : nil

        title = title.nil? ? nil : title[1].strip
      end

      if title.nil? || title =~ /^\s*$/
        warn "Warning: missing title for #{url.strip}"
        title = url.gsub(%r{(^https?://|/.*$)}, '').gsub(/-/, ' ').strip
      else
        title = title.gsub(/\n/, ' ').gsub(/\s+/, ' ').strip # .sub(/[^a-z]*$/i,'')
      end

      # Skipping SEO removal until it's more reliable
      # title.remove_seo(url.strip)
      title
    rescue StandardError => e
      warn "Error retrieving title for #{url.strip}"
      raise e
    end
  end
end
