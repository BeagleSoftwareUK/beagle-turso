# frozen_string_literal: true

require "spec_helper"
require "securerandom"

RSpec.describe Beagle::Turso::SyncManager do
  after(:each) { ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected? }

  # Local-only handling: BeagleTursoAdapter opens `Database.open_local` (no
  # remote_url:/auth_token:), whose #push/#pull raise. SyncManager reraises
  # that as a documented, distinctly-typed error rather than a bare
  # RuntimeError -- and does not require real Turso creds to exercise.
  describe "against a local-only connection" do
    before(:each) do
      ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    end

    it "push! raises NotSyncedError instead of the driver's bare RuntimeError" do
      expect { described_class.push!(ActiveRecord::Base.connection) }
        .to raise_error(described_class::NotSyncedError, /local-only/)
    end

    it "pull! raises NotSyncedError instead of the driver's bare RuntimeError" do
      expect { described_class.pull!(ActiveRecord::Base.connection) }
        .to raise_error(described_class::NotSyncedError, /local-only/)
    end

    it "sync! raises on its push! step before ever attempting to pull" do
      expect { described_class.sync!(ActiveRecord::Base.connection) }
        .to raise_error(described_class::NotSyncedError, /local-only/)
    end
  end

  # Genuine round trip against real Turso creds. SKIPs cleanly without them.
  describe "against synced connections" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }

    before(:each) do
      skip "no TURSO creds (TURSO_DATABASE_URL/TURSO_AUTH_TOKEN unset)" if url.to_s.empty? || token.to_s.empty?
    end

    it "push!-ed writes from one replica are pull!-able from a second, fresh replica" do
      marker = "sm-#{Process.pid}-#{SecureRandom.hex(4)}"
      path_a = "/tmp/bt_sync_manager_a_#{marker}.db"
      path_b = "/tmp/bt_sync_manager_b_#{marker}.db"

      begin
        # Replica A: migrate, insert, push.
        ActiveRecord::Base.establish_connection(
          adapter: "beagle_turso", database: path_a, remote_url: url, auth_token: token
        )
        ActiveRecord::Schema.verbose = false
        ActiveRecord::Schema.define do
          create_table :sync_manager_markers, force: true do |t|
            t.string :name
          end
        end
        klass_a = Class.new(ActiveRecord::Base) { self.table_name = "sync_manager_markers" }
        klass_a.create!(name: marker)

        described_class.push!(ActiveRecord::Base.connection)
        ActiveRecord::Base.remove_connection

        # Replica B: a FRESH local path, with bootstrap_if_empty disabled so
        # the only thing that can bring the schema+row down is the explicit
        # pull! call below (not an implicit bootstrap-on-open) -- proving
        # pull! itself does the work, not just a fresh Database.open.
        ActiveRecord::Base.establish_connection(
          adapter: "beagle_turso", database: path_b, remote_url: url, auth_token: token,
          bootstrap_if_empty: false
        )
        described_class.pull!(ActiveRecord::Base.connection)

        klass_b = Class.new(ActiveRecord::Base) { self.table_name = "sync_manager_markers" }
        expect(klass_b.where(name: marker).count).to eq(1)
      ensure
        File.delete(path_a) if File.exist?(path_a)
        File.delete(path_b) if File.exist?(path_b)
      end
    end
  end
end
