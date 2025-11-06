ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "devise"
require "ostruct"        # if you use OpenStruct in tests
require "minitest/mock"  # if you use Minitest::Mock

class ActiveSupport::TestCase
  parallelize(workers: :number_of_processors)
  fixtures :all
  # Geocoder stub (keeps tests offline)
  require "geocoder"
  Geocoder.configure(lookup: :test)
  Geocoder::Lookup::Test.set_default_stub(
    [{ "latitude" => -33.96, "longitude" => 18.48, "address" => "Test Address" }]
  )

  # Configure default URL options for mailers in tests
  Rails.application.routes.default_url_options[:host] = 'test.host'
end

# Controller tests (ActionController::TestCase)
class ActionController::TestCase
  include Devise::Test::ControllerHelpers
end

# Request/Integration tests (ActionDispatch::IntegrationTest)
class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end

# (Optional) System tests
# class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
#   include Devise::Test::IntegrationHelpers
# end
