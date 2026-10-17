require "beagle/turso"
require "timeout"

RSpec.describe "fork safety" do
  before { skip "fork unsupported on this platform" unless Process.respond_to?(:fork) }

  it "raises ForkedError in the child, exits cleanly, and leaves the parent working" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    conn.execute("CREATE TABLE t (n INTEGER)", [])

    rd, wr = IO.pipe
    pid = fork do
      rd.close
      outcome = [-> { conn.query("SELECT 1", []) }, -> { db.connect }].map do |op|
        op.call
        "no error"
      rescue Beagle::Turso::ForkedError
        "forked"
      rescue => e
        "other #{e.class}"
      end
      db.close # silent no-op in the child
      wr.write(outcome.join(","))
      wr.close
      exit(0) # normal exit: finalizers for the inherited handles run and must not hang
    end
    wr.close

    status = begin
      Timeout.timeout(10) { Process.wait2(pid).last }
    rescue Timeout::Error
      Process.kill(:KILL, pid)
      Process.wait(pid)
      raise "child hung on exit (inherited handle finalizer)"
    end

    expect(rd.read).to eq("forked,forked")
    expect(status.success?).to be(true)
    expect(conn.query("SELECT 1", [])).to eq([[1]])
  end
end
