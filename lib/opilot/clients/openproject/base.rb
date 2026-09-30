module OPilot
  module Clients
    module OpenProject
      # The transport every endpoint module is written against: the instance
      # URL, the token, and one way to build and send a request.
      class Base
        def initialize(base_url, token)
          @base  = base_url
          @token = token
        end

        private

        # Every endpoint URL, built here. Query values are form-encoded, which
        # leaves numbers and booleans as they are; a nil value is left out.
        def url(path, **query)
          pairs = query.compact.map { |key, value| "#{key}=#{HTTP.encode_filters(value.to_s)}" }
          "#{@base}/api/v3/#{path}#{"?#{pairs.join("&")}" if pairs.any?}"
        end

        def get(path, **query)
          send_request("GET #{path}") { HTTP.get_json(url(path, **query), token: @token) }
        end

        def post(path, body, **query)
          send_request("POST #{path}") { HTTP.post_json(url(path, **query), body, token: @token) }
        end

        def patch(path, body, **query)
          send_request("PATCH #{path}") { HTTP.patch_json(url(path, **query), body, token: @token) }
        end

        # A Response from the transport's [code, body], and a NetworkError for
        # a request that got no answer — the one place the transport's own
        # error class is translated.
        def send_request(request)
          code, body = yield
          Response.new(code, body, request)
        rescue HTTP::Error => e
          raise NetworkError, e.message
        end

        # A filterable, paginated collection. `offset` is OpenProject's page
        # number, not an element offset.
        def collection(path, filters_json:, page:, page_size:, **query)
          get(path, pageSize: page_size, offset: page, filters: filters_json, **query)
        end
      end
    end
  end
end
