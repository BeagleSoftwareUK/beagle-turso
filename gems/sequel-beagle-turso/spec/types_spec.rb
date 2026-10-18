require "bigdecimal"

RSpec.describe "Sequel::BeagleTurso value conversion" do
  let(:db) { Sequel.connect(adapter: :beagle_turso, database: tmp_db) }
  after { db.close_replica }

  before do
    db.create_table(:v) do
      Integer :i
      BigDecimal :d, size: [10, 2]
      Float :f
      TrueClass :b
      Date :dt
      DateTime :ts
      Time :tm, only_time: true
      String :s
      File :bl
    end
  end

  it "round-trips each type to the right Ruby class" do
    db[:v].insert(i: 7, d: BigDecimal("12.50"), f: 1.5, b: true, dt: Date.new(2026, 10, 17),
                  ts: Time.utc(2026, 10, 17, 12, 34, 56), tm: Sequel::SQLTime.create(9, 8, 7),
                  s: "hi", bl: Sequel.blob("\x00\x01".b))
    r = db[:v].first
    expect(r[:i]).to eq(7)
    expect(r[:d]).to eq(BigDecimal("12.5"))
    expect(r[:f]).to eq(1.5)
    expect(r[:b]).to be(true)
    expect(r[:dt]).to eq(Date.new(2026, 10, 17))
    expect(r[:ts]).to be_a(Time)
    # Sequel's default timezone handling writes and reads wall-clock time, so
    # compare without converting zones (works whatever the machine's TZ is).
    expect(r[:ts].strftime("%F %T")).to eq("2026-10-17 12:34:56")
    expect(r[:tm].strftime("%T")).to eq("09:08:07")
    expect(r[:s]).to eq("hi")
    expect(r[:bl]).to be_a(Sequel::SQL::Blob)
    expect(r[:bl].bytes).to eq([0, 1])
  end

  it "reads false booleans and leaves NULLs unconverted" do
    db[:v].insert(b: false)
    r = db[:v].first
    expect(r[:b]).to be(false)
    expect(r[:dt]).to be_nil
    expect(r[:d]).to be_nil
  end

  it "leaves expression columns as the engine returns them" do
    db[:v].insert(i: 2)
    expect(db[:v].select { (i + 1).as(:x) }.first[:x]).to eq(3)
  end

  it "reports columns for an empty result" do
    expect(db[:v].where(i: -1).columns).to include(:i, :d, :b)
    expect(db[:v].where(i: -1).all).to eq([])
  end
end
