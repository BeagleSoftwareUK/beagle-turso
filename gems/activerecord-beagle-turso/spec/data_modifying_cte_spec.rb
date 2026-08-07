# frozen_string_literal: true

require "spec_helper"

# FIX #2: AR's write_query? classifies a leading `WITH` as a READ, so a
# data-modifying CTE (`WITH ... UPDATE/INSERT/DELETE`, no RETURNING) would be
# routed to query_result -- the write still persists, but the affected-row count
# comes back nil and a CTE-INSERT's rowid is lost. The adapter detects these and
# routes them to the write branch (execute -> real affected count + rowid).
RSpec.describe "beagle_turso adapter data-modifying CTE" do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :gadgets, force: true do |t|
        t.string :name
        t.integer :qty
      end
    end
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  let(:gadget_class) { Class.new(ActiveRecord::Base) { self.table_name = "gadgets" } }

  it "returns the correct affected count for a WITH ... UPDATE (data-modifying CTE)" do
    3.times { |i| gadget_class.create!(name: "g#{i}", qty: 1) }
    conn = ActiveRecord::Base.connection

    sql = <<~SQL.squish
      WITH bump AS (SELECT id FROM gadgets WHERE qty = 1)
      UPDATE gadgets SET qty = 2 WHERE id IN (SELECT id FROM bump)
    SQL

    affected = conn.exec_update(sql, "CTE-UPDATE")
    expect(affected).to eq(3)
    expect(gadget_class.where(qty: 2).count).to eq(3)
  end

  it "reports the affected count for a WITH ... DELETE (data-modifying CTE)" do
    gadget_class.delete_all
    5.times { |i| gadget_class.create!(name: "d#{i}", qty: 7) }
    conn = ActiveRecord::Base.connection

    sql = <<~SQL.squish
      WITH doomed AS (SELECT id FROM gadgets WHERE qty = 7)
      DELETE FROM gadgets WHERE id IN (SELECT id FROM doomed)
    SQL

    affected = conn.exec_delete(sql, "CTE-DELETE")
    expect(affected).to eq(5)
    expect(gadget_class.count).to eq(0)
  end

  it "still treats a WITH ... SELECT as a read (regression guard)" do
    gadget_class.delete_all
    gadget_class.create!(name: "readable", qty: 3)
    conn = ActiveRecord::Base.connection

    rows = conn.select_all(<<~SQL.squish).to_a
      WITH recent AS (SELECT id, name FROM gadgets)
      SELECT name FROM recent
    SQL

    expect(rows).to eq([{ "name" => "readable" }])
  end
end
