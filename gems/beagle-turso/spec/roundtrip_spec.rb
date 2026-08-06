require "beagle/turso"

RSpec.describe "local round-trip" do
  it "creates, inserts, and queries via persistent objects" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    conn.execute("CREATE TABLE t (id INTEGER, name TEXT)", [])
    affected = conn.execute("INSERT INTO t (id, name) VALUES (?, ?)", [1, "alice"])
    expect(affected).to eq(1)
    rows = conn.query("SELECT id, name FROM t", [])
    expect(rows).to eq([[1, "alice"]])
  end
end
