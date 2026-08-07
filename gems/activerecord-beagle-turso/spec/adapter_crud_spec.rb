# frozen_string_literal: true

require "spec_helper"

RSpec.describe "beagle_turso adapter CRUD" do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table :widgets, force: true do |t|
        t.string :name
        t.integer :qty
      end
    end
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
  end

  it "inserts and reads back through the model" do
    klass = Class.new(ActiveRecord::Base) { self.table_name = "widgets" }
    w = klass.create!(name: "gizmo", qty: 3)
    expect(w.id).to be_a(Integer)
    got = klass.find(w.id)
    expect([got.name, got.qty]).to eq(["gizmo", 3])
    expect(klass.where(qty: 3).count).to eq(1)
  end

  it "updates and deletes through the model" do
    klass = Class.new(ActiveRecord::Base) { self.table_name = "widgets" }
    w = klass.create!(name: "sprocket", qty: 10)
    w.update!(qty: 42)
    expect(klass.find(w.id).qty).to eq(42)
    w.destroy
    expect(klass.where(id: w.id).count).to eq(0)
  end
end
