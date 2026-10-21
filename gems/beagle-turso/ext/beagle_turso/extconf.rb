require "etc"
require "mkmf"
require "rb_sys/mkmf"

create_rust_makefile("beagle_turso/beagle_turso") do |r|
  # Building ON macOS: strip at link time instead of after it.
  #
  # Since Rust 1.77 a release build strips debuginfo after linking, and on a
  # macOS host rustc (1.97) does that with its bundled rust-objcopy (LLVM
  # objcopy), which rewrites the Mach-O symbol string table at a 4-byte offset.
  # macOS 27's dyld requires 8 and refuses the bundle:
  #
  #   dlopen(.../beagle_turso.bundle): ... (mis-aligned LINKEDIT string pool)
  #
  # So turn rustc's strip off and have Apple's linker leave out the debug
  # entries (-S, which include build paths) and local symbols (-x) as it
  # links; the linker keeps the table aligned. A CARGO_PROFILE_RELEASE_STRIP
  # set in the environment still wins. This only affects the release profile.
  #
  # Keyed on the machine actually building (Etc.uname), not RbConfig's target:
  # released darwin gems are cross-compiled on Linux, are stripped differently
  # and load fine, so that path is deliberately left unchanged.
  if Etc.uname[:sysname] == "Darwin"
    r.env = { "CARGO_PROFILE_RELEASE_STRIP" => ENV.fetch("CARGO_PROFILE_RELEASE_STRIP", "false") }
    r.extra_rustflags = ["-Clink-arg=-Wl,-S", "-Clink-arg=-Wl,-x"]
  end
end
