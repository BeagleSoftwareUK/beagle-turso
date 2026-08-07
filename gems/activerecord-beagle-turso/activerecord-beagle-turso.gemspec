# frozen_string_literal: true

require_relative "lib/activerecord/beagle_turso/version"

Gem::Specification.new do |spec|
  spec.name    = "activerecord-beagle-turso"
  spec.version = ActiveRecord::BeagleTurso::VERSION
  spec.authors = ["BeagleSoftwareUK"]

  spec.summary     = "ActiveRecord adapter for Turso, backed by the beagle-turso driver."
  spec.description = <<~DESC
    An ActiveRecord connection adapter for Turso's libsql engine. It subclasses
    the stock SQLite3Adapter and reroutes only the raw-execution seam onto the
    beagle-turso native driver, so schema migrations and model CRUD run against
    a local, in-memory, or synced remote Turso database while inheriting
    SQLite3Adapter's SQL generation, quoting, and schema introspection.
  DESC

  spec.homepage = "https://github.com/BeagleSoftwareUK/beagle-turso"
  spec.license  = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = "https://github.com/BeagleSoftwareUK/beagle-turso"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", "~> 8.1"
  spec.add_dependency "beagle-turso"
  # AR's SQLite3Adapter `require`s the sqlite3 gem at load time (and reads a few
  # ::SQLite3 constants during connect), even though execution goes to Turso.
  spec.add_dependency "sqlite3", ">= 2.1"

  spec.add_development_dependency "rspec", "~> 3.13"
end
