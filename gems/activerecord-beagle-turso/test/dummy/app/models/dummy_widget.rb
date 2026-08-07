# frozen_string_literal: true

# Zeitwerk-autoloaded (never `require`d by hand) -- proves the beagle_turso
# connection works when reached through Rails' normal app/models autoloading,
# not just a `Class.new(ActiveRecord::Base)` built inline in a spec.
class DummyWidget < ActiveRecord::Base
end
