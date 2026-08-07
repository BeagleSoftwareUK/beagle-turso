# frozen_string_literal: true

require "logger"
require "rails"
# ActiveRecord::Railtie's own top-of-file comment explains why it hard-requires
# action_controller/railtie (and, transitively, action_view/railtie) --
# "action_controller must always be present with Rails" for historical
# middleware-configuration reasons. This dummy app does not use either
# framework for anything; they're loaded because ActiveRecord::Railtie
# requires them, not because this app needs them.
require "active_record/railtie"
require "activerecord-beagle-turso"

module Dummy
  # A hand-written (not `rails new`-scaffolded) Rails::Application -- the
  # smallest one that will boot on the `active_record/railtie` require chain
  # above. It exists solely so spec/dummy_app_integration_spec.rb can prove
  # BeagleTursoAdapter survives a real `Rails.application.initialize!` boot
  # (Railtie initializer ordering, config/database.yml resolution via
  # Rails::Application::Configuration#database_configuration, Zeitwerk
  # autoloading of app/models) rather than only the bare
  # `ActiveRecord::Base.establish_connection` calls the rest of this gem's
  # specs use. See README.md's test-coverage section for what this does and
  # does not add on top of those specs.
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults 8.1

    # No config/environments/*.rb here -- this app only ever runs as `test`
    # (see spec/dummy_app_integration_spec.rb, which sets RAILS_ENV=test
    # before requiring config/environment). Set directly what a generated
    # test.rb would otherwise set.
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = "dummy-app-boot-integration-test-only"
  end
end
