require "sequel"
require "sequel/adapters/beagle_turso"

module SpecPaths
  def tmp_db
    path = "/tmp/sbt_#{Process.pid}_#{rand(1_000_000)}.db"
    (@tmp_dbs ||= []) << path
    path
  end
end

RSpec.configure do |c|
  c.include SpecPaths
  c.after { (@tmp_dbs || []).each { |p| Dir.glob("#{p}*").each { |f| File.delete(f) rescue nil } } }
end
