require "net/http"
require "uri"
require "json"

module Chomper
  module HTTP
    Error = Class.new(RuntimeError)

    # Returns [status_code, body_string]. Never raises on HTTP errors.
    def self.get(url, token:)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      read_timeout: 30, open_timeout: 10) do |http|
        req = Net::HTTP::Get.new(uri)
        req.basic_auth("apikey", token)
        req["Content-Type"] = "application/json"
        res = http.request(req)
        [res.code.to_i, res.body]
      end
    rescue => e
      raise Error, "HTTP request failed for #{url}: #{e.message}"
    end

    # Returns [status_code, parsed_hash_or_nil].
    def self.get_json(url, token:)
      code, body = get(url, token: token)
      parsed = JSON.parse(body) rescue nil
      [code, parsed]
    end

    # Returns [status_code, parsed_hash], raises on non-200.
    def self.get_json!(url, token:)
      code, parsed = get_json(url, token: token)
      raise Error, "#{url} returned HTTP #{code}" unless code == 200
      [code, parsed]
    end

    def self.post_json(url, body, token:)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      read_timeout: 30, open_timeout: 10) do |http|
        req = Net::HTTP::Post.new(uri)
        req.basic_auth("apikey", token)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        res = http.request(req)
        parsed = JSON.parse(res.body) rescue nil
        [res.code.to_i, parsed]
      end
    rescue => e
      raise Error, "HTTP request failed for #{url}: #{e.message}"
    end

    def self.patch_json(url, body, token:)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      read_timeout: 30, open_timeout: 10) do |http|
        req = Net::HTTP::Patch.new(uri)
        req.basic_auth("apikey", token)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        res = http.request(req)
        parsed = JSON.parse(res.body) rescue nil
        [res.code.to_i, parsed]
      end
    rescue => e
      raise Error, "HTTP request failed for #{url}: #{e.message}"
    end

    def self.encode_filters(filters_json)
      URI.encode_www_form_component(filters_json)
    end
  end
end
