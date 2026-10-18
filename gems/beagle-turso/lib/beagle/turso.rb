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
    # Whether statements (Connection#execute, #query, #query_result,
    # #query_result_with_types, #execute_batch) release the GVL: :release (the
    # default) lets other threads run and a worker-pool fiber scheduler offload
    # them; :hold keeps them under the GVL, as in 0.3.0. Process-wide.
    def self.statement_gvl
      _statement_gvl_hold? ? :hold : :release
    end

    def self.statement_gvl=(mode)
      unless mode == :hold || mode == :release
        raise ArgumentError, "statement_gvl must be :hold or :release"
      end
      _set_statement_gvl_hold(mode == :hold)
    end

    private_class_method :_statement_gvl_hold?, :_set_statement_gvl_hold

    # Case and surrounding space don't matter. Anything else is most likely a
    # typo in a rollback attempt, so it is reported rather than ignored.
    case (env_gvl = ENV["BEAGLE_TURSO_STATEMENT_GVL"].to_s).strip.downcase
    when "hold" then self.statement_gvl = :hold
    when "", "release" then nil
    else
      warn "beagle-turso: ignoring BEAGLE_TURSO_STATEMENT_GVL=#{env_gvl.inspect} " \
           "(expected hold or release); statements release the GVL"
    end

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
