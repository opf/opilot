source "https://rubygems.org"

gem "rainbow"
gem "tty-markdown" # renders Claude's streamed Markdown for the terminal (display only)
gem "octokit"
gem "faraday-retry" # silences octokit/faraday v2 warning; not called directly
gem "git"
gem "retriable"
# Spreadsheet reader for intake attachments (xlsx/xlsm/ods/csv). Also pulls in
# rubyzip + nokogiri, which the hand-rolled docx/pptx extraction reuses — so
# this one gem covers every OOXML format the intake converter handles.
gem "roo", "~> 3.0"

group :test do
  gem "rake"
  gem "webmock"
end
