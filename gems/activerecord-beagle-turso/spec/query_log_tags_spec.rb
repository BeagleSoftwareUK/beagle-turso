# frozen_string_literal: true

require "spec_helper"

# Rails appends a SQL comment to every statement when
# `config.active_record.query_log_tags_enabled = true` -- the app-generator
# default for development since Rails 7.0. Anything in this adapter that
# pattern-matches raw SQL has to survive that tag, and two things do: the bare
# pragma-read bridge, and the schema-introspection filter.
RSpec.describe "beagle_turso adapter with query log tags enabled" do
  around(:each) do |example|
    previous_transformers = ActiveRecord.query_transformers.dup
    previous_taggings = ActiveRecord::QueryLogs.taggings
    previous_tags = ActiveRecord::QueryLogs.tags

    ActiveRecord::QueryLogs.taggings = { application: "Dummy" }
    ActiveRecord::QueryLogs.tags = [:application]
    ActiveRecord.query_transformers << ActiveRecord::QueryLogs
    example.run
  ensure
    ActiveRecord.query_transformers = previous_transformers
    ActiveRecord::QueryLogs.taggings = previous_taggings
    ActiveRecord::QueryLogs.tags = previous_tags
    ActiveRecord::Base.remove_connection
  end

  def connect!
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Schema.verbose = false
  end

  it "tags statements, so the specs below are actually exercising the tagged path" do
    connect!
    seen = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      seen << payload[:sql]
    end
    ActiveRecord::Base.connection.execute("SELECT 1")
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(seen.last).to match(%r{/\*application[:=].*Dummy.*\*/})
  end

  # Regression: the bare-pragma bridge used to be `\z`-anchored, so a tagged
  # `PRAGMA defer_foreign_keys /*application='Dummy'*/` fell through to the
  # driver's empty result. query_value then returned nil, Rails interpolated it
  # into `PRAGMA defer_foreign_keys = `, and every alter_table-based schema
  # change died with "query failed: incomplete input".
  it "still reads defer_foreign_keys back as a value" do
    connect!
    expect(ActiveRecord::Base.connection.query_value("PRAGMA defer_foreign_keys")).to eq(0)
  end

  it "runs add_foreign_key, which goes through disable_referential_integrity" do
    connect!
    ActiveRecord::Schema.define do
      create_table :authors, force: true
      create_table :books, force: true do |t|
        t.integer :author_id, null: false
      end
    end

    expect {
      ActiveRecord::Base.connection.add_foreign_key :books, :authors
    }.not_to raise_error

    expect(ActiveRecord::Base.connection.foreign_keys("books").map(&:to_table)).to eq(["authors"])
  end

  it "loads a schema containing foreign keys and records the migration version" do
    connect!
    ActiveRecord::Schema.define(version: 20_260_809_000_001) do
      create_table :authors, force: true
      create_table :books, force: true do |t|
        t.integer :author_id, null: false
      end
      add_foreign_key :books, :authors
    end

    connection = ActiveRecord::Base.connection
    expect(connection.table_exists?("schema_migrations")).to be(true)
    expect(connection.table_exists?("ar_internal_metadata")).to be(true)
    expect(connection.pool.schema_migration.versions).to eq(["20260809000001"])
  end

  it "hides beagle_turso internal bookkeeping tables from introspection" do
    connect!
    ActiveRecord::Schema.define do
      create_table :widgets, force: true
    end
    connection = ActiveRecord::Base.connection

    internal = connection.select_values(
      "SELECT name FROM sqlite_master WHERE name LIKE '__turso_internal_%'"
    )

    expect(internal).not_to be_empty
    expect(connection.tables).to include("widgets")
    expect(connection.tables & internal).to be_empty
  end

  it "keeps internal tables out of a schema dump" do
    connect!
    ActiveRecord::Schema.define do
      create_table :widgets, force: true
    end

    dump = StringIO.new
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection.pool, dump)

    expect(dump.string).to include('create_table "widgets"')
    expect(dump.string).not_to include("__turso_internal_")
  end
end
