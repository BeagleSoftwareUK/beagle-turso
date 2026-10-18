require_relative "lib/sequel/beagle_turso/version"

Gem::Specification.new do |spec|
  spec.name = "sequel-beagle-turso"
  spec.version = Sequel::BeagleTurso::VERSION
  spec.authors = ["BeagleSoftwareUK"]
  spec.summary = "Sequel adapter for Turso's local-first engine, backed by the beagle-turso driver."
  spec.description = <<~DESC
    A Sequel adapter (URL scheme beagle-turso://) that runs Sequel -- and ROM /
    Hanami repositories on top of it -- on a beagle-turso database: a local
    SQLite-compatible replica that syncs to Turso Cloud. SQL generation, schema
    parsing and transactions come from Sequel's shared SQLite support.
  DESC
  spec.homepage = "https://github.com/BeagleSoftwareUK/beagle-turso"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.metadata["source_code_uri"] = "https://github.com/BeagleSoftwareUK/beagle-turso"
  spec.add_dependency "sequel", "~> 5.100"
  spec.add_dependency "beagle-turso", "~> 0.3"
end
