# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "securerandom"
require "open3"
require "fileutils"
require "beagle/turso"

# Real `rake db:prepare` against a real Turso database: a copy-table migration
# (change_column_null) on a table with rows must exit 0 -- the post-migration
# push hits sync-engine bug A once and the guard's retry absorbs it -- and a
# fresh replica must then see the new schema and every row.
#
# Skipped without TURSO_DATABASE_URL / TURSO_AUTH_TOKEN. Creates uniquely named
# tables on the remote and drops them afterwards.
RSpec.describe "db:prepare on a synced replica (credentialed end to end)" do
  url   = ENV["TURSO_DATABASE_URL"].to_s
  token = ENV["TURSO_AUTH_TOKEN"].to_s

  before(:all) do
    skip "set TURSO_DATABASE_URL and TURSO_AUTH_TOKEN to run" if url.empty? || token.empty?
  end

  let(:tag)  { "e2e#{SecureRandom.hex(4)}" }
  let(:dir)  { Dir.mktmpdir("ar-e2e-app") }
  let(:gem_root) { File.expand_path("..", __dir__) }

  after(:each) do
    FileUtils.rm_rf(dir)
    cleanup_remote
  end

  def write(path, body)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  def rake(task)
    env = { "REV_DB" => File.join(dir, "replica.db"), "BUNDLE_GEMFILE" => File.join(gem_root, "Gemfile"),
            "RAILS_ENV" => "development" }
    Open3.capture3(env, "bundle", "exec", "rake", task, chdir: dir)
  end

  def with_fresh_replica
    Dir.mktmpdir("ar-e2e-chk") do |d|
      db = Beagle::Turso::Database.open(local_path: File.join(d, "r.db"), remote_url: ENV["TURSO_DATABASE_URL"],
        auth_token: ENV["TURSO_AUTH_TOKEN"])
      yield db, db.connect
    ensure
      db&.close
    end
  end

  def cleanup_remote
    with_fresh_replica do |db, c|
      names = c.query("SELECT name FROM sqlite_schema WHERE type='table' AND (name LIKE '%#{tag}%')", []).flatten
      names.each { |n| c.execute(%(DROP TABLE "#{n}"), []) }
      db.push unless names.empty?
    end
  rescue StandardError
    nil
  end

  it "exits 0 and leaves the remote with the new schema and all rows" do
    write("Rakefile", "require_relative 'config/application'\nRails.application.load_tasks\n")
    write("config/application.rb", <<~RUBY)
      require "logger"
      require "rails"
      require "active_record/railtie"
      require "activerecord-beagle-turso"
      module E2eApp
        class Application < Rails::Application
          config.root = File.expand_path("..", __dir__)
          config.load_defaults 8.1
          config.eager_load = false
          config.secret_key_base = "x"
          config.logger = Logger.new(IO::NULL)
          config.active_record.schema_migrations_table_name = "#{tag}_schema_migrations"
          config.active_record.internal_metadata_table_name = "#{tag}_internal_metadata"
          config.active_record.dump_schema_after_migration = false
        end
      end
      Rails.application.initialize!
    RUBY
    write("config/database.yml", <<~YML)
      development:
        adapter: beagle_turso
        database: <%= ENV.fetch("REV_DB") %>
        remote_url: <%= ENV.fetch("TURSO_DATABASE_URL") %>
        auth_token: <%= ENV.fetch("TURSO_AUTH_TOKEN") %>
    YML
    write("db/migrate/20261018000001_create_#{tag}.rb", <<~RUBY)
      class Create#{tag.capitalize} < ActiveRecord::Migration[8.1]
        def change
          create_table :#{tag}_w do |t| t.string :name end
          reversible { |d| d.up { 3.times { |i| execute "INSERT INTO #{tag}_w (name) VALUES ('w\#{i}')" } } }
        end
      end
    RUBY

    _out, err, status = rake("db:prepare")
    expect(status.exitstatus).to eq(0), err

    write("db/migrate/20261018000002_null_#{tag}.rb", <<~RUBY)
      class Null#{tag.capitalize} < ActiveRecord::Migration[8.1]
        def change
          change_column_null :#{tag}_w, :name, false, "d"
        end
      end
    RUBY
    _out, err, status = rake("db:prepare")
    expect(status.exitstatus).to eq(0), err

    with_fresh_replica do |_db, c|
      expect(c.query("SELECT sql FROM sqlite_schema WHERE name = '#{tag}_w'", []).flatten.first).to match(/NOT NULL/i)
      expect(c.query("SELECT name FROM #{tag}_w ORDER BY name", []).flatten).to eq(%w[w0 w1 w2])
    end

    # Nothing pending: db:prepare again must exit 0 without needing to push.
    _out, err, status = rake("db:prepare")
    expect(status.exitstatus).to eq(0), err
  end
end
