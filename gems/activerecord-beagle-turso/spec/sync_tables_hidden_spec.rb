# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "stringio"

# The sync engine's own tables (turso_cdc, turso_cdc_version,
# turso_sync_last_change_id) must never show up as application tables: Rails
# tooling that walks `tables` would dump or truncate the change log.
RSpec.describe "beagle_turso adapter: sync engine tables are hidden" do
  after(:each) { ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected? }

  HIDDEN = %w[turso_cdc turso_cdc_version turso_sync_last_change_id].freeze

  describe "against a local-only connection" do
    before(:each) do
      ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
      conn = ActiveRecord::Base.connection
      (HIDDEN + %w[turso_sync_log widgets]).each do |t|
        conn.execute("CREATE TABLE #{t} (id INTEGER PRIMARY KEY, v TEXT)")
      end
    end

    it "excludes the three sync tables from tables/data_sources but keeps look-alikes" do
      conn = ActiveRecord::Base.connection
      expect(conn.tables & HIDDEN).to eq([])
      expect(conn.data_sources & HIDDEN).to eq([])
      expect(conn.tables).to include("turso_sync_log", "widgets")
    end

    it "reports the sync tables as non-existent data sources" do
      conn = ActiveRecord::Base.connection
      HIDDEN.each do |t|
        expect(conn.data_source_exists?(t)).to be(false)
        expect(conn.table_exists?(t)).to be(false)
      end
      expect(conn.data_source_exists?("turso_sync_log")).to be(true)
    end

    it "keeps them out of the schema dump" do
      io = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, io)
      expect(io.string).not_to include("turso_cdc")
      expect(io.string).not_to include("turso_sync_last_change_id")
      expect(io.string).to include('create_table "turso_sync_log"')
    end
  end

  describe "against a synced connection" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }

    before(:each) do
      skip "no TURSO creds (TURSO_DATABASE_URL/TURSO_AUTH_TOKEN unset)" if url.to_s.empty? || token.to_s.empty?
    end

    it "hides the engine's tables on a real synced replica" do
      marker = "sth_#{Process.pid}_#{SecureRandom.hex(4)}"
      path = "/tmp/bt_sync_hidden_#{marker}.db"
      table = "sync_hidden_#{SecureRandom.hex(4)}"
      begin
        ActiveRecord::Base.establish_connection(
          adapter: "beagle_turso", database: path, remote_url: url, auth_token: token
        )
        ActiveRecord::Schema.verbose = false
        conn = ActiveRecord::Base.connection
        conn.create_table(table) { |t| t.string :name }
        Beagle::Turso::SyncManager.push!(conn)

        expect(conn.tables).to include(table)
        expect(conn.tables & HIDDEN).to eq([])
        expect(conn.data_sources & HIDDEN).to eq([])
      ensure
        begin
          if ActiveRecord::Base.connected?
            conn = ActiveRecord::Base.connection
            conn.drop_table(table, if_exists: true)
            Beagle::Turso::SyncManager.push!(conn)
          end
        ensure
          ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected?
          Dir.glob("#{path}*").each { |f| File.delete(f) }
        end
      end
    end
  end
end
