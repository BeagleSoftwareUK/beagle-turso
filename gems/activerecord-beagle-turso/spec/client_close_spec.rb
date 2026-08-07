# frozen_string_literal: true

require "spec_helper"

# Regression: the adapter's Client#close was a literal no-op and closed? always
# returned false, so ActiveRecord's disconnect/reconnect churn leaked the
# beagle-turso session (a server-side sync session, for a synced database) until
# the remote reported "database is busy". Client#close now releases the handle
# and is idempotent. Exercised here against a local in-memory database, so it
# needs no TURSO credentials and always runs.
RSpec.describe ActiveRecord::ConnectionAdapters::BeagleTursoAdapter::Client do
  it "closes idempotently and reports closed?" do
    database = Beagle::Turso::Database.open_local(":memory:")
    client = described_class.new(database)

    expect(client.closed?).to be(false)

    client.close
    expect(client.closed?).to be(true)

    # Idempotent: a second close is a no-op, does not re-close, does not raise.
    expect { client.close }.not_to raise_error
    expect(client.closed?).to be(true)
  end
end
