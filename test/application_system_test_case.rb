require "test_helper"
require "capybara/email"
require "support/waiting"
require "minitest/retry"

Minitest::Retry.use!(retry_count: 3, verbose: true, exceptions_to_retry: [Net::ReadTimeout])

OmniAuth.config.test_mode = true

Capybara.default_max_wait_time = ENV.fetch("CAPYBARA_DEFAULT_MAX_WAIT_TIME", ENV["MAGIC_TEST"].present? ? 5 : 15)
Capybara.javascript_driver = ENV["MAGIC_TEST"].present? ? :selenium_chrome : :selenium_chrome_headless
Capybara.default_driver = ENV["MAGIC_TEST"].present? ? :selenium_chrome : :selenium_chrome_headless

Capybara.register_server :puma do |app, port, host|
  require "rack/handler/puma"
  # current we need at least three threads for the webhooks tests to pass.
  Rack::Handler::Puma.run(app, Host: host, Port: port, Threads: "5:5", config_files: ["-"])
end

Capybara.server = :puma
Capybara.server_port = 3001
Capybara.app_host = "http://localhost:3001"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :chrome, screen_size: [1400, 1400]
  include ActiveJob::TestHelper
  include MagicTest::Support
  include Capybara::DSL
  include Capybara::Email::DSL
  include Capybara::Minitest::Assertions
  # include Capybara::Screenshot::MiniTestPlugin
  include Devise::Test::IntegrationHelpers
  include Warden::Test::Helpers
  include Waiting

  def example_password
    @example_password ||= SecureRandom.hex
  end

  def another_example_password
    @another_example_password ||= SecureRandom.hex
  end

  def setup
    ENV["BASE_URL"] = "http://localhost:3001"
    Capybara.use_default_driver
    Capybara.reset_sessions!
  end

  def teardown
    Capybara.use_default_driver
    Capybara.reset_sessions!
  end

  @@test_devices = {
    # iphone_8: {resolution: [750, 1334], mobile: true, high_dpi: true},
    macbook_pro_15_inch: {resolution: [2880, 1800], mobile: false, high_dpi: true},
    # hd_monitor: {resolution: [1920, 1080], mobile: false, high_dpi: false},
  }

  if ENV["TEST_DEVICE"]
    key = ENV["TEST_DEVICE"].to_sym
    if @@test_devices.key?(key)
      puts "Running tests with the `#{ENV["TEST_DEVICE"]}` device profile specifically.".green
      @@test_devices = {key => @@test_devices[key]}
    else
      puts "⚠️ `#{ENV["TEST_DEVICE"]}` isn't a valid device profile in `test/test_helper.rb`, so we'll just run *all* device profiles.".yellow
    end
  end

  def resize_for(display_details)
    page.driver.browser.manage.window.resize_to(*calculate_resolution(display_details))
  end

  def within_team_menu_for(display_details)
    within_primary_menu_for(display_details) do
      yield
    end
  end

  def open_mobile_menu
    find(".mobile-menu-trigger").click
  end

  # sign out.
  def sign_out_for(display_details)
    if display_details[:mobile]
      open_mobile_menu
      click_on "Logout"
    else
      within ".menu" do
        # first(".logged-user-i").hover
        click_on "Logout"
      end
    end

    # make sure we're actually signed out.
    # (this will vary depending on where you send people when they sign out.)
    assert page.has_content? "Sign In"
  end

  def sign_in_from_homepage_for(display_details)
    # TODO the tailwind port of bullet train doesn't currently support a homepage.
    visit new_user_session_path

    # this forces capybara to wait until the proper page loads.
    # otherwise our tests will immediately start trying to match things before the page even loads.
    assert page.has_content?("Sign In")
  end

  def sign_up_from_homepage_for(display_details)
    # TODO the tailwind port of bullet train doesn't currently support a homepage.
    visit new_user_registration_path

    # this forces capybara to wait until the proper page loads.
    # otherwise our tests will immediately start trying to match things before the page even loads.
    assert page.has_content?("Create Your Account")
  end

  def within_homepage_navigation_for(display_details)
    if display_details[:mobile]
      open_mobile_menu
    end
    yield
  end

  def within_primary_menu_for(display_details)
    open_mobile_menu if display_details[:mobile]
    within ".menu" do
      yield
    end
  end

  def be_invited_to_sign_up
    # if the application is configured to only allow invitation-only sign-ups, visit the invitation url.
    visit invitation_path(key: invitation_keys.first) if invitation_only?
  end

  def select2_select(label, string)
    string = string.join("\n") if string.is_a?(Array)
    field = find("label", text: /\A#{label}\z/)
    field.click
    "#{string}\n".chars.each do |digit|
      within(field.find(:xpath, "..")) do
        find(".select2-search__field").send_keys(digit)
      end
    end
  end

  # https://stackoverflow.com/a/50794401/2414273
  def assert_no_js_errors
    last_timestamp = page.driver.browser.logs.get(:browser)
      .map(&:timestamp)
      .last || 0

    yield

    errors = page.driver.browser.logs.get(:browser)
    errors = errors.reject { |e| e.timestamp > last_timestamp } if last_timestamp > 0
    errors = errors.reject { |e| e.level == "WARNING" }

    assert errors.length.zero?, "Expected no js errors, but these errors where found: #{errors.join(", ")}"
  end

  def find_stimulus_controller_for_label(label, stimulus_controller, wrapper = false)
    if wrapper
      wrapper_el = find("label", text: /\A#{label}\z/).first(:xpath, ".//..//..")
      wrapper_el if wrapper_el["data-controller"] == stimulus_controller
    else
      find("label", text: /\A#{label}\z/).first(:xpath, ".//..").first('[data-controller="' + stimulus_controller + '"]')
    end
  end

  def set_element_attribute(element, attribute, value)
    page.evaluate_script(<<~JS, element, attribute, value)
      (function(element, attribute, value){
        element.setAttribute(attribute, value)
      })(arguments[0], arguments[1], arguments[2])
    JS
  end

  def disconnect_stimulus_controller_on(element)
    set_element_attribute(element, "data-former-controller", element["data-controller"])
    set_element_attribute(element, "data-controller", "")
  end

  def reconnect_stimulus_controller_on(element)
    set_element_attribute(element, "data-controller", element["data-former-controller"])
  end

  def improperly_disconnect_and_reconnect_stimulus_controller_on(element)
    inner_html_before_disconnect = element["innerHTML"]

    disconnect_stimulus_controller_on(element)

    page.evaluate_script(<<~JS, element, inner_html_before_disconnect)
      (function(element, innerHTML){
        element.innerHTML = innerHTML
      })(arguments[0], arguments[1])
    JS

    reconnect_stimulus_controller_on(element)
  end

  def calculate_resolution(display_details)
    # cut the display's pixel count in half if we're mimicking a high dpi display.
    display_details[:resolution].map { |pixel_count| pixel_count / (display_details[:high_dpi] ? 2 : 1) }
  end

  # We monkey patch #execute when headless browser system tests
  # are finicky and need to sleep to reflect changes.
  module ::Selenium::WebDriver::Remote
    class Bridge
      @@execute_sleep_time = 0
      alias_method :patched_execute, :execute
      def execute(*args)
        sleep @@execute_sleep_time
        patched_execute(*args)
      end

      def self.slow_down_execute_time
        @@execute_sleep_time = 0.5
      end

      def self.reset_execute_time
        @@execute_sleep_time = 0
      end
    end
  end
end
