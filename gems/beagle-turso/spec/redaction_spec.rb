require "beagle/turso"

RSpec.describe Beagle::Turso::Redaction do
  describe ".message" do
    it "reduces URLs to scheme and host" do
      text = "push failed: libsql://user:pw@db-acme.turso.io:443/v1/sync?authToken=SECRET123 refused"
      out = described_class.message(text)
      expect(out).to eq("push failed: libsql://db-acme.turso.io refused")
    end

    it "blanks token, password and secret parameters" do
      out = described_class.message(%(auth_token=SECRET1 authToken: "SECRET2" password=SECRET3 secret='SECRET4'))
      expect(out).not_to match(/SECRET\d/)
      expect(out).to include("auth_token=[redacted]")
    end

    it "blanks bearer credentials" do
      expect(described_class.message("Authorization: Bearer eyJabc.def")).to eq("Authorization: Bearer [redacted]")
    end

    it "leaves ordinary text alone and accepts nil" do
      expect(described_class.message("database is busy: locked")).to eq("database is busy: locked")
      expect(described_class.message(nil)).to eq("")
    end
  end

  describe ".host" do
    it "returns only the host" do
      expect(described_class.host("libsql://db-acme.turso.io/x?authToken=S")).to eq("db-acme.turso.io")
      expect(described_class.host("https://u:p@h.example:8080/p")).to eq("h.example")
    end

    it "returns nil for unparseable input" do
      expect(described_class.host("not a url at all ::")).to be_nil
      expect(described_class.host(nil)).to be_nil
    end
  end
end
