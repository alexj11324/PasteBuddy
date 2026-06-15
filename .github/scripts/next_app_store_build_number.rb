#!/usr/bin/env ruby

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

BASE_URL = "https://api.appstoreconnect.apple.com"

key_id = ENV.fetch("ASC_KEY_ID")
issuer_id = ENV.fetch("ASC_ISSUER_ID")
private_key_path = ENV.fetch("ASC_API_KEY_PATH")
app_id = ENV.fetch("ASC_APP_ID")
minimum_build_number = ENV.fetch("MIN_BUILD_NUMBER", "0").to_i

def jwt(key_id:, issuer_id:, private_key_path:)
  key = OpenSSL::PKey::EC.new(File.read(private_key_path))
  now = Time.now.to_i
  header = { alg: "ES256", kid: key_id, typ: "JWT" }
  payload = { iss: issuer_id, iat: now, exp: now + 900, aud: "appstoreconnect-v1" }
  encode = ->(object) { Base64.urlsafe_encode64(object.to_json).delete("=") }
  unsigned = "#{encode.call(header)}.#{encode.call(payload)}"
  digest = OpenSSL::Digest::SHA256.digest(unsigned)
  der_signature = key.dsa_sign_asn1(digest)
  raw_signature = OpenSSL::ASN1.decode(der_signature).value.map do |integer|
    integer.value.to_s(2).rjust(32, "\x00")[-32, 32]
  end.join
  "#{unsigned}.#{Base64.urlsafe_encode64(raw_signature).delete("=")}"
end

token = jwt(key_id: key_id, issuer_id: issuer_id, private_key_path: private_key_path)

def get_json(path_or_url, token)
  uri = path_or_url.start_with?("https://") ? URI(path_or_url) : URI("#{BASE_URL}#{path_or_url}")
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  parsed = JSON.parse(response.body) rescue { "raw" => response.body }
  unless response.code.to_i == 200
    warn JSON.pretty_generate(parsed)
    abort "App Store Connect request failed: #{response.code}"
  end
  parsed
end

versions = []
next_url = "/v1/apps/#{app_id}/builds?limit=200"

while next_url
  parsed = get_json(next_url, token)
  parsed.fetch("data", []).each do |build|
    version = build.dig("attributes", "version").to_s
    versions << version.to_i if version.match?(/\A\d+\z/)
  end
  next_url = parsed.dig("links", "next")
end

puts([versions.max || 0, minimum_build_number].max + 1)
