module SL
  class AmazonSearch
    class << self
      def settings
        {
          trigger: 'a',
          searches: [
            ['a', 'Amazon Search']
          ]
        }
      end

      def search(search_type, search_terms, link_text)
        az_url, = SL.ddg("site:amazon.com #{search_terms}", link_text)
        url, title = SL::URL.amazon_affiliatize(az_url, SL.config['amazon_partner'])
        title ||= search_terms

        [url, title, link_text]
      end
    end

    SL::Searches.register 'amazon', :search, self
  end
end
