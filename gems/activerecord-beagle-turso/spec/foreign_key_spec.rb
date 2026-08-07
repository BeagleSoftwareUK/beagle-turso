# frozen_string_literal: true

require "spec_helper"

# FIX #1: stock SQLite3Adapter turns foreign keys ON per-connection via a
# DEFAULT_PRAGMA setter, which is a no-op on our Client. The adapter re-asserts
# `PRAGMA foreign_keys = ON` in configure_connection so referential integrity is
# actually enforced (not a silent regression).
RSpec.describe "beagle_turso adapter foreign key enforcement" do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :authors, force: true do |t|
        t.string :name
      end
      create_table :books, force: true do |t|
        t.references :author, foreign_key: true
        t.string :title
      end
    end
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  let(:author_class) { Class.new(ActiveRecord::Base) { self.table_name = "authors" } }
  let(:book_class)   { Class.new(ActiveRecord::Base) { self.table_name = "books" } }

  it "has foreign keys enabled on the connection" do
    expect(ActiveRecord::Base.connection.query_value("PRAGMA foreign_keys")).to eq(1)
  end

  it "raises when inserting a child row that references a non-existent parent" do
    expect {
      book_class.create!(author_id: 999_999, title: "orphan")
    }.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "does not raise when the referenced parent exists" do
    author = author_class.create!(name: "Ursula")
    expect {
      book_class.create!(author_id: author.id, title: "A Wizard of Earthsea")
    }.not_to raise_error
  end
end
