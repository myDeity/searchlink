module SL
  class GitHubSearch
    class << self
      def settings
        {
          trigger: '(?:gist|gh)',
          searches: [
            ['gh', 'GitHub User/Repo Link'],
            ['gist', 'Gist Search'],
            ['giste', 'Gist Embed']
          ]
        }
      end

      def search(search_type, search_terms, link_text)
        case search_type
        when /^gist/
          url, title = gist(search_terms, search_type)
        else
          url, title = github(search_terms, link_text)
        end

        [url, title, link_text]
      end

      def github(search_terms, link_text)
        terms = search_terms.split(%r{[ /]+})
        # SL.config['remove_seo'] = false

        url = case terms.count
              when 2
                "https://github.com/#{terms[0]}/#{terms[1]}"
              when 1
                "https://github.com/#{terms[0]}"
              else
                url, title = SL.ddg("site:github.com #{search_terms}", link_text)
              end

        if SL::URL.valid_link?(url)
          title = SL::URL.get_title(url) if title.nil?

          [url, title]
        else
          SL.notify('Searching GitHub', 'Repo not found, performing search')
          SL.ddg("site:github.com #{search_terms}", link_text)
        end
      end

      def gist(terms, type)
        terms.strip!
        case terms
        when %r{^(?<id>[a-z0-9]{32})(?:[#/](?<file>(file-)?.*?))?$}
          m = Regexp.last_match
          res = `curl -SsLI 'https://gist.github.com/#{m['id']}'`.strip
          url = res.match(/^location: (.*?)$/)[1].strip
          title = titleize(url)
          if m['file']
            url = "#{url}##{m['file']}"
            title = "#{title}: #{m['file']}"
          end
        when %r{^(?<u>\S+)/(?<id>[a-z0-9]{32})(?:[#/](?<file>(file-)?.*?))?$}
          m = Regexp.last_match
          url = "https://gist.github.com/#{m['u']}/#{m['id']}"
          title = titleize(url)
          if m['file']
            url = "#{url}##{m['file']}"
            title = "#{title}: #{m['file']}"
          end
        when %r{(?<url>https://gist.github.com/(?<user>\w+)/(?<id>[a-z0-9]{32}))(?:[#/](?<file>(file-)?.*?))?$}
          m = Regexp.last_match
          url = m['url']
          title = titleize(url)
          if m['file']
            url = "#{url}##{m['file']}"
            title = "#{title}: #{m['file']}"
          end
        else
          url, title = SL.ddg("site:gist.github.com #{terms}", link_text)
        end

        if url =~ %r{https://gist.github.com/(?<user>\w+)/(?<id>[a-z0-9]+?)(?:[#/](?<file>(file-)?.*?))?$}
          m = Regexp.last_match
          user = m['user']
          id = m['id']

          if type =~ /e$/
            url = if m['file']
                    "https://gist.github.com/#{user}/#{id}.js?file=#{m['file'].fix_gist_file}"
                  else
                    "https://gist.github.com/#{user}/#{id}.js"
                  end

            ['embed', %(<script src="#{url}"></script>)]
          else
            [url, title]
          end
        else
          [false, title]
        end
      end
    end

    SL::Searches.register 'github', :search, self
  end
end
