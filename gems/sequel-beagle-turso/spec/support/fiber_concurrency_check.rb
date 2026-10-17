require "bundler/setup"
require "sequel"
Sequel.extension :fiber_concurrency
require "sequel/adapters/beagle_turso"
require "async"

db = Sequel.connect(adapter: :beagle_turso, database: ARGV.fetch(0), max_connections: 4)
db.create_table(:f) { Integer :n }
Sync do |task|
  8.times.map { |k| task.async { 5.times { |i| db.transaction { db[:f].insert(n: k * 10 + i) } } } }.each(&:wait)
end
puts "rows=#{db[:f].count}"
db.close_replica
