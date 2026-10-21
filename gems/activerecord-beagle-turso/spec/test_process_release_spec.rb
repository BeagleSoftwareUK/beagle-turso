# frozen_string_literal: true

require "spec_helper"
require "rake"
require "rbconfig"
require "tmpdir"

# Regression: `bin/rails db:test:prepare test` failed with
#
#   open failed: Locking error: Failed locking file '.../storage/test.sqlite3'.
#   File is locked by another process
#
# The rake `test` task runs the tests in a CHILD process (Rails'
# run_from_rake; rspec-rails' `spec` task does the same), while the rake
# process still held the connection db:test:prepare had opened -- and a local
# Turso database file is locked to the process that opened it. These specs use
# a real file database and a real child process, because the lock only exists
# between processes.
RSpec.describe ActiveRecord::ConnectionAdapters::BeagleTurso::TestProcessRelease do
  # A second connection, on another adapter, that must never be touched.
  other_adapter_model = Class.new(ActiveRecord::Base) do
    self.abstract_class = true
    def self.name = "OtherAdapterRecord"
  end

  around do |example|
    Dir.mktmpdir("beagle-turso-release") do |dir|
      @dir = dir
      @path = File.join(dir, "test.sqlite3")
      previous_rake = Rake.application
      Rake.application = Rake::Application.new
      described_class.install!
      example.run
    ensure
      Rake.application = previous_rake
      other_adapter_model.remove_connection if other_adapter_model.connected?
      ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected?
    end
  end

  # What db:test:prepare does: open the file database and use it.
  def connect_to_file_database
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: @path)
    ActiveRecord::Base.connection.execute("CREATE TABLE IF NOT EXISTS t (x INTEGER)")
  end

  # What the `rails test` child does first: open the same database file.
  def child_process_can_open?
    script = 'require "beagle/turso"; Beagle::Turso::Database.open_local(ARGV[0]).close'
    system(RbConfig.ruby, "-rbundler/setup", "-e", script, @path, err: File::NULL)
  end

  def connected?(model = ActiveRecord::Base)
    model.connection_pool.connections.any?(&:connected?)
  end

  def define_db_test_prepare
    Rake::Task.define_task("db:test:prepare") do
      connect_to_file_database
      ActiveRecord::Base.connection.execute("SELECT 1")
    end
  end

  it "is needed: while the rake process holds a connection, a second process cannot open the file" do
    connect_to_file_database

    expect(child_process_can_open?).to be(false)
  end

  it "releases after db:test:prepare, so `test`'s child process can open the file" do
    define_db_test_prepare
    child_opened = nil
    Rake::Task.define_task("test" => "db:test:prepare") { child_opened = child_process_can_open? }

    Rake::Task["test"].invoke

    expect(child_opened).to be(true)
  end

  it "does the same for any task after it that starts a process, such as rspec-rails' `spec`" do
    define_db_test_prepare
    child_opened = nil
    Rake::Task.define_task("spec" => "db:test:prepare") { child_opened = child_process_can_open? }

    Rake::Task["spec"].invoke

    expect(child_opened).to be(true)
  end

  it "keeps the connection until the outermost db task has finished" do
    connected_after_inner_task = nil
    Rake::Task.define_task("db:test:load_schema") { connect_to_file_database }
    Rake::Task.define_task("db:test:prepare") do
      Rake::Task["db:test:load_schema"].invoke
      connected_after_inner_task = connected?
    end

    Rake::Task["db:test:prepare"].invoke

    expect(connected_after_inner_task).to be(true)
    expect(connected?).to be(false)
  end

  it "leaves connections alone after tasks outside db:" do
    connect_to_file_database
    Rake::Task.define_task("test") {}

    Rake::Task["test"].invoke

    expect(connected?).to be(true)
  end

  it "leaves in-memory databases alone (closing one would destroy it)" do
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
    ActiveRecord::Base.connection.execute("CREATE TABLE kept (x INTEGER)")
    Rake::Task.define_task("db:test:prepare") {}

    Rake::Task["db:test:prepare"].invoke

    expect(ActiveRecord::Base.connection.table_exists?(:kept)).to be(true)
  end

  it "leaves other adapters' connections alone" do
    other_adapter_model.establish_connection(adapter: "sqlite3", database: File.join(@dir, "other.sqlite3"))
    other_adapter_model.connection.execute("SELECT 1")
    define_db_test_prepare

    Rake::Task["db:test:prepare"].invoke

    expect(connected?).to be(false)
    expect(connected?(other_adapter_model)).to be(true)
  end

  it "reconnects on the next use after a release" do
    define_db_test_prepare
    Rake::Task["db:test:prepare"].invoke

    expect(connected?).to be(false)
    expect(ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM t")).to eq(0)
  end
end
