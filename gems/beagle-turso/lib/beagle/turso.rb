require_relative "turso/version"
require_relative "turso/errors"
require_relative "turso/redaction"
require_relative "turso/syncer"

# Load the native extension. Precompiled ("fat") gems ship the .so under a
# per-Ruby-ABI subdir (lib/beagle_turso/<major.minor>/beagle_turso.so); a
# source build (dev, or the source-fallback gem) puts it flat at
# lib/beagle_turso/beagle_turso.so. Try the versioned path first, fall back.
begin
  require "beagle_turso/#{RUBY_VERSION[/\d+\.\d+/]}/beagle_turso"
rescue LoadError
  require "beagle_turso/beagle_turso"
end

module Beagle
  module Turso
    class Database
      # Opens a local-only database, or one synced with a remote Turso
      # database when both `remote_url` and `auth_token` are given (see
      # `#push`/`#pull`). Delegates to the native `_open` primitive, which
      # takes its arguments positionally. Only the remote host is kept on
      # the Ruby object; the token is never stored.
      def self.open(local_path:, remote_url: nil, auth_token: nil, bootstrap_if_empty: true)
        db = _open(local_path, remote_url, auth_token, bootstrap_if_empty)
        if remote_url && auth_token
          db.instance_variable_set(:@synced, true)
          db.instance_variable_set(:@remote_host, Redaction.host(remote_url))
        end
        db
      end

      private_class_method :_open

      # True when opened with both remote_url: and auth_token:, i.e. when
      # #push/#pull talk to a remote.
      def synced?
        @synced == true
      end

      # The remote database's host, without scheme, path, query or
      # credentials; nil for a local-only database.
      attr_reader :remote_host
    end
  end
end
