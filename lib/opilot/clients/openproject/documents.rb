module OPilot
  module Clients
    module OpenProject
      # The v3 Documents API (product-development intake). It is provided by
      # the `documents` project module, so it 404s unless that module is
      # enabled on the project and the token carries :view_documents. Its query
      # supports project/document/title/type filters but NOT updatedAt, so any
      # "since" narrowing is client-side.
      module Documents
        # The project filter coerces its values to integers, so a project
        # IDENTIFIER ("my-project") would match nothing and the sweep would come
        # back empty. So only a NUMERIC id is taken (Lookup#project_id).
        def documents(project_id, page: 1, page_size: 100)
          unless project_id.to_s.match?(/\A\d+\z/)
            raise ArgumentError, "documents needs a numeric project id, got #{project_id.inspect}"
          end

          collection("documents", filters_json: Query.filter("project", "=", project_id),
                                  page: page, page_size: page_size)
        end

        # One document, with links embedded — carries title, the formattable
        # description, created_at/updated_at, and the project link that
        # Intake uses to verify a --doc-id belongs to the named project.
        def document(document_id)
          get("documents/#{document_id}")
        end

        # Attachment metadata for a document: fileName, contentType, fileSize and
        # _links.downloadLocation for each. The content itself is fetched with
        # #download_attachment, since it is binary and behind a redirect.
        def document_attachments(document_id)
          get("documents/#{document_id}/attachments", pageSize: 100)
        end
      end
    end
  end
end
