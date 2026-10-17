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

    {
      "access_token=SECRETA1" => "access_token=[redacted]",
      "turso_auth_token=SECRETA2" => "turso_auth_token=[redacted]",
      "jwt=SECRETA3" => "jwt=[redacted]",
      "api_key=SECRETA4" => "api_key=[redacted]",
      "apikey=SECRETA5" => "apikey=[redacted]",
      "x-api-key: SECRETA6" => "x-api-key: [redacted]",
      "authorization=SECRETA7" => "authorization=[redacted]",
      "Authorization: Basic SECRETA8" => "Authorization: Basic [redacted]",
      "bearer SECRETA9" => "bearer [redacted]",
      "q=1&token%3DSECRETB1" => "q=1&token%3D[redacted]",
      "authToken%3dSECRETB2 next" => "authToken%3d[redacted] next",
      %({"auth_token": "SECRETB3"}) => %({"auth_token": "[redacted]"}),
      "failed with eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJTRUNSRVRCNCJ9.SECRETB4sig_-x here" => "failed with [redacted] here"
    }.each do |input, expected|
      it "blanks #{input[0, 24].inspect}" do
        out = described_class.message(input)
        expect(out.include?("SECRET")).to be(false)
        expect(out).to eq(expected)
      end
    end

    it "reduces a bracketed IPv6 URL to scheme and host" do
      expect(described_class.message("dial http://[::1]:8080/?token=x failed")).to eq("dial http://[::1] failed")
    end

    it "stays linear on large adversarial input" do
      inputs = [
        "a." * 50_000, "a" * 100_000, "a://" * 25_000, "token" * 20_000, "x_" * 50_000,
        "eyJ" + ("a." * 50_000), "token=" * 16_000, "Bearer " * 14_000, "[:" * 50_000,
        "http://[" + (":" * 100_000), "#{"a-" * 50_000}token"
      ]
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      inputs.each { described_class.message(_1) }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t).to be < 0.5
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
