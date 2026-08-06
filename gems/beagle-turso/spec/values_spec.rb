require "beagle/turso"

RSpec.describe "value kinds" do
  it "round-trips every kind, including a true binary BLOB" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    conn.execute("CREATE TABLE k (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)", [])

    blob = "\xFF\x00\xFE".b

    conn.execute("INSERT INTO k VALUES (?, ?, ?, ?, ?)", [42, 3.5, "hi", blob, nil])

    row = conn.query("SELECT i, r, t, b, n FROM k", []).first
    expect(row[0]).to eq(42)
    expect(row[1]).to eq(3.5)
    expect(row[2]).to eq("hi")
    expect(row[3]).to eq(blob)
    expect(row[4]).to be_nil

    typeof_row = conn.query(
      "SELECT typeof(i), typeof(r), typeof(t), typeof(b), typeof(n) FROM k",
      []
    ).first
    expect(typeof_row).to eq(["integer", "real", "text", "blob", "null"])
  end
end
