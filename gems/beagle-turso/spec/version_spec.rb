require "beagle/turso"

RSpec.describe Beagle::Turso do
  it "has a version" do
    expect(Beagle::Turso::VERSION).to be_a(String)
  end

  it "loaded the native extension" do
    expect(defined?(Beagle::Turso::Database)).to eq("constant")
  end
end
