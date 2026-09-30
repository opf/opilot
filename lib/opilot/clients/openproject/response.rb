module OPilot
  module Clients
    module OpenProject
      # What every endpoint returns. It destructures like the old tuple
      # (`code, body = client.work_package(42)`), so existing callers keep
      # working; new code calls #value!, which raises a typed Error.
      class Response
        attr_reader :code, :body, :request

        def initialize(code, body, request)
          @code    = code
          @body    = body
          @request = request
        end

        def to_ary = [code, body]

        # A 2xx with a body. 204 carries none by design.
        def ok?
          (200..299).cover?(code) && (!body.nil? || code == 204)
        end

        def value!
          return body if ok?
          raise Error.for(code, body, "#{request} answered HTTP #{code}#{" without a JSON body" if (200..299).cover?(code)}")
        end

        # Equal to the tuple it destructures to, so `[404, nil] == response` holds.
        def ==(other)
          other.respond_to?(:to_ary) && to_ary == other.to_ary
        end
        alias eql? ==

        def hash = to_ary.hash

        def inspect = "#<#{self.class.name.split("::").last} #{request} → #{code}>"
      end
    end
  end
end
