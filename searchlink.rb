#!/usr/bin/env ruby
# encoding: utf-8

SILENT = ENV['SL_SILENT'] =~ /false/i ? false : true
VERSION = '2.3.10'

# SearchLink by Brett Terpstra 2015 <http://brettterpstra.com/projects/searchlink/>
# MIT License, please maintain attribution
require 'net/https'
require 'uri'
require 'rexml/document'
require 'shellwords'
require 'yaml'
require 'cgi'
require 'fileutils'
require 'tempfile'
require 'zlib'
require 'time'
require 'json'
require 'erb'

if RUBY_VERSION.to_f > 1.9
  Encoding.default_external = Encoding::UTF_8
  Encoding.default_internal = Encoding::UTF_8
end

PINBOARD_CACHE = File.expand_path('~/.searchlink_cache')

# Array helpers
class Array
  def longest_element
    group_by(&:size).max.last[0]
  end
end

# String helpers
class ::String
  def slugify
    downcase.gsub(/[^a-z0-9_]/i, '-').gsub(/-+/, '-')
  end

  def slugify!
    replace slugify
  end

  def clean
    gsub(/\n+/, ' ')
      .gsub(/"/, '&quot')
      .gsub(/\|/, '-')
      .gsub(/([&?]utm_[scm].+=[^&\s!,.)\]]++?)+(&.*)/, '\2')
      .sub(/\?&/, '').strip
  end

  # convert itunes to apple music link
  def to_am
    input = dup
    input.sub!(%r{/itunes\.apple\.com}, 'geo.itunes.apple.com')
    append = input =~ %r{\?[^/]+=} ? '&app=music' : '?app=music'
    input + append
  end

  def path_elements
    path = URI.parse(self).path
    path.sub!(%r{/?$}, '/')
    path.sub!(%r{/[^/]+[.\-][^/]+/$}, '')
    path.gsub!(%r{(^/|/$)}, '')
    path.split(%r{/}).delete_if { |section| section =~ /^\d+$/ || section.length < 5 }
  end

  def close_punctuation!
    replace close_punctuation
  end

  def close_punctuation
    return self unless self =~ /[“‘\[(<]/

    words = split(/\s+/)

    punct_chars = {
      '“' => '”',
      '‘' => '’',
      '[' => ']',
      '(' => ')',
      '<' => '>'
    }

    left_punct = []

    words.each do |w|
      punct_chars.each do |k, v|
        left_punct.push(k) if w =~ /#{Regexp.escape(k)}/
        left_punct.delete_at(left_punct.rindex(k)) if w =~ /#{Regexp.escape(v)}/
      end
    end

    tail = ''
    left_punct.reverse.each { |c| tail += punct_chars[c] }

    gsub(/[^a-z)\]’”.…]+$/i, '...').strip + tail
  end

  def remove_seo!(url)
    replace remove_seo(url)
  end

  def remove_seo(url)
    title = dup
    url = URI.parse(url)
    host = url.hostname
    path = url.path
    root_page = path =~ %r{^/?$} ? true : false

    title.gsub!(/\s*(&ndash;|&mdash;)\s*/, ' - ')
    title.gsub!(/&[lr]dquo;/, '"')
    title.gsub!(/&[lr]dquo;/, "'")

    seo_title_separators = %w[| « - – · :]

    begin
      re_parts = []

      host_parts = host.sub(/(?:www\.)?(.*?)\.[^.]+$/, '\1').split(/\./).delete_if { |p| p.length < 3 }
      h_re = !host_parts.empty? ? host_parts.map { |seg| seg.downcase.split(//).join('.?') }.join('|') : ''
      re_parts.push(h_re) unless h_re.empty?

      # p_re = path.path_elements.map{|seg| seg.downcase.split(//).join('.?') }.join('|')
      # re_parts.push(p_re) if p_re.length > 0

      site_re = "(#{re_parts.join('|')})"

      dead_switch = 0

      while title.downcase.gsub(/[^a-z]/i, '') =~ /#{site_re}/i

        break if dead_switch > 5

        seo_title_separators.each_with_index do |sep, i|
          parts = title.split(/ ?#{Regexp.escape(sep)} +/)

          next if parts.length == 1

          remaining_separators = seo_title_separators[i..-1].map { |s| Regexp.escape(s) }.join('')
          seps = Regexp.new("^[^#{remaining_separators}]+$")

          longest = parts.longest_element.strip

          unless parts.empty?
            parts.delete_if do |pt|
              compressed = pt.strip.downcase.gsub(/[^a-z]/i, '')
              compressed =~ /#{site_re}/ && pt =~ seps ? !root_page : false
            end
          end

          title = if parts.empty?
                    longest
                  elsif parts.length < 2
                    parts.join(sep)
                  elsif parts.length > 2
                    parts.longest_element.strip
                  else
                    parts.join(sep)
                  end
        end
        dead_switch += 1
      end
    rescue StandardError => e
      return self unless $cfg['debug']
      warn 'Error processing title'
      p e
      raise e
      # return self
    end

    seps = Regexp.new("[#{seo_title_separators.map { |s| Regexp.escape(s) }.join('')}]")
    if title =~ seps
      seo_parts = title.split(seps)
      title = seo_parts.longest_element.strip if seo_parts.length.positive?
    end

    title && title.length > 5 ? title.gsub(/\s+/, ' ') : self
  end

  def truncate!(max)
    replace truncate(max)
  end

  def truncate(max)
    return self if length < max

    max -= 3
    counter = 0
    trunc_title = ''

    words = split(/\s+/)
    while trunc_title.length < max && counter < words.length
      trunc_title += " #{words[counter]}"
      break if trunc_title.length + 1 > max

      counter += 1
    end

    trunc_title = words[0] if trunc_title.nil? || trunc_title.empty?

    trunc_title
  end

  def nil_if_missing
    return nil if self =~ /missing value/

    self
  end

  def split_hook
    elements = split(/\|\|/)
    {
      name: elements[0].nil_if_missing,
      url: elements[1].nil_if_missing,
      path: elements[2].nil_if_missing
    }
  end

  def split_hooks
    split(/\^\^/).map(&:split_hook)
  end

  def matches_score(terms, separator: ' ', start_word: true)
    matched = 0
    regexes = terms.to_rx_array(separator: separator, start_word: start_word)

    regexes.each do |rx|
      matched += 1 if self =~ rx
    end

    (matched / regexes.count.to_f) * 10
  end

  def matches_exact(string)
    comp = gsub(/[^a-z0-9 ]/i, '')
    comp =~ /\b#{string.gsub(/[^a-z0-9 ]/i, '').split(/ +/).map { |s| Regexp.escape(s) }.join(' +')}/i
  end

  def matches_none(terms)
    terms.to_rx_array.each { |rx| return false if gsub(/[^a-z0-9 ]/i, '') =~ rx }
    true
  end

  def matches_any(terms)
    terms.to_rx_array.each { |rx| return true if gsub(/[^a-z0-9 ]/i, '') =~ rx }
    false
  end

  def matches_all(terms)
    terms.to_rx_array.each { |rx| return false unless gsub(/[^a-z0-9 ]/i, '') =~ rx }
    true
  end

  def to_rx_array(separator: ' ', start_word: true)
    bound = start_word ? '\b' : ''
    split(/#{separator}/).map { |arg| /#{bound}#{Regexp.escape(arg.gsub(/[^a-z0-9]/i, ''))}/i }
  end
end

# = plist
#
# Copyright 2006-2010 Ben Bleything and Patrick May
# Distributed under the MIT License
module Plist ; end

# === Load a plist file
# This is the main point of the library:
#
#   r = Plist::parse_xml( filename_or_xml )
module Plist
  def Plist::parse_xml( filename_or_xml )
    listener = Listener.new
    parser = StreamParser.new(filename_or_xml, listener)
    parser.parse
    listener.result
  end

  class Listener
    attr_accessor :result, :open

    def initialize
      @result = nil
      @open = Array.new
    end

    def tag_start(name, attributes)
      @open.push PTag::mappings[name].new
    end

    def text( contents )
      @open.last.text = contents if @open.last
    end

    def tag_end(name)
      last = @open.pop
      if @open.empty?
        @result = last.to_ruby
      else
        @open.last.children.push last
      end
    end
  end

  class StreamParser
    def initialize( plist_data_or_file, listener )
      if plist_data_or_file.respond_to? :read
        @xml = plist_data_or_file.read
      elsif File.exists? plist_data_or_file
        @xml = File.read( plist_data_or_file )
      else
        @xml = plist_data_or_file
      end

      @listener = listener
    end

    TEXT       = /([^<]+)/
    XMLDECL_PATTERN = /<\?xml\s+(.*?)\?>*/um
    DOCTYPE_PATTERN = /\s*<!DOCTYPE\s+(.*?)(\[|>)/um
    COMMENT_START = /\A<!--/u
    COMMENT_END = /.*?-->/um

    def parse
      plist_tags = PTag::mappings.keys.join('|')
      start_tag  = /<(#{plist_tags})([^>]*)>/i
      end_tag    = /<\/(#{plist_tags})[^>]*>/i

      require 'strscan'

      @scanner = StringScanner.new(@xml)
      until @scanner.eos?
        if @scanner.scan(COMMENT_START)
          @scanner.scan(COMMENT_END)
        elsif @scanner.scan(XMLDECL_PATTERN)
        elsif @scanner.scan(DOCTYPE_PATTERN)
        elsif @scanner.scan(start_tag)
          @listener.tag_start(@scanner[1], nil)
          if (@scanner[2] =~ /\/$/)
            @listener.tag_end(@scanner[1])
          end
        elsif @scanner.scan(TEXT)
          @listener.text(@scanner[1])
        elsif @scanner.scan(end_tag)
          @listener.tag_end(@scanner[1])
        else
          raise "Unimplemented element"
        end
      end
    end
  end

  class PTag
    @@mappings = { }
    def PTag::mappings
      @@mappings
    end

    def PTag::inherited( sub_class )
      key = sub_class.to_s.downcase
      key.gsub!(/^plist::/, '' )
      key.gsub!(/^p/, '')  unless key == "plist"

      @@mappings[key] = sub_class
    end

    attr_accessor :text, :children
    def initialize
      @children = Array.new
    end

    def to_ruby
      raise "Unimplemented: " + self.class.to_s + "#to_ruby on #{self.inspect}"
    end
  end

  class PList < PTag
    def to_ruby
      children.first.to_ruby if children.first
    end
  end

  class PDict < PTag
    def to_ruby
      dict = Hash.new
      key = nil

      children.each do |c|
        if key.nil?
          key = c.to_ruby
        else
          dict[key] = c.to_ruby
          key = nil
        end
      end

      dict
    end
  end

  class PKey < PTag
    def to_ruby
      CGI::unescapeHTML(text || '')
    end
  end

  class PString < PTag
    def to_ruby
      CGI::unescapeHTML(text || '')
    end
  end

  class PArray < PTag
    def to_ruby
      children.collect do |c|
        c.to_ruby
      end
    end
  end

  class PInteger < PTag
    def to_ruby
      text.to_i
    end
  end

  class PTrue < PTag
    def to_ruby
      true
    end
  end

  class PFalse < PTag
    def to_ruby
      false
    end
  end

  class PReal < PTag
    def to_ruby
      text.to_f
    end
  end

  require 'date'
  class PDate < PTag
    def to_ruby
      DateTime.parse(text)
    end
  end

  require 'base64'
  class PData < PTag
    def to_ruby
      data = Base64.decode64(text.gsub(/\s+/, ''))

      begin
        return Marshal.load(data)
      rescue Exception => e
        io = StringIO.new
        io.write data
        io.rewind
        return io
      end
    end
  end
end

module Plist
  VERSION = '3.1.0'
end

# Main SearchLink class
class SearchLink
  include Plist

  attr_reader :originput, :output, :clipboard

  attr_accessor :cfg

  # Values found in ~/.searchlink will override defaults in
  # this script

  def initialize(opt = {})
    @printout = opt[:echo] || false
    unless File.exist? File.expand_path('~/.searchlink')
      default_config = <<~ENDCONFIG
        # set to true to have an HTML comment included detailing any errors
        # Can be disabled per search with `--d`, or enabled with `++d`.
        debug: true
        # set to true to have an HTML comment included reporting results
        report: true

        # use Notification Center to display progress
        notifications: false

        # when running on a file, back up original to *.bak
        backup: true

        # change this to set a specific country for search (default US)
        country_code: US

        # set to true to force inline Markdown links. Can be disabled
        # per search with `--i`, or enabled with `++i`.
        inline: false

        # set to true to include a random string in reference titles.
        # Avoids conflicts if you're only running on part of a document
        # or using SearchLink multiple times within a document
        prefix_random: true

        # set to true to add titles to links based on the page title
        # of the search result. Can be disabled per search with `--t`,
        # or enabled with `++t`.
        include_titles: false

        # confirm existence (200) of generated links. Can be disabled
        # per search with `--v`, or enabled with `++v`.
        validate_links: false

        # If the link text is left empty, always insert the page title
        # E.g. [](!g Search Text)
        empty_uses_page_title: false

        # Formatting for social links, use %service%, %user%, and %url%
        # E.g. "%user% on %service%" => "ttscoff on Twitter"
        #      "%service%/%user%" => "Twitter/ttscoff"
        #      "%url%" => "twitter.com/ttscoff"
        social_template: "%service%/%user%"

        # append affiliate link info to iTunes urls, empty quotes for none
        # example:
        # itunes_affiliate: "&at=10l4tL&ct=searchlink"
        itunes_affiliate: "&at=10l4tL&ct=searchlink"

        # to create Amazon affiliate links, set amazon_partner to your amazon
        # affiliate tag
        #    amazon_partner: "bretttercom-20"
        amazon_partner: "bretttercom-20"

        # To create custom abbreviations for Google Site Searches,
        # add to (or replace) the hash below.
        # "abbreviation" => "site.url",
        # This allows you, for example to use [search term](!bt)
        # as a shortcut to search brettterpstra.com (using a site-specific
        # Google search). Keys in this list can override existing
        # search trigger abbreviations.
        #
        # If a custom search starts with "http" or "/", it becomes
        # a simple replacement. Any instance of "$term" is replaced
        # with a URL-escaped version of your search terms.
        # Use $term1, $term2, etc. to replace in sequence from
        # multiple search terms. No instances of "$term" functions
        # as a simple shortcut. "$term" followed by a "d" lowercases
        # the replacement. Use "$term1d," "$term2d" to downcase
        # sequential replacements (affected individually).
        # Long flags (e.g. --no-validate_links) can be used after
        # any url in the custom searches.
        #
        # Use $terms to slugify all search terms, turning
        # "Markdown Service Tools" into "markdown-service-tools"
        custom_site_searches:
          bt: brettterpstra.com
          btt: https://brettterpstra.com/topic/$term1d
          bts: /search/$term --no-validate_links
          md: www.macdrifter.com
          ms: macstories.net
          dd: www.leancrew.com
          spark: macsparky.com
          man: http://man.cx/$term
          dev: developer.apple.com
          nq: http://nerdquery.com/?media_only=0&query=$term&search=1&category=-1&catid=&type=and&results=50&db=0&prefix=0
          gs: http://scholar.google.com/scholar?btnI&hl=en&q=$term&btnG=&as_sdt=80006
        # Remove or comment (with #) history searches you don't want
        # performed by `!h`. You can force-enable them per search, e.g.
        # `!hsh` (Safari History only), `!hcb` (Chrome Bookmarks only),
        # etc. Multiple types can be strung together: !hshcb (Safari
        # History and Chrome bookmarks).
        history_types:
        - safari_bookmarks
        - safari_history
        # - chrome_history
        # - chrome_bookmarks
        # - firefox_bookmarks
        # - firefox_history
        # - edge_bookmarks
        # - edge_history
        # - brave_bookmarks
        # - brave_history
        # - arc_history
        # - arc_bookmarks
        # Pinboard search
        # You can find your api key here: https://pinboard.in/settings/password
        pinboard_api_key: ''

      ENDCONFIG

      File.open(File.expand_path('~/.searchlink'), 'w') do |f|
        f.puts default_config
      end
    end

    @cfg = YAML.load_file(File.expand_path('~/.searchlink'))

    # set to true to have an HTML comment inserted showing any errors
    @cfg['debug'] ||= false

    # set to true to get a verbose report at the end of multi-line processing
    @cfg['report'] ||= false

    @cfg['backup'] = true unless @cfg.key? 'backup'

    # set to true to force inline links
    @cfg['inline'] ||= false

    # set to true to add titles to links based on site title
    @cfg['include_titles'] ||= false

    # set to true to use page title as link text when empty
    @cfg['empty_uses_page_title'] ||= false

    # change this to set a specific country for search (default US)
    @cfg['country_code'] ||= 'US'

    # set to true to include a random string in ref titles
    # allows running SearchLink multiple times w/out conflicts
    @cfg['prefix_random'] = false unless @cfg['prefix_random']

    @cfg['social_template'] ||= '%service%/%user%'

    # append affiliate link info to iTunes urls, empty quotes for none
    # example:
    # $itunes_affiliate = "&at=10l4tL&ct=searchlink"
    @cfg['itunes_affiliate'] ||= '&at=10l4tL&ct=searchlink'

    # to create Amazon affiliate links, set amazon_partner to your amazon
    # affiliate tag
    #    amazon_partner: "bretttercom-20"
    @cfg['amazon_partner'] ||= ''

    # To create custom abbreviations for Google Site Searches,
    # add to (or replace) the hash below.
    # "abbreviation" => "site.url",
    # This allows you, for example to use [search term](!bt)
    # as a shortcut to search brettterpstra.com. Keys in this
    # hash can override existing search triggers.
    @cfg['custom_site_searches'] ||= {
      'bt' => 'brettterpstra.com',
      'imdb' => 'imdb.com'
    }

    # confirm existence of links generated from custom search replacements
    @cfg['validate_links'] ||= false

    # use notification center to show progress
    @cfg['notifications'] ||= false
    @cfg['pinboard_api_key'] ||= false

    @line_num = nil
    @match_column = nil
    @match_length = nil
  end

  def available_searches
    searches = [
      %w[a Amazon],
      %w[g Google],
      %w[ddg DuckDuckGo],
      %w[yt YouTube],
      ['z', 'DDG Zero-Click Search'],
      %w[wiki Wikipedia],
      ['s', 'Software search (Google)'],
      ['@t', 'Twitter user link'],
      ['@f', 'Facebook user link'],
      ['@l', 'LinkedIn user link'],
      ['@i', 'Instagram user link'],
      ['@m', 'Mastodon user link'],
      ['am', 'Apple Music'],
      ['amart', 'Apple Music Artist'],
      ['amalb', 'Apple Music Album'],
      ['amsong', 'Apple Music Song'],
      ['ampod', 'Apple Music Podcast'],
      ['ipod', 'iTunes podcast'],
      ['isong', 'iTunes song'],
      ['iart', 'iTunes artist'],
      ['ialb', 'iTunes album'],
      ['lsong', 'Last.fm song'],
      ['lart', 'Last.fm artist'],
      ['mas', 'Mac App Store'],
      ['masd', 'Mac App Store developer link'],
      ['itu', 'iTunes App Store'],
      ['itud', 'iTunes App Store developer link'],
      ['imov', 'iTunes Movies'],
      ['def', 'Dictionary definition'],
      %w[hook Hookmarks],
      ['tmdb', 'The Movie Database search'],
      ['tmdba', 'The Movie Database Actor search'],
      ['tmdbm', 'The Movie Database Movie search'],
      ['tmdbt', 'The Movie Database TV search'],
      %w[sp Spelling],
      %w[pb Pinboard],
      ["h", "Web history"],
      ["hs[hb]", "Safari [history, bookmarks]"],
      ["hc[hb]", "Chrome [history, bookmarks]"],
      ["hf[hb]", "Firefox [history, bookmarks]"],
      ["he[hb]", "Edge [history, bookmarks]"],
      ["hb[hb]", "Brave [history, bookmarks]"]
    ]
    out = ''
    searches.each { |s| out += "!#{s[0]}#{spacer(s[0])}#{s[1]}\n" }
    out
  end

  def spacer(str)
    len = str.length
    str.scan(/[mwv]/).each { len += 1 }
    str.scan(/t/).each { len -= 1 }
    case len
    when 0..3
      "\t\t"
    when 4..12
      " \t"
    end
  end

  def help_text
    text = <<~EOHELP
      -- [Available searches] -------------------
      #{available_searches}
    EOHELP

    if @cfg['custom_site_searches']
      text += "\n-- [Custom Searches] ----------------------\n"
      @cfg['custom_site_searches'].each { |label, site| text += "!#{label}#{spacer(label)} #{site}\n" }
    end
    text
  end

  def help_dialog
    text = "[SearchLink v#{VERSION}]\n\n"
    text += help_text
    text += "\nClick \\\"More Help\\\" for additional information"
    text.gsub!(/\n/, '\\\n')
    res = `osascript <<'APPLESCRIPT'
set _res to display dialog "#{text}" buttons {"OK", "More help"} default button "OK" with title "SearchLink Help"

return button returned of _res
APPLESCRIPT
    `.strip
    `open http://brettterpstra.com/projects/searchlink` if res == 'More help'
  end

  def help_cli
    $stdout.puts help_text
  end

  def parse(input)
    @output = ''
    return false if input.empty?

    parse_arguments(input, { only_meta: true })
    @originput = input.dup

    if input.strip =~ /^help$/i
      if SILENT
        help_dialog # %x{open http://brettterpstra.com/projects/searchlink/}
      else
        $stdout.puts "SearchLink v#{VERSION}"
        $stdout.puts 'See http://brettterpstra.com/projects/searchlink/ for help'
      end
      print input
      Process.exit
    end

    @cfg['inline'] = true if input.scan(/\]\(/).length == 1 && input.split(/\n/).length == 1
    @errors = {}
    @report = []

    links = {}
    @footer = []
    counter_links = 0
    counter_errors = 0

    input.sub!(/\n?<!-- Report:.*?-->\n?/m, '')
    input.sub!(/\n?<!-- Errors:.*?-->\n?/m, '')

    input.scan(/\[(.*?)\]:\s+(.*?)\n/).each { |match| links[match[1].strip] = match[0] }

    prefix = if @cfg['prefix_random']
               if input =~ /\[(\d{4}-)\d+\]: \S+/
                 Regexp.last_match(1)
               else
                 format('%04d-', rand(9999))
               end
             else
               ''
             end

    highest_marker = 0
    input.scan(/^\s{,3}\[(?:#{prefix})?(\d+)\]: /).each do
      m = Regexp.last_match
      highest_marker = m[1].to_i if m[1].to_i > highest_marker
    end

    footnote_counter = 0
    input.scan(/^\s{,3}\[\^(?:#{prefix})?fn(\d+)\]: /).each do
      m = Regexp.last_match
      footnote_counter = m[1].to_i if m[1].to_i > footnote_counter
    end

    if input =~ /\[(.*?)\]\((.*?)\)/
      lines = input.split(/\n/)
      out = []

      total_links = input.scan(/\[(.*?)\]\((.*?)\)/).length
      in_code_block = false
      line_difference = 0
      lines.each_with_index do |line, num|
        @line_num = num - line_difference
        cursor_difference = 0
        # ignore links in code blocks
        if line =~ /^( {4,}|\t+)[^*+\-]/
          out.push(line)
          next
        end
        if line =~ /^[~`]{3,}/
          if in_code_block
            in_code_block = false
            out.push(line)
            next
          else
            in_code_block = true
          end
        end
        if in_code_block
          out.push(line)
          next
        end

        delete_line = false

        search_count = 0

        line.gsub!(/\[(.*?)\]\((.*?)\)/) do |match|
          this_match = Regexp.last_match
          @match_column = this_match.begin(0) - cursor_difference
          match_string = this_match.to_s
          @match_length = match_string.length
          match_before = this_match.pre_match

          invalid_search = false
          ref_title = false

          if match_before.scan(/(^|[^\\])`/).length.odd?
            add_report("Match '#{match_string}' within an inline code block")
            invalid_search = true
          end

          counter_links += 1
          unless SILENT
            $stderr.print("\033[0K\rProcessed: #{counter_links} of #{total_links}, #{counter_errors} errors. ")
          end

          link_text = this_match[1] || ''
          link_info = parse_arguments(this_match[2].strip).strip || ''

          if link_text.strip == '' && link_info =~ /".*?"/
            link_info.gsub!(/"(.*?)"/) do
              m = Regexp.last_match(1)
              link_text = m if link_text == ''
              m
            end
          end

          if link_info.strip =~ /:$/ && line.strip == match
            ref_title = true
            link_info.sub!(/\s*:\s*$/, '')
          end

          unless !link_text.empty? || !link_info.sub(/^[!\^]\S+/, '').strip.empty?
            add_error('No input', match)
            counter_errors += 1
            invalid_search = true
          end

          if link_info =~ /^!(\S+)/
            search_type = Regexp.last_match(1)
            unless valid_search?(search_type) || search_type =~ /^(\S+\.)+\S+$/
              add_error("Invalid search#{did_you_mean(search_type)}", match)
              invalid_search = true
            end
          end

          if invalid_search
            match
          elsif link_info =~ /^\^(.+)/
            m = Regexp.last_match
            if m[1].nil? || m[1] == ''
              match
            else
              note = m[1].strip
              footnote_counter += 1
              ref = if !link_text.empty? && link_text.scan(/\s/).empty?
                      link_text
                    else
                      format('%<p>sfn%<c>04d', p: prefix, c: footnote_counter)
                    end
              add_footer "[^#{ref}]: #{note}"
              res = "[^#{ref}]"
              cursor_difference += (@match_length - res.length)
              @match_length = res.length
              add_report("#{match_string} => Footnote #{ref}")
              res
            end
          elsif (link_text == '' && link_info == '') || url?(link_info)
            add_error("Invalid search", match) unless url?(link_info)
            match
          else
            link_info = link_text if !link_text.empty? && link_info == ''

            search_type = ''
            search_terms = ''
            link_only = false
            @clipboard = false
            @titleize = @cfg['empty_uses_page_title']

            if link_info =~ /^(?:[!\^](\S+))\s*(.*)$/
              m = Regexp.last_match

              search_type = m[1].nil? ? 'g' : m[1]

              search_terms = m[2].gsub(/(^["']|["']$)/, '')
              search_terms.strip!

              # if the link text is just '%' replace with title regardless of config settings
              if link_text == '%' && search_terms && !search_terms.empty?
                @titleize = true
                link_text = ''
              end

              search_terms = link_text if search_terms == ''

              # if the input starts with a +, append it to the link text as the search terms
              search_terms = "#{link_text} #{search_terms.strip.sub(/^\+\s*/, '')}" if search_terms.strip =~ /^\+[^+]/

              # if the end of input contain "^", copy to clipboard instead of STDOUT
              @clipboard = true if search_terms =~ /(!!)?\^(!!)?$/

              # if the end of input contains "!!", only print the url
              link_only = true if search_terms =~ /!!\^?$/

              search_terms.sub!(/(!!)?\^?(!!)?$/,"")

            elsif link_info =~ /^!/
              search_word = link_info.match(/^!(\S+)/)

              if search_word && valid_search?(search_word[1])
                search_type = search_word[1] unless search_word.nil?
                search_terms = link_text
              elsif search_word && search_word[1] =~ /^(\S+\.)+\S+$/
                search_type = 'g'
                search_terms = "site:#{search_word[1]} #{link_text}"
              else
                add_error("Invalid search#{did_you_mean(search_word[1])}", match)
                search_type = false
                search_terms = false
              end

            elsif link_text && !link_text.empty? && (link_info.nil? || link_info.empty?)
              search_type = 'g'
              search_terms = link_text
            elsif link_info && !link_info.empty?
              search_type = 'g'
              search_terms = link_info
            else
              add_error('Invalid search', match)
              search_type = false
              search_terms = false
            end

            if search_type && !search_terms.empty?
              @cfg['custom_site_searches'].each do |k, v|
                next unless search_type == k

                link_text = search_terms if !@titleize && link_text == ''
                v = parse_arguments(v, { no_restore: true })
                if v =~ %r{^(/|http)}i
                  search_type = 'r'
                  tokens = v.scan(/\$term\d+[ds]?/).sort.uniq

                  if !tokens.empty?
                    highest_token = 0
                    tokens.each do |token|
                      if token =~ /(\d+)[ds]?$/ && Regexp.last_match(1).to_i > highest_token
                        highest_token = Regexp.last_match(1).to_i
                      end
                    end
                    terms_p = search_terms.split(/ +/)
                    if terms_p.length > highest_token
                      remainder = terms_p[highest_token - 1..-1].join(' ')
                      terms_p = terms_p[0..highest_token - 2]
                      terms_p.push(remainder)
                    end
                    tokens.each do |t|
                      next unless t =~ /(\d+)[ds]?$/

                      int = Regexp.last_match(1).to_i - 1
                      replacement = terms_p[int]
                      case t
                      when /d$/
                        replacement.downcase!
                        re_down = ''
                      when /s$/
                        replacement.slugify!
                        re_down = ''
                      else
                        re_down = '(?!d|s)'
                      end
                      v.gsub!(/#{Regexp.escape(t) + re_down}/, ERB::Util.url_encode(replacement))
                    end
                    search_terms = v
                  else
                    search_terms = v.gsub(/\$term[ds]?/i) do |mtch|
                      search_terms.downcase! if mtch =~ /d$/i
                      search_terms.slugify! if mtch =~ /s$/i
                      ERB::Util.url_encode(search_terms)
                    end
                  end
                else
                  search_type = 'g'
                  search_terms = "site:#{v} #{search_terms}"
                end

                break
              end
            end

            if search_type && search_terms
              # warn "Searching #{search_type} for #{search_terms}"
              search_count += 1
              url, title, link_text = do_search(search_type, search_terms, link_text, search_count)

              if url
                title = titleize(url) if @titleize && title == ''

                link_text = title if link_text == '' && title
                force_title = search_type =~ /def/ ? true : false

                if link_only || search_type =~ /sp(ell)?/ || url == 'embed'
                  url = title if url == 'embed'
                  cursor_difference += @match_length - url.length
                  @match_length = url.length
                  add_report("#{match_string} => #{url}")
                  url
                elsif ref_title
                  unless links.key? url
                    links[url] = link_text
                    add_footer make_link('ref_title', link_text, url, title: title, force_title: force_title)
                  end
                  delete_line = true
                elsif @cfg['inline']
                  res = make_link('inline', link_text, url, title: title, force_title: force_title)
                  cursor_difference += @match_length - res.length
                  @match_length = res.length
                  add_report("#{match_string} => #{url}")
                  res
                else
                  unless links.key? url
                    highest_marker += 1
                    links[url] = format('%<pre>s%<m>04d', pre: prefix, m: highest_marker)
                    add_footer make_link('ref_title', links[url], url, title: title, force_title: force_title)
                  end

                  type = @cfg['inline'] ? 'inline' : 'ref_link'
                  res = make_link(type, link_text, links[url], title: false, force_title: force_title)
                  cursor_difference += @match_length - res.length
                  @match_length = res.length
                  add_report("#{match_string} => #{url}")
                  res
                end
              else
                add_error('No results', "#{search_terms} (#{match_string})")
                counter_errors += 1
                match
              end
            else
              add_error('Invalid search', match)
              counter_errors += 1
              match
            end
          end
        end
        line_difference += 1 if delete_line
        out.push(line) unless delete_line
        delete_line = false
      end
      warn "\n" unless SILENT

      input = out.delete_if { |l| l.strip =~ /^<!--DELETE-->$/ }.join("\n")

      if @cfg['inline']
        add_output "#{input}\n"
        add_output "\n#{print_footer}" unless @footer.empty?
      elsif @footer.empty?
        add_output input
      else
        last_line = input.strip.split(/\n/)[-1]
        case last_line
        when /^\[.*?\]: http/
          add_output "#{input.rstrip}\n"
        when /^\[\^.*?\]: /
          add_output input.rstrip
        else
          add_output "#{input}\n\n"
        end
        add_output "#{print_footer}\n\n"
      end
      @line_num = nil
      add_report("Processed: #{total_links} links, #{counter_errors} errors.")
      print_report
      print_errors
    else
      link_only = false
      @clipboard = false

      res = parse_arguments(input.strip!).strip
      input = res.nil? ? input : res

      # if the end of input contain "^", copy to clipboard instead of STDOUT
      @clipboard = true if input =~ /\^[!~:]*$/

      # if the end of input contains "!!", only print the url
      link_only = true if input =~ /!![\^~:]*$/

      reference_link = input =~ /:([!\^\s~]*)$/

      # if end of input contains ~, pull url from clipboard
      if input =~ /~[:\^!\s]*$/
        input.sub!(/[:!\^\s~]*$/, '')
        clipboard = `__CF_USER_TEXT_ENCODING=$UID:0x8000100:0x8000100 pbpaste`.strip
        if url?(clipboard)
          type = reference_link ? 'ref_title' : 'inline'
          print make_link(type, input.strip, clipboard)
        else
          print @originput
        end
        Process.exit
      end

      input.sub!(/[:!\^\s~]*$/, '')

      ## Maybe if input is just a URL, convert it to a link
      ## using hostname as text without doing search
      if only_url?(input.strip)
        type = reference_link ? 'ref_title' : 'inline'
        url, title = url_to_link(input.strip, type)
        print make_link(type, title, url, title: false, force_title: false)
        Process.exit
      end

      # check for additional search terms in parenthesis
      additional_terms = ''
      if input =~ /\((.*?)\)/
        additional_terms = " #{Regexp.last_match(1).strip}"
        input.sub!(/\(.*?\)/, '')
      end

      # Maybe detect "search + addition terms" and remove additional terms from link text?
      # if input =~ /\+(.+?)$/
      #   additional_terms = "#{additional_terms} #{Regexp.last_match(1).strip}"
      #   input.sub!(/\+.*?$/, '').strip!
      # end

      link_text = false

      if input =~ /"(.*?)"/
        link_text = Regexp.last_match(1)
        input.gsub!(/"(.*?)"/, '\1')
      end

      # remove quotes from terms, just in case
      # input.sub!(/^(!\S+)?\s*(["'])(.*?)\2([\!\^]+)?$/, "\\1 \\3\\4")

      case input
      when /^!(\S+)\s+(.*)$/
        type = Regexp.last_match(1)
        link_info = Regexp.last_match(2).strip
        link_text ||= link_info
        terms = link_info + additional_terms
        terms.strip!

        if valid_search?(type) || type =~ /^(\S+\.)+\S+$/
          if type && terms && !terms.empty?
            @cfg['custom_site_searches'].each do |k, v|
              next unless type == k

              link_text = terms if link_text == ''
              v = parse_arguments(v, { no_restore: true })
              if v =~ %r{^(/|http)}i
                type = 'r'
                tokens = v.scan(/\$term\d+[ds]?/).sort.uniq

                if !tokens.empty?
                  highest_token = 0
                  tokens.each do |token|
                    t = Regexp.last_match(1)
                    highest_token = t.to_i if token =~ /(\d+)d?$/ && t.to_i > highest_token
                  end
                  terms_p = terms.split(/ +/)
                  if terms_p.length > highest_token
                    remainder = terms_p[highest_token - 1..-1].join(' ')
                    terms_p = terms_p[0..highest_token - 2]
                    terms_p.push(remainder)
                  end
                  tokens.each do |t|
                    next unless t =~ /(\d+)d?$/

                    int = Regexp.last_match(1).to_i - 1
                    replacement = terms_p[int]
                    case t
                    when /d$/
                      replacement.downcase!
                      re_down = ''
                    when /s$/
                      replacement.slugify!
                      re_down = ''
                    else
                      re_down = '(?!d|s)'
                    end
                    v.gsub!(/#{Regexp.escape(t) + re_down}/, ERB::Util.url_encode(replacement))
                  end
                  terms = v
                else
                  terms = v.gsub(/\$term[ds]?/i) do |mtch|
                    terms.downcase! if mtch =~ /d$/i
                    terms.slugify! if mtch =~ /s$/i
                    ERB::Util.url_encode(terms)
                  end
                end
              else
                type = 'g'
                terms = "site:#{v} #{terms}"
              end

              break
            end
          end

          if type =~ /^(\S+\.)+\S+$/
            terms = "site:#{type} #{terms}"
            type = 'g'
          end
          search_count ||= 0
          search_count += 1
          url, title, link_text = do_search(type, terms, link_text, search_count)
        else
          add_error("Invalid search#{did_you_mean(type)}", input)
          counter_errors += 1
        end
      when /^([tfilm])?@(\S+)\s*$/
        type = Regexp.last_match(1)
        unless type
          if Regexp.last_match(2) =~ /[a-z0-9_]@[a-z0-9_.]+/i
            type = 'm'
          else
            type = 't'
          end
        end
        link_text = input.sub(/^[tfilm]/, '')
        url, title = social_handle(type, link_text)
        link_text = title
      else
        link_text ||= input
        url, title = ddg(input)
      end

      if url
        if type =~ /sp(ell)?/
          add_output(url)
        elsif link_only
          add_output(url)
        elsif url == 'embed'
          add_output(title)
        else
          type = reference_link ? 'ref_title' : 'inline'
          add_output make_link(type, link_text, url, title: title, force_title: false)
          print_errors
        end
      else
        add_error('No results', title)
        add_output @originput.chomp
        print_errors
      end

      if @clipboard
        if @output == @originput
          warn "No results found"
        else
          `echo #{Shellwords.escape(@output)}|tr -d "\n"|pbcopy`
          warn "Results in clipboard"
        end
      end
    end
  end

  private

  def parse_arguments(string, opt={})
    input = string.dup
    return "" if input.nil?

    skip_flags = opt[:only_meta] || false
    no_restore = opt[:no_restore] || false
    restore_prev_config unless no_restore

    unless skip_flags
      input.gsub!(/(\+\+|--)([dirtv]+)\b/) do
        m = Regexp.last_match
        bool = m[1] == '++' ? '' : 'no-'
        output = ' '
        m[2].split('').each do |arg|
          output += case arg
                    when 'd'
                      "--#{bool}debug "
                    when 'i'
                      "--#{bool}inline "
                    when 'r'
                      "--#{bool}prefix_random "
                    when 't'
                      "--#{bool}include_titles "
                    when 'v'
                      "--#{bool}validate_links "
                    else
                      ''
                    end
        end
        output
      end
    end

    options = %w[debug country_code inline prefix_random include_titles validate_links]
    options.each do |o|
      if input =~ /^ *#{o}:\s+(\S+)$/
        val = Regexp.last_match(1).strip
        val = true if val =~ /true/i
        val = false if val =~ /false/i
        @cfg[o] = val
        $stderr.print "\r\033[0KGlobal config: #{o} = #{@cfg[o]}\n" unless SILENT
      end

      next if skip_flags

      while input =~ /^#{o}:\s+(.*?)$/ || input =~ /--(no-)?#{o}/
        next unless input =~ /--(no-)?#{o}/ && !skip_flags

        unless @prev_config.key? o
          @prev_config[o] = @cfg[o]
          bool = Regexp.last_match(1).nil? || Regexp.last_match(1) == '' ? true : false
          @cfg[o] = bool
          $stderr.print "\r\033[0KLine config: #{o} = #{@cfg[o]}\n" unless SILENT
        end
        input.sub!(/\s?--(no-)?#{o}/, '')
      end
    end
    @clipboard ? string : input
  end

  def restore_prev_config
    @prev_config&.each do |k, v|
      @cfg[k] = v
      $stderr.print "\r\033[0KReset config: #{k} = #{@cfg[k]}\n" unless SILENT
    end
    @prev_config = {}
  end

  def make_link(type, text, url, title: false, force_title: false)
    text = title || titleize(url) if @titleize && text == ''

    title = title && (@cfg['include_titles'] || force_title) ? %( "#{title.clean}") : ''

    case type
    when 'ref_title'
      %(\n[#{text.strip}]: #{url}#{title})
    when 'ref_link'
      %([#{text.strip}][#{url}])
    when 'inline'
      %([#{text.strip}](#{url}#{title}))
    end
  end

  def add_output(str)
    print str if @printout && !@clipboard
    @output += str
  end

  def add_footer(str)
    @footer ||= []
    @footer.push(str.strip)
  end

  def print_footer
    unless @footer.empty?

      footnotes = []
      @footer.delete_if do |note|
        note.strip!
        case note
        when /^\[\^.+?\]/
          footnotes.push(note)
          true
        when /^\s*$/
          true
        else
          false
        end
      end

      output = @footer.sort.join("\n").strip
      output += "\n\n" if !output.empty? && !footnotes.empty?
      output += footnotes.join("\n\n") unless footnotes.empty?
      return output.gsub(/\n{3,}/, "\n\n")
    end

    ''
  end

  def add_report(str)
    return unless @cfg['report']

    unless @line_num.nil?
      position = "#{@line_num}:"
      position += @match_column.nil? ? '0:' : "#{@match_column}:"
      position += @match_length.nil? ? '0' : @match_length.to_s
    end
    @report.push("(#{position}): #{str}")
    warn "(#{position}): #{str}" unless SILENT
  end

  def add_error(type, str)
    return unless @cfg['debug']

    unless @line_num.nil?
      position = "#{@line_num}:"
      position += @match_column.nil? ? '0:' : "#{@match_column}:"
      position += @match_length.nil? ? '0' : @match_length.to_s
    end
    @errors[type] ||= []
    @errors[type].push("(#{position}): #{str}")
  end

  def print_report
    return if (@cfg['inline'] && @originput.split(/\n/).length == 1) || @clipboard

    return if @report.empty?

    out = "\n<!-- Report:\n#{@report.join("\n")}\n-->\n"
    add_output out
  end

  def print_errors(type = 'Errors')
    return if @errors.empty?

    out = ''
    inline = if @originput.split(/\n/).length > 1
               false
             else
               @cfg['inline'] || @originput.split(/\n/).length == 1
             end

    @errors.each do |k, v|
      next if v.empty?

      v.each_with_index do |err, i|
        out += "(#{k}) #{err}"
        out += if inline
                 i == v.length - 1 ? ' | ' : ', '
               else
                 "\n"
               end
      end
    end

    unless out == ''
      sep = inline ? ' ' : "\n"
      out.sub!(/\| /, '')
      out = "#{sep}<!-- #{type}:#{sep}#{out}-->#{sep}"
    end
    if @clipboard
      warn out
    else
      add_output out
    end
  end

  def print_or_copy(text)
    # Process.exit unless text
    if @clipboard
      `echo #{Shellwords.escape(text)}|tr -d "\n"|pbcopy`
      print @originput
    else
      print text
    end
  end

  def notify(str, sub)
    return unless @cfg['notifications']

    `osascript -e 'display notification "SearchLink" with title "#{str}" subtitle "#{sub}"'`
  end

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

  def best_search_match(term)
    searches = all_possible_searches.dup
    searches.select do |s|
      s.matches_score(term, separator: '', start_word: false) > 8
    end
  end

  def did_you_mean(term)
    matches = best_search_match(term)
    matches.empty? ? '' : ", did you mean #{matches.map { |m| "!#{m}" }.join(', ')}?"
  end

  def all_possible_searches
    %w[
      h
      hs
      hsh
      hshb
      hsbh
      hsb
      hc
      hch
      hcb
      hchb
      hcbh
      hf
      hfh
      hfb
      hfhb
      hfbh
      he
      heh
      heb
      hehb
      hebh
      hb
      hbh
      hbb
      hbhb
      hbbh
      ha
      hah
      hab
      habh
      hahb
      a
      imov
      g
      ddg
      z
      zero
      b
      wiki
      def
      mas
      masd
      itu
      itud
      tmdb
      tmdba
      tmdbm
      tmdbt
      s
      iart
      ialb
      isong
      ipod
      iarte
      ialbe
      isonge
      ipode
      lart
      lalb
      lsong
      lpod
      larte
      lalbe
      lsonge
      lpode
      amart
      amalb
      amsong
      ampod
      amarte
      amalbe
      amsonge
      ampode
      @t
      @f
      @i
      @l
      @m
      r
      sp
      spell
      pb
      yt
    ].concat(@cfg['custom_site_searches'].keys)
  end

  def valid_searches
    [
      'h(([scfabe])([hb])?)*',
      'a',
      'imov',
      'g',
      'ddg',
      'z(ero)?',
      'b',
      'wiki',
      'def',
      'masd?',
      'itud?',
      'tmdb[amt]?',
      's',
      '(i|am|l)(art|alb|song|pod)e?',
      '@[tfilm]',
      'r',
      'sp(ell)?',
      'pb',
      'yt'
    ]
  end

  def valid_search?(term)
    valid = false
    valid = true if term =~ /^(#{valid_searches.join('|')})$/
    valid = true if @cfg['custom_site_searches'].keys.include? term
    notify("Invalid search#{did_you_mean(term)}", term) unless valid
    valid
  end

  def search_arc_history(term)
    # Google history
    history_file = File.expand_path('~/Library/Application Support/Arc/User Data/Default/History')
    if File.exist?(history_file)
      notify('Searching Arc History', term)
      search_chromium_history(history_file, term)
    else
      false
    end
  end

  def search_brave_history(term)
    # Google history
    history_file = File.expand_path('~/Library/Application Support/BraveSoftware/Brave-Browser/Default/History')
    if File.exist?(history_file)
      notify('Searching Brave History', term)
      search_chromium_history(history_file, term)
    else
      false
    end
  end

  def search_edge_history(term)
    # Google history
    history_file = File.expand_path('~/Library/Application Support/Microsoft/Edge/Default/History')
    if File.exist?(history_file)
      notify('Searching Edge History', term)
      search_chromium_history(history_file, term)
    else
      false
    end
  end

  def search_chrome_history(term)
    # Google history
    history_file = File.expand_path('~/Library/Application Support/Google/Chrome/Default/History')
    if File.exist?(history_file)
      notify('Searching Chrome History', term)
      search_chromium_history(history_file, term)
    else
      false
    end
  end

  def search_chromium_history(history_file, term)
    tmpfile = "#{history_file}.tmp"
    FileUtils.cp(history_file, tmpfile)

    terms = []
    terms.push("(url NOT LIKE '%search/?%'
               AND url NOT LIKE '%?q=%'
               AND url NOT LIKE '%?s=%'
               AND url NOT LIKE '%duckduckgo.com/?t%')")
    terms.concat(term.split(/\s+/).map do |t|
      "(url LIKE '%#{t.strip.downcase}%'
      OR title LIKE '%#{t.strip.downcase}%')"
    end)
    query = terms.join(' AND ')
    most_recent = `sqlite3 -json '#{tmpfile}' "select title, url,
    datetime(last_visit_time / 1000000 + (strftime('%s', '1601-01-01')), 'unixepoch') as datum
    from urls where #{query} order by datum desc limit 1 COLLATE NOCASE;"`.strip
    FileUtils.rm_f(tmpfile)
    return false if most_recent.strip.empty?

    bm = JSON.parse(most_recent)[0]

    date = Time.parse(bm['datum'])
    [bm['url'], bm['title'], date]
  end

  def search_arc_bookmarks(term)
    bookmarks_file = File.expand_path('~/Library/Application Support/Arc/User Data/Default/Bookmarks')

    if File.exist?(bookmarks_file)
      notify('Searching Brave Bookmarks', term)
      return search_chromium_bookmarks(bookmarks_file, term)
    end

    false
  end

  def search_brave_bookmarks(term)
    bookmarks_file = File.expand_path('~/Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks')

    if File.exist?(bookmarks_file)
      notify('Searching Brave Bookmarks', term)
      return search_chromium_bookmarks(bookmarks_file, term)
    end

    false
  end

  def search_edge_bookmarks(term)
    bookmarks_file = File.expand_path('~/Library/Application Support/Microsoft/Edge/Default/Bookmarks')

    if File.exist?(bookmarks_file)
      notify('Searching Brave Bookmarks', term)
      return search_chromium_bookmarks(bookmarks_file, term)
    end

    false
  end

  def search_chrome_bookmarks(term)
    bookmarks_file = File.expand_path('~/Library/Application Support/Google/Chrome/Default/Bookmarks')

    if File.exist?(bookmarks_file)
      notify('Searching Chrome Bookmarks', term)
      return search_chromium_bookmarks(bookmarks_file, term)
    end

    false
  end

  def search_chromium_bookmarks(bookmarks_file, term)
    chrome_bookmarks = JSON.parse(IO.read(bookmarks_file))

    if chrome_bookmarks
      terms = term.split(/\s+/)
      roots = chrome_bookmarks['roots']
      urls = extract_chrome_bookmarks(roots)
      urls.sort_by! { |bookmark| bookmark['date_added'] }
      urls.select do |u|
        found = true
        terms.each { |t| found = false unless u['url'] =~ /#{t}/i || u['title'] =~ /#{t}/i }
        found
      end
      unless urls.empty?
        lastest_bookmark = urls[-1]
        return [lastest_bookmark['url'], lastest_bookmark['title'], lastest_bookmark['date']]
      end
    end

    false
  end

  def search_firefox_history(term)
    # Firefox history
    base = File.expand_path('~/Library/Application Support/Firefox/Profiles')
    Dir.chdir(base)
    profile = Dir.glob('*default-release')
    return false unless profile

    src = File.join(base, profile[0], 'places.sqlite')

    if File.exist?(src)
      notify('Searching Firefox History', term)
      tmpfile = "#{src}.tmp"
      FileUtils.cp(src, tmpfile)

      terms = []
      terms.push("(moz_places.url NOT LIKE '%search/?%'
                 AND moz_places.url NOT LIKE '%?q=%'
                 AND moz_places.url NOT LIKE '%?s=%'
                 AND moz_places.url NOT LIKE '%duckduckgo.com/?t%')")
      terms.concat(term.split(/\s+/).map do |t|
        "(moz_places.url LIKE '%#{t.strip.downcase}%' OR moz_places.title LIKE '%#{t.strip.downcase}%')"
      end)
      query = terms.join(' AND ')
      most_recent = `sqlite3 -json '#{tmpfile}' "select moz_places.title, moz_places.url,
      datetime(moz_historyvisits.visit_date/1000000, 'unixepoch', 'localtime') as datum
      from moz_places, moz_historyvisits where moz_places.id = moz_historyvisits.place_id
      and #{query} order by datum desc limit 1 COLLATE NOCASE;"`.strip
      FileUtils.rm_f(tmpfile)

      return false if most_recent.strip.empty?

      bm = JSON.parse(most_recent)[0]

      date = Time.parse(bm['datum'])
      [bm['url'], bm['title'], date]
    else
      false
    end
  end

  def search_firefox_bookmarks(term)
    # Firefox history
    base = File.expand_path('~/Library/Application Support/Firefox/Profiles')
    Dir.chdir(base)
    profile = Dir.glob('*default-release')
    return false unless profile

    src = File.join(base, profile[0], 'places.sqlite')

    if File.exist?(src)
      notify('Searching Firefox Bookmarks', term)
      tmpfile = "#{src}.tmp"
      FileUtils.cp(src, tmpfile)

      terms = []
      terms.push("(h.url NOT LIKE '%search/?%'
                 AND h.url NOT LIKE '%?q=%'
                 AND h.url NOT LIKE '%?s=%'
                 AND h.url NOT LIKE '%duckduckgo.com/?t%')")
      terms.concat(term.split(/\s+/).map do |t|
        "(h.url LIKE '%#{t.strip.downcase}%' OR b.title LIKE '%#{t.strip.downcase}%')"
      end)

      query = terms.join(' AND ')

      most_recent = `sqlite3 -json '#{tmpfile}' "select h.url, b.title,
      datetime(b.dateAdded/1000000, 'unixepoch', 'localtime') as datum
      FROM moz_places h JOIN moz_bookmarks b ON h.id = b.fk
      where #{query} order by datum desc limit 1 COLLATE NOCASE;"`.strip
      FileUtils.rm_f(tmpfile)

      return false if most_recent.strip.empty?

      bm = JSON.parse(most_recent)[0]

      date = Time.parse(bm['datum'])
      [bm['url'], bm['title'], date]
    else
      false
    end
  end

  def search_safari_history(term)
    # Firefox history
    src = File.expand_path('~/Library/Safari/History.db')
    if File.exist?(src)
      notify('Searching Safari History', term)
      tmpfile = "#{src}.tmp"
      FileUtils.cp(src, tmpfile)

      terms = []
      terms.push("(url NOT LIKE '%search/?%'
                 AND url NOT LIKE '%?q=%' AND url NOT LIKE '%?s=%'
                 AND url NOT LIKE '%duckduckgo.com/?t%')")
      terms.concat(term.split(/\s+/).map do |t|
        "(url LIKE '%#{t.strip.downcase}%' OR title LIKE '%#{t.strip.downcase}%')"
      end)
      query = terms.join(' AND ')
      most_recent = `sqlite3 -json '#{tmpfile}' "select title, url,
      datetime(visit_time/1000000, 'unixepoch', 'localtime') as datum
      from history_visits INNER JOIN history_items ON history_items.id = history_visits.history_item
      where #{query} order by datum desc limit 1 COLLATE NOCASE;"`.strip
      FileUtils.rm_f(tmpfile)

      return false if most_recent.strip.empty?

      bm = JSON.parse(most_recent)[0]
      date = Time.parse(bm['datum'])
      [bm['url'], bm['title'], date]
    else
      false
    end
  end

  def search_safari_bookmarks(terms)
    result = nil

    data = `plutil -convert xml1 -o - ~/Library/Safari/Bookmarks.plist`.strip
    parent = Plist::parse_xml(data)
    result = get_safari_bookmarks(parent, terms).first

    return false if result.nil?

    [result[:url], result[:title], Time.now]
  end

  def get_safari_bookmarks(parent, terms)
    results = []
    if parent.is_a?(Array)
      parent.each do |c|
        if c.is_a?(Hash)
          if c.key?('Children')
            results.concat(get_safari_bookmarks(c['Children'], terms))
          elsif c.key?('URIDictionary')
            title = c['URIDictionary']['title']
            url = c['URLString']
            results.push({ url: url, title: title }) if title =~ /#{terms}/i || url =~ /#{terms}/i
          end
        end
      end
    else
      results.concat(get_safari_bookmarks(parent['Children'], terms))
    end
    results.sort_by { |h| h[:title] }.uniq
  end

  def search_history(term,types = [])
    if types.empty?
      return false unless @cfg['history_types']

      types = @cfg['history_types']
    end

    results = []

    if !types.empty?
      types.each do |type|
        url, title, date = case type
                           when 'chrome_history'
                             search_chrome_history(term)
                           when 'chrome_bookmarks'
                             search_chrome_bookmarks(term)
                           when 'safari_bookmarks'
                             search_safari_bookmarks(term)
                           when 'safari_history'
                             search_safari_history(term)
                           when 'firefox_history'
                             search_firefox_history(term)
                           when 'firefox_bookmarks'
                             search_firefox_bookmarks(term)
                           when 'edge_history'
                             search_edge_history(term)
                           when 'edge_bookmarks'
                             search_edge_bookmarks(term)
                           when 'brave_history'
                             search_brave_history(term)
                           when 'brave_bookmarks'
                             search_brave_bookmarks(term)
                           when 'arc_history'
                             search_arc_history(term)
                           when 'arc_bookmarks'
                             search_arc_bookmarks(term)
                           else
                             false
                           end

        results << { 'url' => url, 'title' => title, 'date' => date } if url
      end

      if results.empty?
        false
      else
        out = results.sort_by! { |r| r['date'] }.last
        [out['url'], out['title']]
      end
    else
      false
    end
  end

  def extract_chrome_bookmarks(json, urls = [])
    if json.instance_of?(Array)
      json.each { |item| urls = extract_chrome_bookmarks(item, urls) }
    elsif json.instance_of?(Hash)
      if json.key? 'children'
        urls = extract_chrome_bookmarks(json['children'], urls)
      elsif json['type'] == 'url'
        date = Time.at(json['date_added'].to_i / 1000000 + (Time.new(1601, 01, 01).strftime('%s').to_i))
        urls << { 'url' => json['url'], 'title' => json['name'], 'date' => date }
      else
        json.each { |_, v| urls = extract_chrome_bookmarks(v, urls) }
      end
    else
      return urls
    end
    urls
  end

  def tmdb(search_type, terms)
    type = case search_type
           when /t$/
             'tv'
           when /m$/
             'movie'
           when /a$/
             'person'
           else
             'multi'
           end
    body = `/usr/bin/curl -sSL 'https://api.themoviedb.org/3/search/#{type}?query=#{ERB::Util.url_encode(terms)}&api_key=2bd76548656d92517f14d64766e87a02'`
    data = JSON.parse(body)
    if data.key?('results') && data['results'].count.positive?
      res = data['results'][0]
      type = res['media_type'] if type == 'multi'
      id = res['id']
      url = "https://www.themoviedb.org/#{type}/#{id}"
      title = res['name']
      title ||= res['title']
      title ||= terms
    else
      url, title = ddg("site:imdb.com #{terms}")

      return false unless url
    end

    [url, title]
  end

  def wiki(terms)
    ## Hack to scrape wikipedia result
    body = `/usr/bin/curl -sSL 'https://en.wikipedia.org/wiki/Special:Search?search=#{ERB::Util.url_encode(terms)}&go=Go'`
    return unless body

    body = body.force_encoding('utf-8') if RUBY_VERSION.to_f > 1.9

    begin
      title = body.match(/"wgTitle":"(.*?)"/)[1]
      url = body.match(/<link rel="canonical" href="(.*?)"/)[1]
    rescue StandardError
      return false
    end

    [url, title]

    ## Removed because Ruby 2.0 does not like https connection to wikipedia without using gems?
    # uri = URI.parse("https://en.wikipedia.org/w/api.php?action=query&format=json&prop=info&inprop=url&titles=#{CGI.escape(terms)}")
    # req = Net::HTTP::Get.new(uri.path)
    # req['Referer'] = "http://brettterpstra.com"
    # req['User-Agent'] = "SearchLink (http://brettterpstra.com)"

    # res = Net::HTTP.start(uri.host, uri.port,
    #   :use_ssl => true,
    #   :verify_mode => OpenSSL::SSL::VERIFY_NONE) do |https|
    #     https.request(req)
    #   end

    # if RUBY_VERSION.to_f > 1.9
    #   body = res.body.force_encoding('utf-8')
    # else
    #   body = res.body
    # end

    # result = JSON.parse(body)

    # if result
    #   result['query']['pages'].each do |page,info|
    #     unless info.key? "missing"
    #       return [info['fullurl'],info['title']]
    #     end
    #   end
    # end
    # return false
  end

  def zero_click(terms)
    url = URI.parse("http://api.duckduckgo.com/?q=#{ERB::Util.url_encode(terms)}&format=json&no_redirect=1&no_html=1&skip_disambig=1")
    res = Net::HTTP.get_response(url).body
    res = res.force_encoding('utf-8') if RUBY_VERSION.to_f > 1.9

    result = JSON.parse(res)
    return ddg(terms) unless result

    wiki_link = result['AbstractURL'] || result['Redirect']
    title = result['Heading'] || false

    if !wiki_link.empty? && !title.empty?
      [wiki_link, title]
    else
      ddg(terms)
    end
  end

  # Search apple music
  # terms => search terms (unescaped)
  # media => music, podcast
  # entity => optional: artist, song, album, podcast
  # returns {:type=>,:id=>,:url=>,:title}
  def applemusic(terms, media = 'music', entity = '')
    aff = @cfg['itunes_affiliate']
    output = {}

    url = URI.parse("http://itunes.apple.com/search?term=#{ERB::Util.url_encode(terms)}&country=#{@cfg['country_code']}&media=#{media}&entity=#{entity}")
    res = Net::HTTP.get_response(url).body
    res = res.force_encoding('utf-8') if RUBY_VERSION.to_f > 1.9
    res.gsub!(/(?mi)[\x00-\x08\x0B-\x0C\x0E-\x1F]/, '')
    json = JSON.parse(res)
    return false unless json['resultCount']&.positive?

    result = json['results'][0]

    case result['wrapperType']
    when 'track'
      if result['kind'] == 'podcast'
        output[:type] = 'podcast'
        output[:id] = result['collectionId']
        output[:url] = result['collectionViewUrl'].to_am + aff
        output[:title] = result['collectionName']
      else
        output[:type] = 'song'
        output[:album] = result['collectionId']
        output[:id] = result['trackId']
        output[:url] = result['trackViewUrl'].to_am + aff
        output[:title] = "#{result['trackName']} by #{result['artistName']}"
      end
    when 'collection'
      output[:type] = 'album'
      output[:id] = result['collectionId']
      output[:url] = result['collectionViewUrl'].to_am + aff
      output[:title] = "#{result['collectionName']} by #{result['artistName']}"
    when 'artist'
      output[:type] = 'artist'
      output[:id] = result['artistId']
      output[:url] = result['artistLinkUrl'].to_am + aff
      output[:title] = result['artistName']
    end
    return false if output.empty?

    output
  end

  def itunes(entity, terms, dev, aff = nil)
    aff ||= @cfg['itunes_affiliate']

    url = URI.parse("http://itunes.apple.com/search?term=#{ERB::Util.url_encode(terms)}&country=#{@cfg['country_code']}&entity=#{entity}")
    res = Net::HTTP.get_response(url).body
    res = res.force_encoding('utf-8').encode # if RUBY_VERSION.to_f > 1.9

    begin
      json = JSON.parse(res)
    rescue StandardError => e
      add_error('Invalid response', "Search for #{terms}: (#{e})")
      return false
    end
    return false unless json

    return false unless json['resultCount']&.positive?

    result = json['results'][0]
    case entity
    when /movie/
      # dev parameter probably not necessary in this case
      output_url = result['trackViewUrl']
      output_title = result['trackName']
    when /(mac|iPad)Software/
      output_url = dev && result['sellerUrl'] ? result['sellerUrl'] : result['trackViewUrl']
      output_title = result['trackName']
    when /(musicArtist|song|album)/
      case result['wrapperType']
      when 'track'
        output_url = result['trackViewUrl']
        output_title = "#{result['trackName']} by #{result['artistName']}"
      when 'collection'
        output_url = result['collectionViewUrl']
        output_title = "#{result['collectionName']} by #{result['artistName']}"
      when 'artist'
        output_url = result['artistLinkUrl']
        output_title = result['artistName']
      end
    when /podcast/
      output_url = result['collectionViewUrl']
      output_title = result['collectionName']
    end
    return false unless output_url && output_title

    return [output_url, output_title] if dev

    [output_url + aff, output_title]
  end

  def lastfm(entity, terms)
    url = URI.parse("http://ws.audioscrobbler.com/2.0/?method=#{entity}.search&#{entity}=#{ERB::Util.url_encode(terms)}&api_key=2f3407ec29601f97ca8a18ff580477de&format=json")
    res = Net::HTTP.get_response(url).body
    res = res.force_encoding('utf-8') if RUBY_VERSION.to_f > 1.9
    json = JSON.parse(res)
    return false unless json['results']

    begin
      case entity
      when 'track'
        result = json['results']['trackmatches']['track'][0]
        url = result['url']
        title = "#{result['name']} by #{result['artist']}"
      when 'artist'
        result = json['results']['artistmatches']['artist'][0]
        url = result['url']
        title = result['name']
      end
      [url, title]
    rescue StandardError
      false
    end
  end

  def define(terms)
    url = URI.parse("http://api.duckduckgo.com/?q=!def+#{ERB::Util.url_encode(terms)}&format=json&no_redirect=1&no_html=1&skip_disambig=1")
    res = Net::HTTP.get_response(url).body
    res = res.force_encoding('utf-8') if RUBY_VERSION.to_f > 1.9

    result = JSON.parse(res)

    if result
      wiki_link = result['Redirect'] || false
      title = terms

      if !wiki_link.empty? && !title.empty?
        return [wiki_link, title]
      end
    end

    def_url = "https://www.wordnik.com/words/#{ERB::Util.url_encode(terms)}"
    body = `/usr/bin/curl -sSL '#{def_url}'`
    if body =~ /id="define"/
      first_definition = body.match(%r{(?mi)(?:id="define"[\s\S]*?<li>)([\s\S]*?)</li>})[1]
      parts = first_definition.match(%r{<abbr title="partOfSpeech">(.*?)</abbr> (.*?)$})
      return [def_url, "(#{parts[1]}) #{parts[2]}".gsub(/ *<\/?.*?> /, '')]
    end

    false
  rescue StandardError
    false
  end

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

  # Search bookmark paths and addresses. Return array of bookmark hashes.
  def search_hook(search)
    path_matches = `osascript <<'APPLESCRIPT'
      set searchString to "#{search.strip}"
      tell application "Hook"
        set _marks to every bookmark whose name contains searchString or path contains searchString or address contains searchString
        set _out to {}
        repeat with _hook in _marks
          set _out to _out & (name of _hook & "||" & address of _hook & "||" & path of _hook)
        end repeat
        set {astid, AppleScript's text item delimiters} to {AppleScript's text item delimiters, "^^"}
        set _output to _out as string
        set AppleScript's text item delimiters to astid
        return _output
      end tell
    APPLESCRIPT`.strip.split_hooks

    top_match = path_matches.uniq.first
    return false unless top_match

    [top_match[:url], top_match[:name]]
  end

  def google(terms, define = false)
    uri = URI.parse("http://ajax.googleapis.com/ajax/services/search/web?v=1.0&filter=1&rsz=small&q=#{ERB::Util.url_encode(terms)}")
    req = Net::HTTP::Get.new(uri.request_uri)
    req['Referer'] = 'http://brettterpstra.com'
    res = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
    body = if RUBY_VERSION.to_f > 1.9
             res.body.force_encoding('utf-8')
           else
             res.body
           end

    json = JSON.parse(body)
    return ddg(terms, false) unless json['responseData']

    result = json['responseData']['results'][0]
    return false if result.nil?

    output_url = result['unescapedUrl']
    output_title = if define && output_url =~ /dictionary/
                     result['content'].gsub(/<\/?.*?>/, '')
                   else
                     result['titleNoFormatting']
                   end
    [output_url, output_title]
  rescue StandardError
    ddg(terms, false)
  end

  def ddg(terms, type = false)
    prefix = type ? "#{type.sub(/^!?/, '!')} " : '%5C'
    begin
      cmd = %(/usr/bin/curl -LisS --compressed 'https://lite.duckduckgo.com/lite/?q=#{prefix}#{ERB::Util.url_encode(terms)}')
      body = `#{cmd}`
      locs = body.force_encoding('utf-8').scan(/^location: (.*?)$/)
      return false if locs.empty?

      url = locs[-1]

      result = url[0].strip || false
      return false unless result

      output_url = CGI.unescape(result)
      output_title = if @cfg['include_titles'] || @titleize
                       titleize(output_url) || ''
                     else
                       ''
                     end
      [output_url, output_title]
    end
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

    return `#{gather} --title-only '#{url.strip}' --fallback-title 'Unkown'` if gather

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

  def spell(phrase)
    aspell = if File.exist?('/usr/local/bin/aspell')
               '/usr/local/bin/aspell'
             elsif File.exist?('/opt/homebrew/bin/aspell')
               '/opt/homebrew/bin/aspell'
             end

    if aspell.nil?
      add_error('Missing aspell', 'Install aspell in to allow spelling corrections')
      return false
    end

    words = phrase.split(/\b/)
    output = ''
    words.each do |w|
      if w =~ /[A-Za-z]+/
        spell_res = `echo "#{w}" | #{aspell} --sug-mode=bad-spellers -C pipe | head -n 2 | tail -n 1`
        if spell_res.strip == "\*"
          output += w
        else
          spell_res.sub!(/.*?: /, '')
          results = spell_res.split(/, /).delete_if { |word| phrase =~ /^[a-z]/ && word =~ /[A-Z]/ }
          output += results[0]
        end
      else
        output += w
      end
    end
    output
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

  def template_social(user, url, service)
    template = @cfg['social_template']
    template.sub!(/%user%/, user)
    template.sub!(/%service%/, service)
    template.sub!(/%url%/, url.sub(%r{^https?://(www\.)?}, '').sub(%r{/$}, ''))
    template
  end

  def social_handle(type, term)
    handle = term.sub(/^@/, '').strip
    case type
    when /^t/
      url = "https://twitter.com/#{handle}"
      title = template_social(handle, url, 'Twitter')
    when /^f/
      url = "https://www.facebook.com/#{handle}"
      title = template_social(handle, url, 'Facebook')
    when /^l/
      url = "https://www.linkedin.com/in/#{handle}/"
      title = template_social(handle, url, 'LinkedIn')
    when /^i/
      url = "https://www.instagram.com/#{handle}/"
      title = template_social(handle, url, 'Instagram')
    when /^m/
      parts = handle.split(/@/)
      return [false, term] unless parts.count == 2

      url = "https://#{parts[1]}/@#{parts[0]}"
      title = template_social(handle, url, 'Mastodon')
    else
      [false, term]
    end
    [url, title]
  end

  def do_search(search_type, search_terms, link_text = '', search_count = 0)
    if (search_count % 5).zero?
      notify('Throttling for 5s')
      sleep 5
    end

    notify('Searching', search_terms)
    return [false, search_terms, link_text] if search_terms.empty?

    case search_type
    when /^r$/ # simple replacement
      if @cfg['validate_links'] && !valid_link?(search_terms)
        return [false, "Link not valid: #{search_terms}", link_text]
      end

      link_text = search_terms if link_text == ''
      return [search_terms, link_text, link_text]
    when /^@t/ # twitter-ify username
      unless search_terms.strip =~ /^@?[0-9a-z_$]+$/i
        return [false, "#{search_terms} is not a valid Twitter handle", link_text]
      end

      url, title = social_handle('t', search_terms)
      link_text = title
    when /^@fb?/ # fb-ify username
      unless search_terms.strip =~ /^@?[0-9a-z_]+$/i
        return [false, "#{search_terms} is not a valid Facebook username", link_text]
      end

      url, title = social_handle('f', search_terms)
      link_text = title
    when /^@i/ # intagramify username
      unless search_terms.strip =~ /^@?[0-9a-z_]+$/i
        return [false, "#{search_terms} is not a valid Instagram username", link_text]
      end

      url, title = social_handle('i', search_terms)
      link_text = title
    when /^@l/ # linked-inify username
      unless search_terms.strip =~ /^@?[0-9a-z_]+$/i
        return [false, "#{search_terms} is not a valid LinkedIn username", link_text]
      end

      url, title = social_handle('l', search_terms)
      link_text = title
    when /^@m/ # mastodonify username
      unless search_terms.strip =~ /^@?[0-9a-z_]+@[0-9a-z_.]+$/i
        return [false, "#{search_terms} is not a valid Mastodon username", link_text]
      end

      url, title = social_handle('m', search_terms)
      link_text = title
    when /^sp(ell)?$/ # replace with spelling suggestion
      res = spell(search_terms)
      return [res, res, ''] if res

      url = false
    when /^hook$/
      url, title = search_hook(search_terms)
    when /^h(([scfabe])([hb])?)*$/
      mtch = Regexp.last_match(1)
      str = mtch
      types = []
      if str =~ /s([hb]*)/
        t = Regexp.last_match(1)
        if t.length > 1 || t.empty?
          types.push('safari_history')
          types.push('safari_bookmarks')
        elsif t == 'h'
          types.push('safari_history')
        elsif t == 'b'
          types.push('safari_bookmarks')
        end
      end

      if str =~ /c([hb]*)/
        t = Regexp.last_match(1)
        if t.length > 1 || t.empty?
          types.push('chrome_bookmarks')
          types.push('chrome_history')
        elsif t == 'h'
          types.push('chrome_history')
        elsif t == 'b'
          types.push('chrome_bookmarks')
        end
      end

      if str =~ /f([hb]*)/
        t = Regexp.last_match(1)
        if t.length > 1 || t.empty?
          types.push('firefox_bookmarks')
          types.push('firefox_history')
        elsif t == 'h'
          types.push('firefox_history')
        elsif t == 'b'
          types.push('firefox_bookmarks')
        end
      end

      if str =~ /e([hb]*)/
        t = Regexp.last_match(1)
        if t.length > 1 || t.empty?
          types.push('edge_bookmarks')
          types.push('edge_history')
        elsif t == 'h'
          types.push('edge_history')
        elsif t == 'b'
          types.push('edge_bookmarks')
        end
      end

      if str =~ /b([hb]*)/
        t = Regexp.last_match(1)
        if t.length > 1 || t.empty?
          types.push('brave_bookmarks')
          types.push('brave_history')
        elsif t == 'h'
          types.push('brave_history')
        elsif t == 'b'
          types.push('brave_bookmarks')
        end
      end

      if str =~ /a([hb]*)/
        t = Regexp.last_match(1)
        if t.length > 1 || t.empty?
          types.push('arc_bookmarks')
          types.push('arc_history')
        elsif t == 'h'
          types.push('arc_history')
        elsif t == 'b'
          types.push('arc_bookmarks')
        end
      end

      url, title = search_history(search_terms, types)
    when /^a$/
      az_url, = ddg("site:amazon.com #{search_terms}")
      url, title = amazon_affiliatize(az_url, @cfg['amazon_partner'])
    when /^(g|ddg)$/ # google lucky search
      url, title = ddg(search_terms)
    when /^z(ero)?/
      url, title = zero_click(search_terms)
    when /^yt$/
      url, title = ddg("site:youtube.com #{search_terms}")
    when /^pb$/
      url, title = pinboard(search_terms)
    when /^wiki$/
      url, title = wiki(search_terms)
    when /^def$/ # wikipedia/dictionary search
      # title, definition, definition_link, wiki_link = zero_click(search_terms)
      # if search_type == 'def' && definition_link != ''
      #   url = definition_link
      #   title = definition.gsub(/'+/,"'")
      # elsif wiki_link != ''
      #   url = wiki_link
      #   title = "Wikipedia: #{title}"
      # end
      fix = spell(search_terms)

      if fix && search_terms.downcase != fix.downcase
        add_error('Spelling', "Spelling altered for '#{search_terms}' to '#{fix}'")
        search_terms = fix
        link_text = fix
      end

      url, title = define(search_terms)
    when /^imov?$/ # iTunes movie search
      dev = false
      url, title = itunes('movie', search_terms, dev, @cfg['itunes_affiliate'])
    when /^masd?$/ # Mac App Store search (mas = itunes link, masd = developer link)
      dev = search_type =~ /d$/
      url, title = itunes('macSoftware', search_terms, dev, @cfg['itunes_affiliate'])

    when /^itud?$/ # iTunes app search
      dev = search_type =~ /d$/
      url, title = itunes('iPadSoftware', search_terms, dev, @cfg['itunes_affiliate'])

    when /^s$/ # software search (google)
      excludes = %w[apple.com postmates.com download.cnet.com softpedia.com softonic.com macupdate.com]
      url, title = ddg(%(#{excludes.map { |x| "-site:#{x}" }.join(' ')} #{search_terms} app))
      link_text = title if link_text == '' && !@titleize
    when /^tmdb/
      url, title = tmdb(search_type, search_terms)
      link_text = title if link_text == '' && !@titleize
    when /^am/ # apple music search
      stype = search_type.downcase.sub(/^am/, '')
      otype = 'link'
      if stype =~ /e$/
        otype = 'embed'
        stype.sub!(/e$/, '')
      end
      result = case stype
               when /^pod$/
                 applemusic(search_terms, 'podcast')
               when /^art$/
                 applemusic(search_terms, 'music', 'musicArtist')
               when /^alb$/
                 applemusic(search_terms, 'music', 'album')
               when /^song$/
                 applemusic(search_terms, 'music', 'musicTrack')
               else
                 applemusic(search_terms)
               end

      return [false, "Not found: #{search_terms}", link_text] unless result

      # {:type=>,:id=>,:url=>,:title=>}
      if otype == 'embed' && result[:type] =~ /(album|song)/
        url = 'embed'
        if result[:type] =~ /song/
          link = %(https://embed.music.apple.com/#{@cfg['country_code'].downcase}/album/#{result[:album]}?i=#{result[:id]}&app=music#{@cfg['itunes_affiliate']})
          height = 150
        else
          link = %(https://embed.music.apple.com/#{@cfg['country_code'].downcase}/album/#{result[:id]}?app=music#{@cfg['itunes_affiliate']})
          height = 450
        end

        title = [
          %(<iframe src="#{link}" allow="autoplay *; encrypted-media *;"),
          %(frameborder="0" height="#{height}"),
          %(style="width:100%;max-width:660px;overflow:hidden;background:transparent;"),
          %(sandbox="allow-forms allow-popups allow-same-origin),
          %(allow-scripts allow-top-navigation-by-user-activation"></iframe>)
        ].join(' ')
      else
        url = result[:url]
        title = result[:title]
      end

    when /^ipod$/
      url, title = itunes('podcast', search_terms, false)

    when /^isong$/ # iTunes Song Search
      url, title = itunes('song', search_terms, false)

    when /^iart$/ # iTunes Artist Search
      url, title = itunes('musicArtist', search_terms, false)

    when /^ialb$/ # iTunes Album Search
      url, title = itunes('album', search_terms, false)

    when /^lsong$/ # Last.fm Song Search
      url, title = lastfm('track', search_terms)

    when /^lart$/ # Last.fm Artist Search
      url, title = lastfm('artist', search_terms)
    else
      if search_terms
        if search_type =~ /.+?\.\w{2,4}$/
          url, title = ddg(%(site:#{search_type} #{search_terms}))
        else
          url, title = ddg(search_terms)
        end
      end
    end

    if link_text == ''
      link_text = @titleize ? title : search_terms
    end

    if url && @cfg['validate_links'] && !valid_link?(url) && search_type !~ /^sp(ell)?/
      [false, "Not found: #{url}", link_text]
    elsif !url
      [false, "No results: #{url}", link_text]
    else
      [url, title, link_text]
    end
  end
end

sl = SearchLink.new({ echo: false })
overwrite = true
backup = sl.cfg['backup']

if !ARGV.empty?
  files = []
  ARGV.each do |arg|
    case arg
    when /^(--?)?(h(elp)?|v(ersion)?)$/
      $stdout.puts "SearchLink v#{VERSION}"
      sl.help_cli
      $stdout.puts 'See http://brettterpstra.com/projects/searchlink/ for help'
      Process.exit
    when /^--?(stdout)$/
      overwrite = false
    when /^--?no[\-_]backup$/
      backup = false
    else
      files.push(arg)
    end
  end

  files.each do |file|
    if File.exist?(file) && `file -b "#{file}"|grep -c text`.to_i.positive?
      input = RUBY_VERSION.to_f > 1.9 ? IO.read(file).force_encoding('utf-8') : IO.read(file)

      FileUtils.cp(file, "#{file}.bak") if backup && overwrite

      sl.parse(input)

      if overwrite
        File.open(file, 'w') do |f|
          f.puts sl.output
        end
      else
        puts sl.output
      end
    else
      warn "Error reading #{file}"
    end
  end
else
  input = RUBY_VERSION.to_f > 1.9 ? $stdin.read.force_encoding('utf-8').encode : $stdin.read

  sl.parse(input)
  if sl.clipboard
    print input
  else
    print sl.output
  end
end
