# Main SearchLink class
module SL
  include URL

  class SearchLink
    include Plist

    attr_reader :originput, :output, :clipboard

    private

    def do_search(search_type, search_terms, link_text = '', search_count = 0)
      if (search_count % 5).zero?
        SL.notify('Throttling for 5s')
        sleep 5
      end

      SL.notify('Searching', search_terms)
      return [false, search_terms, link_text] if search_terms.empty?

      if SL::Searches.valid_search?(search_type)
        url, title, link_text = SL::Searches.do_search(search_type, search_terms, link_text)
      else
        case search_type
        when /^r$/ # simple replacement
          if SL.config['validate_links'] && !SL::URL.valid_link?(search_terms)
            return [false, "Link not valid: #{search_terms}", link_text]
          end

          link_text = search_terms if link_text == ''
          return [search_terms, link_text, link_text]
        else
          if search_terms
            if search_type =~ /.+?\.\w{2,}$/
              url, title = SL.ddg(%(site:#{search_type} #{search_terms}), link_text)
            else
              url, title = SL.ddg(search_terms, link_text)
            end
          end
        end
      end

      if link_text == ''
        link_text = SL.titleize ? title : search_terms
      end

      if url && SL.config['validate_links'] && !SL::URL.valid_link?(url) && search_type !~ /^sp(ell)?/
        [false, "Not found: #{url}", link_text]
      elsif !url
        [false, "No results: #{url}", link_text]
      else
        [url, title, link_text]
      end
    end
  end
end
