require_relative "lib/beagle/turso/version"

Gem::Specification.new do |spec|
  spec.name = "beagle-turso"
  spec.version = Beagle::Turso::VERSION
  spec.authors = ["BeagleSoftwareUK"]
  spec.summary = "Ruby driver for Turso's new engine, backed by beagle_turso_core (Rust)."
  spec.description = <<~DESC
    A Ruby driver for Turso's database engine, backed by a native Rust
    extension (beagle_turso_core, via Magnus/rb-sys). Opens a local-only
    database (in-memory or on-disk) or one kept in sync with a remote Turso
    database via explicit push/pull. Writes are durable to the local file
    immediately as they happen; push is what propagates them to the remote
    on sync, not synchronously with every write.
  DESC
  spec.homepage = "https://github.com/BeagleSoftwareUK/beagle-turso"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "ext/**/*.{rb,rs,toml}", "README.md"]
  spec.extensions = ["ext/beagle_turso/extconf.rb"]
  spec.metadata["source_code_uri"] = "https://github.com/BeagleSoftwareUK/beagle-turso"
  spec.add_dependency "rb_sys", "~> 0.9"
end
