module Beagle
  module Turso
    # Base class for every error the native driver raises. A RuntimeError so
    # code written against 0.1.x, which raised bare RuntimeErrors, still rescues.
    class Error < RuntimeError; end

    class OpenError < Error; end
    class ConnectError < Error; end
    class QueryError < Error; end
    class SyncError < Error; end
    # push/pull on a database opened without remote_url:/auth_token:.
    class NotSyncedError < Error; end
    # The engine reported the database busy (another session or process holds it).
    class BusyError < Error; end
    class ClosedError < Error; end
    # A handle opened in a parent process was used after fork; open a new one.
    class ForkedError < Error; end
  end
end
