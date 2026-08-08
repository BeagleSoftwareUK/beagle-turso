require_relative "turso/version"

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
      # takes its arguments positionally.
      def self.open(local_path:, remote_url: nil, auth_token: nil, bootstrap_if_empty: true)
        _open(local_path, remote_url, auth_token, bootstrap_if_empty)
      end

      private_class_method :_open
    end
  end
end
