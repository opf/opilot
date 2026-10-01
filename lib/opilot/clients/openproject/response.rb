module OPilot
  module Clients
    module OpenProject
      # What every endpoint returns. Read #code and #body, or call #value!,
      # which raises a typed Error.
      class Response
        attr_reader :code, :body, :request

        def initialize(code, body, request)
          @code    = code
          @body    = body
          @request = request
        end

        # A 2xx with a body. 204 carries none by design.
        def ok?
          (200..299).cover?(code) && (!body.nil? || code == 204)
        end

        def value!
          return body if ok?
          raise Error.for(code, body, "#{request} answered HTTP #{code}#{" without a JSON body" if (200..299).cover?(code)}")
        end

        # A form (`POST …/form`) answers 200 even for a payload it rejects, so its
        # verdict is in the body. False when the form did not run at all: a 403,
        # or a proxy's HTML.
        def form_answered? = code == 200 && body.is_a?(Hash)

        # The form's validation errors, keyed by property, or nil when there are
        # none — or when the form did not answer (see #form_answered?).
        def validation_errors
          return nil unless form_answered?
          errors = body.dig("_embedded", "validationErrors")
          errors.is_a?(Hash) && !errors.empty? ? errors : nil
        end

        def inspect = "#<#{self.class.name.split("::").last} #{request} → #{code}>"
      end
    end
  end
end
