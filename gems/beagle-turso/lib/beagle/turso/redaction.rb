require "uri"

module Beagle
  module Turso
    # Strips credentials from text before it reaches a log, a status or a
    # callback. Engine error messages can embed the remote URL; the auth token
    # itself is sent as a header, but a URL can still carry userinfo or a
    # token query parameter, so reduce every URL to scheme://host.
    module Redaction
      URL = %r{\b([a-z][a-z0-9+.-]*)://(?:[^/\s?#"'@]+@)?([^/\s?#"':]+)[^\s"']*}i
      SECRET_PARAM = /\b(auth_?token|token|password|secret)(["']?\s*[=:]\s*["']?)[^\s"'&,;]+/i
      BEARER = /\b(Bearer)\s+\S+/i

      module_function

      def message(text)
        text.to_s
          .gsub(URL) { "#{Regexp.last_match(1)}://#{Regexp.last_match(2)}" }
          .gsub(SECRET_PARAM) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}[redacted]" }
          .gsub(BEARER, '\1 [redacted]')
      end

      def host(url)
        URI.parse(url.to_s).host
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
