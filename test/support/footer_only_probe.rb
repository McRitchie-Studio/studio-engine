# frozen_string_literal: true

require "bundler/setup"

# Boot probe for test/integration/footer_only_consumer_test.rb.
#
# A FOOTER-ONLY CONSUMER, written the way docs/SITE_FOOTER.md tells one to be
# written, and nothing more: an app with NO ActiveRecord (no
# active_record/railtie, no database), which adds the gem, sets
# Studio.site_footer, renders `studio_site_footer` in a page, and never calls
# Studio.routes(self). Rantly, weekly-lock and 10and5 are this app.
#
# WHAT IT DELIBERATELY DOES NOT DO is the point of the file. Each line below is
# a workaround the rantly pilot had to add, and the engine now owns instead. If
# one of them has to come back here for the probe to boot, the engine has
# regressed:
#
#   - no `require "active_support/core_ext/integer/time"` (nor active_support/all)
#   - no `Studio.validate_user_contract = false`, though ::User is defined, and
#     is not a model (rantly's is a Data class read from a YAML file)
#   - no `Rails.autoloaders.main.do_not_eager_load(...)` of the engine's app/ dirs
#   - no replacement for the `studio_engine:install:migrations` rake task
#
# It runs as its own process because a Rails app (and its frameworks) is one per
# process, and the dummy app the rest of the suite boots loads ActiveRecord.
#
# Contract (all via ENV, so the parent stays in charge):
#   PROBE_ROOT    Rails.root for the throwaway app (a parent-created tmpdir)
#   PROBE_EAGER   "1" boots with config.eager_load = true (what production does)
#   PROBE_ACTION  render | rake
#   PROBE_RESULT  file to write the JSON result to
#   RAILS_ENV     the environment to boot

require "json"
require "fileutils"
require "rails"
require "active_model/railtie"
require "action_controller/railtie"
require "action_view/railtie"

ROOT   = ENV.fetch("PROBE_ROOT")
EAGER  = ENV["PROBE_EAGER"] == "1"
ACTION = ENV.fetch("PROBE_ACTION", "render")
RESULT = ENV.fetch("PROBE_RESULT")

require "studio"

module FooterOnlyProbe
  class Application < ::Rails::Application
    config.root = ROOT
    config.load_defaults 8.1
    config.eager_load = EAGER
    config.secret_key_base = "studio-engine-footer-only-probe-not-a-real-secret"
    config.logger = ActiveSupport::Logger.new(IO::NULL)
    config.log_level = :fatal
    config.session_store :disabled
    config.hosts.clear

    # NOT A CONSUMER WORKAROUND. This throwaway app has no asset-pipeline gem
    # (a real one has propshaft or sprockets, which provide config.assets), so
    # it seeds the shim the engine's studio.assets initializer appends to, as
    # test/dummy and the log-rotation probe do.
    assets = ActiveSupport::OrderedOptions.new
    assets.precompile = []
    config.assets = assets
  end
end

# Rantly's User: a sample profile, not an account and not a model. The engine's
# user-contract check must leave it alone in an app with no ActiveRecord.
User = Data.define(:name)

Studio.configure do |config|
  config.site_footer = lambda do |view|
    {
      name: "Footer Only",
      logo: "/icon.svg",
      tagline: "A site with no database",
      columns: [["About", [["Home", view.root_path], ["Source", "https://example.test/source"]]]],
      legal: [["Home", view.root_path]]
    }
  end
end

FooterOnlyProbe::Application.initialize!

# After the boot, as a real app's app/controllers would autoload: ActionController
# runs `helper :all` when the class is defined, against the helpers path the
# boot assembled, which is how the engine's helpers reach the view.
class ApplicationController < ActionController::Base; end

class PagesController < ApplicationController
  def show = render(inline: "<main>Home</main><%= studio_site_footer %>")
end

Rails.application.routes.draw { root "pages#show" }

result = {
  env: Rails.env.to_s,
  eager_load: Rails.application.config.eager_load,
  active_record_loaded: defined?(::ActiveRecord::Base) ? true : false,
  active_record_railtie: defined?(::ActiveRecord::Railtie) ? true : false,
  engine_active_record: Studio.active_record?
}

case ACTION
when "render"
  status, _headers, body = Rails.application.call(Rack::MockRequest.env_for("http://localhost/"))
  html = +""
  body.each { |chunk| html << chunk }
  body.close if body.respond_to?(:close)
  result[:status] = status
  result[:html] = html
  # Every engine constant under app/ that eager loading reached. Zeitwerk loads
  # nothing it was told to skip, so this is the observable side of the guard.
  result[:loaded_engine_files] = $LOADED_FEATURES.grep(%r{\A#{Regexp.escape(Studio::Engine.root.join("app").to_s)}/})
                                                 .map { |path| path.delete_prefix("#{Studio::Engine.root}/") }
when "rake"
  require "rake"
  Rails.application.load_tasks
  task = "studio_engine:install:migrations"
  result[:task_defined] = Rake::Task.task_defined?(task)
  result[:task_described] = Rake::Task.task_defined?(task) && Rake::Task[task].comment.to_s
  out = StringIO.new
  begin
    $stdout = out
    Rake::Task[task].invoke
    result[:invoke] = "ok"
  rescue Exception => e # rubocop:disable Lint/RescueException -- rake's own handler exits 1 on any of these
    result[:invoke] = "#{e.class}: #{e.message}"
  ensure
    $stdout = STDOUT
  end
  result[:output] = out.string
  result[:migrate_dir_exists] = File.exist?(File.join(ROOT, "db", "migrate"))
  result[:files_under_root] = Dir.glob("**/*", base: ROOT).reject { |p| p.start_with?("log", "tmp") || p == "result.json" }
end

File.write(RESULT, JSON.generate(result))
