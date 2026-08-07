require "beagle/turso"

RSpec.describe "adapter primitives" do
  it "returns columns + rows in SELECT order, rowid, and batch" do
    c = Beagle::Turso::Database.open_local(":memory:").connect
    c.execute_batch("CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT); INSERT INTO t (n) VALUES ('a');")

    # Reversed vs table declaration order, to genuinely pin column order
    # rather than coincidentally matching it.
    cols, rows = c.query_result("SELECT n, id FROM t", [])
    expect(cols).to eq(["n", "id"])
    expect(rows).to eq([["a", 1]])
    expect(c.last_insert_rowid).to eq(1)
  end
end
