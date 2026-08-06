require "beagle/turso"

RSpec.describe "no credential leakage" do
  it "keeps the auth token out of inspect and errors" do
    token = "SECRET-eyJshh"
    db = Beagle::Turso::Database.open(local_path: ":memory:", remote_url: nil, auth_token: nil)
    expect(db.inspect).not_to include(token)

    err = (Beagle::Turso::Database.open(local_path: "/x.db", remote_url: "not-a-scheme://x", auth_token: token) rescue $!)
    expect(err).to be_a(StandardError)
    expect(err.message).not_to include(token)
    expect(err.inspect).not_to include(token)
  end
end
