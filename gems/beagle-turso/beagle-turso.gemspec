require_relative "lib/beagle/turso/version"

Gem::Specification.new do |spec|
  spec.name = "beagle-turso"
  spec.version = Beagle::Turso::VERSION
  spec.authors = ["BeagleSoftwareUK"]
  spec.summary = "Ruby driver for Turso's new engine, backed by beagle_turso_core (Rust)."
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "ext/**/*.{rb,rs,toml}", "README.md"]
  spec.extensions = ["ext/beagle_turso/extconf.rb"]
  spec.add_dependency "rb_sys", "~> 0.9"
end
