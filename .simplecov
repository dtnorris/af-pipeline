# Coverage is opt-in so the normal fast test loop remains unchanged.
SimpleCov.configure do
  coverage_dir ENV.fetch("AF_COVERAGE_REPORT", "coverage/fast")
  cover "lib/**/*.rb"
  enable_coverage :branch
end
