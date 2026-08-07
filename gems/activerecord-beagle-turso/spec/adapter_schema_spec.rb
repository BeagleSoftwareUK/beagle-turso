# frozen_string_literal: true

require "spec_helper"

# Task 5: schema/transaction/type completeness. Exercises the inherited
# SQLite3Adapter schema/transaction/type paths against the real beagle-turso
# driver (nothing mocked) -- each `expect` is a concrete assertion, not a
# restatement of the code under test.
RSpec.describe "beagle_turso adapter schema/transactions/types" do
  after(:each) { ActiveRecord::Base.remove_connection }

  def connect!
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
  end

  # -- 1. Transactions -----------------------------------------------------
  describe "transactions" do
    before(:each) do
      connect!
      ActiveRecord::Schema.define do
        create_table :accounts, force: true do |t|
          t.string :name
          t.integer :balance
        end
      end
    end

    let(:account_class) { Class.new(ActiveRecord::Base) { self.table_name = "accounts" } }

    it "commits a successful transaction" do
      account_class.transaction do
        account_class.create!(name: "alice", balance: 100)
      end
      expect(account_class.find_by(name: "alice")&.balance).to eq(100)
    end

    it "rolls back when ActiveRecord::Rollback is raised, leaving the row absent" do
      expect {
        account_class.transaction do
          account_class.create!(name: "bob", balance: 50)
          raise ActiveRecord::Rollback
        end
      }.not_to raise_error
      expect(account_class.find_by(name: "bob")).to be_nil
      expect(account_class.count).to eq(0)
    end

    it "rolls back when an arbitrary exception is raised, leaving the row absent" do
      expect {
        account_class.transaction do
          account_class.create!(name: "carol", balance: 10)
          raise "boom"
        end
      }.to raise_error("boom")
      expect(account_class.find_by(name: "carol")).to be_nil
    end

    it "rolls back only the inner savepoint on a nested (requires_new) transaction" do
      account_class.transaction do
        account_class.create!(name: "dave", balance: 1)
        account_class.transaction(requires_new: true) do
          account_class.create!(name: "erin", balance: 2)
          raise ActiveRecord::Rollback
        end
      end
      expect(account_class.find_by(name: "dave")).not_to be_nil
      expect(account_class.find_by(name: "erin")).to be_nil
      expect(account_class.count).to eq(1)
    end
  end

  # -- 2. DDL ----------------------------------------------------------------
  describe "DDL" do
    before(:each) do
      connect!
      ActiveRecord::Schema.define do
        create_table :widgets_ddl, force: true do |t|
          t.string :name
        end
      end
    end

    let(:conn) { ActiveRecord::Base.connection }

    it "add_column adds a column that is usable immediately" do
      conn.add_column :widgets_ddl, :qty, :integer, default: 0
      expect(conn.column_exists?(:widgets_ddl, :qty, :integer)).to be(true)

      klass = Class.new(ActiveRecord::Base) { self.table_name = "widgets_ddl" }
      row = klass.create!(name: "gizmo")
      expect(row.qty).to eq(0)
    end

    it "add_index creates a queryable index" do
      conn.add_column :widgets_ddl, :sku, :string
      conn.add_index :widgets_ddl, :sku, unique: true, name: "idx_widgets_ddl_sku"
      expect(conn.index_exists?(:widgets_ddl, :sku, name: "idx_widgets_ddl_sku")).to be(true)

      klass = Class.new(ActiveRecord::Base) { self.table_name = "widgets_ddl" }
      klass.create!(name: "gizmo", sku: "SKU-1")
      expect { klass.create!(name: "gadget", sku: "SKU-1") }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "remove_column drops the column and its data" do
      conn.add_column :widgets_ddl, :temp_flag, :boolean, default: false
      conn.remove_column :widgets_ddl, :temp_flag
      expect(conn.column_exists?(:widgets_ddl, :temp_flag)).to be(false)
    end

    it "change_column alters the column type in place" do
      conn.add_column :widgets_ddl, :code, :string
      klass = Class.new(ActiveRecord::Base) { self.table_name = "widgets_ddl" }
      klass.create!(name: "gizmo", code: "42")

      conn.change_column :widgets_ddl, :code, :integer
      klass.reset_column_information
      expect(klass.columns_hash["code"].sql_type).to eq("integer")
      expect(klass.first.code).to eq(42)
    end
  end

  # -- Fix round 1: the bare-PRAGMA-read bridge (defer_foreign_keys /
  # read_uncommitted) must NOT also swallow `PRAGMA foreign_key_check`, whose
  # empty result is the *correct* "no violations" answer, not a driver gap to
  # paper over. A generic `PRAGMA \w+` allowlist would synthesize a fake
  # non-empty row for it and make check_all_foreign_keys_valid! raise a
  # false-positive on perfectly clean data.
  describe "referential integrity after PRAGMA bridging" do
    before(:each) do
      connect!
      ActiveRecord::Schema.define do
        create_table :ri_parents, force: true do |t|
          t.string :name
        end
        create_table :ri_children, force: true do |t|
          t.references :ri_parent, foreign_key: true
          t.string :name
        end
      end
    end

    let(:parent_class) { Class.new(ActiveRecord::Base) { self.table_name = "ri_parents" } }
    let(:child_class)  { Class.new(ActiveRecord::Base) { self.table_name = "ri_children" } }

    it "check_all_foreign_keys_valid! does not raise on a clean FK graph" do
      parent = parent_class.create!(name: "p1")
      child_class.create!(ri_parent_id: parent.id, name: "c1")

      expect {
        ActiveRecord::Base.connection.check_all_foreign_keys_valid!
      }.not_to raise_error
    end

    it "PRAGMA foreign_key_check itself comes back blank on clean data (not a synthesized row)" do
      parent = parent_class.create!(name: "p1")
      child_class.create!(ri_parent_id: parent.id, name: "c1")

      result = ActiveRecord::Base.connection.execute("PRAGMA foreign_key_check")
      expect(result).to be_blank
    end

    it "FK enforcement is still ON after a disable_referential_integrity-based DDL op" do
      conn = ActiveRecord::Base.connection
      # remove_column/change_column route through alter_table ->
      # disable_referential_integrity, whose ensure-block restores
      # `PRAGMA foreign_keys = ON` via the same bridged pragma read this fix
      # round touches. Prove that restore still actually happens.
      conn.add_column :ri_children, :note, :string
      conn.remove_column :ri_children, :note

      expect(conn.query_value("PRAGMA foreign_keys")).to eq(1)
      expect {
        child_class.create!(ri_parent_id: 999_999, name: "orphan")
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  # -- 3. Types --------------------------------------------------------------
  describe "column types round-trip through a model" do
    before(:each) do
      connect!
      ActiveRecord::Schema.define do
        create_table :type_specimens, force: true do |t|
          t.string :a_string
          t.integer :an_integer
          t.float :a_float
          t.boolean :a_boolean
          t.datetime :a_datetime
          t.binary :a_binary
        end
      end
    end

    let(:specimen_class) { Class.new(ActiveRecord::Base) { self.table_name = "type_specimens" } }

    it "round-trips string, integer, float, boolean, datetime, and binary values" do
      time = Time.utc(2026, 8, 7, 12, 30, 0)
      binary = (+"\xFF\x00\xFE binary\x01").force_encoding(Encoding::ASCII_8BIT)

      created = specimen_class.create!(
        a_string: "hello",
        an_integer: 42,
        a_float: 3.5,
        a_boolean: true,
        a_datetime: time,
        a_binary: binary
      )

      reloaded = specimen_class.find(created.id)

      expect(reloaded.a_string).to eq("hello")
      expect(reloaded.a_string).to be_a(String)

      expect(reloaded.an_integer).to eq(42)
      expect(reloaded.an_integer).to be_a(Integer)

      expect(reloaded.a_float).to eq(3.5)
      expect(reloaded.a_float).to be_a(Float)

      expect(reloaded.a_boolean).to eq(true)
      expect([TrueClass, FalseClass]).to include(reloaded.a_boolean.class)

      expect(reloaded.a_datetime).to be_a(Time)
      expect(reloaded.a_datetime.utc.to_i).to eq(time.to_i)

      expect(reloaded.a_binary).to eq(binary)
      expect(reloaded.a_binary.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "round-trips false booleans distinctly from nil" do
      created = specimen_class.create!(a_boolean: false)
      reloaded = specimen_class.find(created.id)
      expect(reloaded.a_boolean).to eq(false)
      expect(reloaded.a_boolean).not_to be_nil
    end
  end

  # -- 4. pluck / update_all / delete_all / where -----------------------------
  describe "pluck / update_all / delete_all / where" do
    before(:each) do
      connect!
      ActiveRecord::Schema.define do
        create_table :inventory_items, force: true do |t|
          t.string :name
          t.integer :qty
        end
      end
      klass.create!(name: "a", qty: 1)
      klass.create!(name: "b", qty: 2)
      klass.create!(name: "c", qty: 3)
    end

    let(:klass) { Class.new(ActiveRecord::Base) { self.table_name = "inventory_items" } }

    it "pluck returns the correct column values" do
      expect(klass.order(:name).pluck(:name)).to eq(["a", "b", "c"])
      expect(klass.order(:name).pluck(:name, :qty)).to eq([["a", 1], ["b", 2], ["c", 3]])
    end

    it "where filters to the matching rows" do
      expect(klass.where(qty: 2).pluck(:name)).to eq(["b"])
      expect(klass.where("qty > ?", 1).count).to eq(2)
    end

    it "update_all updates matching rows and returns the affected count" do
      affected = klass.where("qty > ?", 1).update_all(qty: 0)
      expect(affected).to eq(2)
      expect(klass.where(qty: 0).count).to eq(2)
      expect(klass.find_by(name: "a").qty).to eq(1)
    end

    it "delete_all removes matching rows and returns the affected count" do
      affected = klass.where("qty > ?", 1).delete_all
      expect(affected).to eq(2)
      expect(klass.count).to eq(1)
      expect(klass.first.name).to eq("a")
    end
  end
end
