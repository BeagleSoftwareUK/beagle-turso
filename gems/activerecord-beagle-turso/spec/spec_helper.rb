# frozen_string_literal: true

require "active_record"
require "activerecord-beagle-turso"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
end
