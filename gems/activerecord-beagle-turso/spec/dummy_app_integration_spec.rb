# frozen_string_literal: true

require "spec_helper"

# Task 7: a REAL Rails app boot, not a bare `establish_connection` call.
#
# Every other spec in this suite calls `ActiveRecord::Base.establish_connection`
# directly -- proving the adapter works, but not that it survives Rails' own
# boot sequence (Railtie initializer ordering, config/database.yml resolution,
# Zeitwerk autoloading). test/dummy is a hand-written but genuine
# `Rails::Application`: it boots via the same config/environment.rb ->
# `Rails.application.initialize!` path a real app's `bin/rails server`/
# `bin/rails console` uses, resolves `adapter: beagle_turso` from
# config/database.yml the way ActiveRecord::Railtie's
# "active_record.initialize_database" initializer does it (not a hand-passed
# hash), runs a real `ActiveRecord::Migration` file via `MigrationContext`
# (schema_migrations + ar_internal_metadata bookkeeping included -- neither
# of which any other spec in this suite exercises), and reads/writes through
# a `DummyWidget` model Zeitwerk autoloads from test/dummy/app/models --
# never `require`d by hand.
#
# See test/dummy/config/application.rb for exactly which frameworks this
# boots (only what active_record/railtie itself pulls in) and README.md's
# test-coverage section for how this fits alongside the rest of the suite.
RSpec.describe "dummy Rails app boot" do
  dummy_app_root = File.expand_path("../test/dummy", __dir__)

  before(:all) do
    ENV["RAILS_ENV"] = "test"
    require File.join(dummy_app_root, "config/environment")

    ActiveRecord::Migration.verbose = false
    migrations_paths = Rails.application.config.paths["db/migrate"].to_a
    ActiveRecord::MigrationContext.new(migrations_paths).migrate
  end

  after(:all) do
    ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected?
  end

  it "boots as a real Rails::Application, connected through the beagle_turso adapter" do
    expect(Rails.application).to be_a(Dummy::Application)
    expect(ActiveRecord::Base.connection.adapter_name).to eq("BeagleTurso")
  end

  it "ran the real migration file: table + schema_migrations + ar_internal_metadata exist" do
    conn = ActiveRecord::Base.connection
    expect(conn.table_exists?(:dummy_widgets)).to be(true)
    expect(conn.column_exists?(:dummy_widgets, :qty, :integer)).to be(true)

    expect(conn.select_values("SELECT version FROM schema_migrations")).to include("20260101000000")
    expect(conn.select_value("SELECT value FROM ar_internal_metadata WHERE key = 'environment'")).to eq("test")
  end

  it "performs CRUD through the Zeitwerk-autoloaded DummyWidget model" do
    # DummyWidget (test/dummy/app/models/dummy_widget.rb) is never `require`d
    # anywhere in this suite -- referencing the constant here is what makes
    # Zeitwerk autoload it, proving the model resolves through Rails' normal
    # app/models autoloading rather than a hand-built `Class.new(ActiveRecord::Base)`.
    widget = DummyWidget.create!(name: "gizmo", qty: 3)
    expect(widget.id).to be_a(Integer)

    found = DummyWidget.find(widget.id)
    expect([found.name, found.qty]).to eq(["gizmo", 3])

    found.update!(qty: 9)
    expect(DummyWidget.find(widget.id).qty).to eq(9)

    found.destroy
    expect(DummyWidget.where(id: widget.id)).to be_empty
  end
end
