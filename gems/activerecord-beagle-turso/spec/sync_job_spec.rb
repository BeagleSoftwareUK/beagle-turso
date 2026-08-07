# frozen_string_literal: true

require "spec_helper"

# Unit-level only: SyncJob is a thin delegator, so this stubs SyncManager
# rather than exercising a real Solid Queue run or real Turso creds (that
# round trip is covered by spec/sync_manager_spec.rb).
RSpec.describe ActiveRecord::ConnectionAdapters::BeagleTurso::SyncJob do
  it "perform delegates to Beagle::Turso::SyncManager.sync!" do
    expect(Beagle::Turso::SyncManager).to receive(:sync!).once
    described_class.new.perform
  end

  it "does not swallow a sync failure -- it propagates" do
    allow(Beagle::Turso::SyncManager).to receive(:sync!).and_raise(Beagle::Turso::SyncManager::NotSyncedError, "boom")
    expect { described_class.new.perform }.to raise_error(Beagle::Turso::SyncManager::NotSyncedError, "boom")
  end

  it "is an ActiveJob when ActiveJob is loaded, otherwise a plain class with the same #perform" do
    if defined?(ActiveJob::Base)
      expect(described_class.ancestors).to include(ActiveJob::Base)
    else
      expect(described_class.instance_method(:perform).owner).to eq(described_class)
    end
  end
end
