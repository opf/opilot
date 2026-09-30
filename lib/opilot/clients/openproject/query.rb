module OPilot
  module Clients
    module OpenProject
      # Query-string values: the `filters` and `sortBy` JSON the collections take.
      module Query
        module_function

        SORT_UPDATED_AT = '[["updatedAt","desc"]]'.freeze

        # The `filters` query value: a JSON array of single-key objects. Values are
        # stringified because the encoded string identifies the request — an
        # Integer here would silently move every URL built through this.
        def filter(field, operator, *values)
          JSON.generate([{ field.to_s => { "operator" => operator.to_s,
                                           "values" => values.flatten.map(&:to_s) } }])
        end
      end
    end
  end
end
