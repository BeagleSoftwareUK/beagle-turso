require "beagle/turso"

RSpec.describe "Connection#query_result_with_types" do
  it "returns columns, declared types and rows" do
    conn = Beagle::Turso::Database.open_local(":memory:").connect
    conn.execute("CREATE TABLE t (d DATE, b BOOLEAN, n)", [])
    conn.execute("INSERT INTO t VALUES ('2026-10-17', 1, 2)", [])
    columns, types, rows = conn.query_result_with_types("SELECT d, b, n, 1 + 1 AS expr FROM t", [])
    expect(columns).to eq(%w[d b n expr])
    expect(types).to eq(["DATE", "BOOLEAN", nil, nil])
    expect(rows).to eq([["2026-10-17", 1, 2, 2]])
  end

  it "leaves query_result's two-element shape unchanged" do
    conn = Beagle::Turso::Database.open_local(":memory:").connect
    expect(conn.query_result("SELECT 1 AS x", [])).to eq([["x"], [[1]]])
  end
end
