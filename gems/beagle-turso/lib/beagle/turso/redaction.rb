require "uri"

module Beagle
  module Turso
    # Strips credentials from text before it reaches a log, a status or a
    # callback. Engine error messages can embed the remote URL; the auth token
    # itself is sent as a header, but a URL can still carry userinfo or a
    # token query parameter, so reduce every URL to scheme://host.
    module Redaction
      # scheme://[userinfo@]host[...]: keep scheme and host (a bracketed IPv6
      # literal included), drop userinfo, port, path, query and fragment. The
      # scheme length is bounded so a long run of "a.a.a." stays linear.
      URL = %r{\b([a-z][a-z0-9+.-]{0,31})://(?:[^/\s?#"'@\[]+@)?(\[[0-9a-f:.]*\]|[^/\s?#"':\[]+)[^\s"']*}i
      # Authorization schemes: keep the scheme word, blank the credential.
      AUTH_SCHEME = /\b(Bearer|Basic)\s+[^\s"',;]+/i
      # key=value / key: value / "key": "value" / key%3Dvalue, where the key is
      # a whole word ending in a secret-ish name (turso_auth_token, x-api-key,
      # access_token, ...). The lookbehind pins the key to a word start, which
      # keeps the unbounded prefix linear.
      SECRET_PARAM = /(?<![\w-])([\w-]*?(?:auth_?token|token|jwt|api[_-]?key|password|passwd|secret|authorization))(["']?\s*(?:[=:]|%3D)\s*["']?)(?!(?:Bearer|Basic)\s)[^\s"'&,;]+/i
      # A bare JWT (header.payload.signature, base64url).
      JWT = /\beyJ[\w-]+\.[\w-]+\.[\w-]+/

      module_function

      def message(text)
        text.to_s
          .gsub(URL) { "#{Regexp.last_match(1)}://#{Regexp.last_match(2)}" }
          .gsub(JWT, "[redacted]")
          .gsub(AUTH_SCHEME, '\1 [redacted]')
          .gsub(SECRET_PARAM) { "#{Regexp.last_match(1)}#{Regexp.last_match(2)}[redacted]" }
      end

      def host(url)
        URI.parse(url.to_s).host
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
