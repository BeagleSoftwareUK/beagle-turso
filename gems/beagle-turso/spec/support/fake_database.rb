# A stand-in for a synced Beagle::Turso::Database: counts push/pull calls and
# runs a scriptable hook on each, so specs can inject failures and delays
# without a network.
class FakeDatabase
  attr_reader :remote_host, :pushes, :pulls, :calls
  attr_writer :on_push, :on_pull

  def initialize(remote_host: "db-acme.turso.io", synced: true)
    @remote_host = remote_host
    @synced = synced
    @pushes = 0
    @pulls = 0
    @calls = []
    @lock = Mutex.new
    @on_push = nil
    @on_pull = nil
  end

  def synced? = @synced

  def push
    @lock.synchronize { @pushes += 1; @calls << :push }
    @on_push&.call
    nil
  end

  def pull
    @lock.synchronize { @pulls += 1; @calls << :pull }
    @on_pull&.call
    true
  end
end
