# Sequel loads an adapter by requiring "sequel/adapters/<url scheme>". URI
# schemes cannot contain "_", so the URL form is beagle-turso:// and this file
# exists only so that lookup finds the adapter.
require_relative "beagle_turso"
