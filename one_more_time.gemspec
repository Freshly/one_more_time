$:.push File.expand_path("lib", __dir__)

# Maintain your gem's version:
require "one_more_time/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |spec|
  spec.name        = "one_more_time"
  spec.version     = OneMoreTime::VERSION
  spec.authors     = ["Andrew Cross"]
  spec.email       = ["andrew.cross@freshly.com"]
  spec.homepage    = "https://github.com/Freshly/one_more_time"
  spec.summary     = "A simple gem to help make your API idempotent"
  spec.description = "Use your database to store previous responses and guarantee safe retries."
  spec.license     = "MIT"

  spec.files = Dir["{bin,lib}/**/*", "LICENSE", "Rakefile", "README.md"]

  spec.add_dependency "activerecord", ">= 6.0.2.1", "< 7.1.0"

  spec.add_development_dependency "rspec"
  spec.add_development_dependency "sqlite3"
  spec.add_development_dependency "timecop"
end
