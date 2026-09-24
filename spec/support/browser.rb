# Examples tagged `:browser` need headless Chrome via Ferrum. They are
# skipped when Ferrum or a Chrome/Chromium binary isn't available.
RSpec.configure do |config|
  config.before(:each, :browser) do
    begin
      require "ferrum"
    rescue LoadError
      skip "ferrum is not installed"
    end

    browser_path = ENV["BROWSER_PATH"].presence || Ferrum::Browser::Options::Chrome.options.detect_path
    skip "Chrome/Chromium not found (set BROWSER_PATH)" unless browser_path && File.exist?(browser_path)
  end
end
