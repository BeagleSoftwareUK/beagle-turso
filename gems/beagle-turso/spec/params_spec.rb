require "beagle/turso"

RSpec.describe "bind parameter types" do
  it "round-trips a Float as Float, not truncated to Integer" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    row = conn.query("SELECT ?, typeof(?)", [3.5, 3.5]).first
    expect(row).to eq([3.5, "real"])
  end

  it "round-trips an Integer as Integer, not widened to Float" do
    db = Beagle::Turso::Database.open_local(":memory:")
    conn = db.connect
    row = conn.query("SELECT ?, typeof(?)", [7, 7]).first
    expect(row).to eq([7, "integer"])
  end
end
