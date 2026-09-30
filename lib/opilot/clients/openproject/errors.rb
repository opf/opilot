module OPilot
  module Clients
    module OpenProject
      # Every failure the SDK raises. `code` is the HTTP status (nil for a
      # network failure); `body` is the parsed error body. The body is never
      # part of the message: it can be large, or quote internal comments.
      class Error < StandardError
        attr_reader :code, :body

        def initialize(message, code: nil, body: nil)
          @code = code
          @body = body
          super(message)
        end

        # Worth asking again later: a bad minute, not an answer. The transport
        # has already retried by the time this is raised.
        def transient? = false

        def self.for(code, body, message)
          klass = STATUS_ERRORS[code] ||
                  case code
                  when 200..299 then InvalidResponse
                  when 500..599 then ServerError
                  else ClientError
                  end
          klass.new(message, code: code, body: body)
        end
      end

      # No answer at all, after the transport's retries.
      class NetworkError < Error
        def transient? = true
      end

      # Any 4xx without a class of its own.
      class ClientError < Error; end
      class Unauthorized < ClientError; end
      class Forbidden < ClientError; end
      class NotFound < ClientError; end
      # A stale lockVersion, after the one retry #update_work_package makes.
      class Conflict < ClientError; end
      # A 422 from a write. The forms answer 200 for an invalid payload, so
      # this never fires there: read `_embedded.validationErrors` instead.
      class ValidationFailed < ClientError; end

      class RateLimited < ClientError
        def transient? = true
      end

      class ServerError < Error
        def transient? = true
      end

      # A 2xx whose body is not JSON — a proxy's HTML page, say.
      class InvalidResponse < Error; end

      Error::STATUS_ERRORS = { 401 => Unauthorized, 403 => Forbidden, 404 => NotFound,
                               409 => Conflict, 422 => ValidationFailed, 429 => RateLimited }.freeze
    end
  end
end
