require_relative "turso/version"
require "beagle_turso/beagle_turso" # native extension

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
