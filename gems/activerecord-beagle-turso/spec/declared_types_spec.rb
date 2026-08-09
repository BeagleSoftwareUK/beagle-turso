# frozen_string_literal: true

require "spec_helper"

# turso's `PRAGMA table_info` reports a column's declared type without its
# parenthesised argument -- `decimal(10,2)` comes back as `decimal` -- so
# Rails' precision/scale/limit extraction silently yields nil for all three.
# The adapter recovers the full type from the CREATE TABLE in sqlite_master.
RSpec.describe "beagle_turso declared column types" do
  after(:each) { ActiveRecord::Base.remove_connection }

  def connect!
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
  end

  def column(table, name)
    ActiveRecord::Base.connection.columns(table).find { |c| c.name == name }
  end

  it "recovers precision and scale on decimals" do
    connect!
    ActiveRecord::Schema.define do
      create_table :products, force: true do |t|
        t.decimal :price, precision: 10, scale: 2
      end
    end

    price = column("products", "price")
    expect(price.precision).to eq(10)
    expect(price.scale).to eq(2)
  end

  it "recovers precision on datetimes" do
    connect!
    ActiveRecord::Schema.define do
      create_table :events, force: true do |t|
        t.datetime :occurred_at
      end
    end

    expect(column("events", "occurred_at").precision).to eq(6)
  end

  it "recovers limit on strings" do
    connect!
    ActiveRecord::Schema.define do
      create_table :people, force: true do |t|
        t.string :name, limit: 50
      end
    end

    expect(column("people", "name").limit).to eq(50)
  end

  it "leaves argument-less types alone" do
    connect!
    ActiveRecord::Schema.define do
      create_table :notes, force: true do |t|
        t.text :body
        t.integer :rank
      end
    end

    expect(column("notes", "body").sql_type).to eq("text")
    expect(column("notes", "rank").sql_type).to eq("integer")
    expect(column("notes", "body").limit).to be_nil
  end

  # The point of the whole exercise: a schema dump has to round-trip, or the
  # dumped file quietly redefines the database with weaker column types.
  it "round-trips a schema dump without losing column arguments" do
    connect!
    ActiveRecord::Schema.define(version: 1) do
      create_table :products, force: true do |t|
        t.decimal :price, precision: 10, scale: 2
        t.string :sku, limit: 20
        t.datetime :listed_at
      end
    end

    dump = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection.pool, dump)

    expect(dump.string).to include('t.decimal "price", precision: 10, scale: 2')
    expect(dump.string).to include('t.string "sku", limit: 20')
    expect(dump.string).not_to include("precision: nil")

    # Dumping twice must be stable -- the second dump is what drifts in a repo.
    second = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection.pool, second)
    expect(second.string).to eq(dump.string)
  end
end
