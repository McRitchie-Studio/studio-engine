# frozen_string_literal: true

# e2e/boot.rb — compile the lab's assets, then serve the dummy host app.
#
# Playwright's webServer runs this. It replaces the `bin/rails db:test:prepare &&
# bin/rails tailwindcss:build && bin/rails server` chain the hub's lane uses,
# because a GEM has no Rails root: there is no bin/rails, no config.ru, no
# config/environments, and test/dummy deliberately has none of them either. Rather
# than grow four files of Rails-app scaffolding inside a gem's test fixture, this
# script does the same three jobs directly — build CSS, build JS, serve — which
# also means the lane never depends on a `rails` CLI resolving the right app root.
#
# THE DATABASE IS DELIBERATELY LEFT ALONE. test/dummy runs sqlite :memory:, which is
# per-process — the hub's lane shares one Postgres between its server and its specs
# and documents the resulting cross-suite hazard. Nothing here needs that: the lab
# pages render partials whose inputs are locals and a fixed epoch, so there is no
# row for a spec to seed and no state for a minitest run to truncate underneath it.
# If a future lab page needs a record, it must seed it IN THIS PROCESS (the browser
# only ever reads through HTTP) rather than reaching for a shared database.

require "bundler/setup"
require "fileutils"
require "base64"

ROOT = File.expand_path("..", __dir__)
PUBLIC_DIR = File.join(ROOT, "test", "dummy", "public", "e2e")

FileUtils.mkdir_p(PUBLIC_DIR)

# ---- The host's favicon ------------------------------------------------------
#
# _head links `<link rel="icon" href="/favicon.png">` and every real host serves one.
# The dummy did not, so every lab page 404'd on it. Not cosmetic here: `watchPageErrors`
# counts console.error and a failed load IS one, so a spec asserting a clean console
# passes or fails on whether the browser's LAZY favicon fetch beat the assertion. It hid
# from 2026-03-24 until a head change shifted script timing and reddened `release` at
# b654525, 48 passed / 1 failed. Written, not committed — test/dummy/public is gitignored
# whole. A 1x1 transparent PNG: the REQUEST must succeed; nobody looks at it.
favicon = File.join(ROOT, "test", "dummy", "public", "favicon.png")
File.binwrite(favicon, Base64.decode64(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk" \
  "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
))

# FAIL LOUD, like the CSS build below: a lane serving a page that 404s on its own
# icon reports console noise as spec failures, which reads as a defect in whatever
# spec happened to observe it.
abort "e2e/boot: favicon not written at #{favicon}" if File.size?(favicon).to_i.zero?

# ---- CSS ---------------------------------------------------------------------
#
# The SAME binary tailwindcss-rails hands consumers (tailwindcss-ruby is already a
# transitive runtime dependency of this gem), driven directly. test/integration/
# tailwind_probe_build_test.rb established that this repo can shell out to a real
# Tailwind v4 compile; this is the same move with the lab's entry point.
require "tailwindcss/ruby"

css_out = File.join(PUBLIC_DIR, "tailwind.css")
css_in = File.join(ROOT, "e2e", "tailwind_input.css")

warn "e2e/boot: compiling #{File.basename(css_in)} -> #{css_out}"
ok = system(Tailwindcss::Ruby.executable.to_s, "-i", css_in, "-o", css_out, "--minify")

# FAIL LOUD, AND FAIL HERE. A lane whose CSS silently failed to build still serves
# every page — just with no `position: sticky` anywhere — so the paint specs would
# run against a page that cannot exhibit the defect and would go GREEN. That is the
# precise shape of false confidence this lane exists to remove, so a failed or empty
# build aborts the server before a single spec runs.
abort "e2e/boot: tailwind build FAILED" unless ok
abort "e2e/boot: tailwind build produced nothing at #{css_out}" if File.size?(css_out).to_i.zero?

# ---- Alpine: DELETED FROM HERE ON PURPOSE ------------------------------------
#
# This used to copy node_modules/alpinejs/dist/cdn.min.js to public/e2e/alpine.js,
# and E2eLabController's `javascript_importmap_tags` stand-in served it. That existed
# because the engine's head loaded Alpine from a CDN, and this lane refuses to fetch
# a dependency over the public internet — one DNS failure away from reporting green
# over dead components. The lane compensated for the defect instead of observing it.
#
# The engine now VENDORS Alpine (app/assets/javascripts/studio/alpine.js), so the
# block below already copies it, and the head's own javascript_include_tag delivers
# it — the real path a consumer uses. Keeping the node_modules copy would load Alpine
# TWICE and, worse, make the delivery UNOBSERVABLE: with a second Alpine always in
# the page, e2e/vendored_alpine.spec.js stayed green with the CDN tag restored, which
# is how this was found.
#
# It also removes the last floating dependency in the lane. `alpinejs: ^3.14.9`
# resolved to 3.16.1 today and to whatever npm serves tomorrow — the same defect the
# vendoring exists to fix, one directory over.

# ---- The engine's OWN served assets ------------------------------------------
#
# app/assets/javascripts/studio/*.js and app/assets/stylesheets/studio/*.css are
# files the engine SHIPS and a consumer's asset pipeline serves verbatim. Copying
# rather than regenerating them is the point: the bytes a spec drives here are the
# bytes a consumer gets. E2eLabController::AssetDelivery serves them from these
# paths in place of the host asset pipeline the dummy does not have.
# app/assets/fonts/studio/*.woff2 rides the same rule: the head declares its
# @font-face against those exact bytes, so a spec that measures text is measuring the
# font a consumer ships rather than whatever the runner happens to have installed.
{ "javascripts" => "js", "stylesheets" => "css", "fonts" => "fonts" }.each do |source_dir, public_sub|
  source = File.join(ROOT, "app", "assets", source_dir, "studio")
  next unless Dir.exist?(source)

  target = File.join(PUBLIC_DIR, public_sub, "studio")
  FileUtils.mkdir_p(target)
  FileUtils.cp_r(Dir.glob(File.join(source, "*")), target)
end

# ---- Email banner artwork ----------------------------------------------------
#
# The email-frames lab page renders the REAL layered banner partial, which wants a
# background and a logo. Copied rather than stubbed with a placeholder: a missing
# image 404s, and the lane's own error watch counts a failed resource load as a
# failure — so a stub would make the page noisy about something the spec does not
# care about while measuring boxes.
# ---- Turbo, for the site footer pages and one survey spec ---------------------
#
# The lab has no Turbo (docs/E2E_LANE.md, "Not covered"), and the footer map's
# remount after a Turbo visit is exactly the behaviour its spec exists to see. So
# the footer pages' own layout (layouts/site_footer_lab) loads the real Turbo
# build out of the turbo-rails gem the engine already depends on. The survey's
# Turbo restore spec opts in by cookie (layouts/survey_turbo_lab). Every other
# lab page keeps the lab layout and stays Turbo-free.
# The engine's ES modules (app/javascript), which its importmap pins. Served under
# /e2e/modules so a lab page's import map resolves "studio/<name>" to the real file
# (E2eLabController::AssetDelivery maps the pin's asset path here).
MODULE_SOURCE = File.join(ROOT, "app", "javascript")
FileUtils.mkdir_p(File.join(PUBLIC_DIR, "modules"))
FileUtils.cp_r(Dir.glob(File.join(MODULE_SOURCE, "*")), File.join(PUBLIC_DIR, "modules"))

turbo_source = File.join(Gem.loaded_specs.fetch("turbo-rails").full_gem_path, "app", "assets", "javascripts", "turbo.min.js")
abort "e2e/boot: turbo.min.js missing from turbo-rails at #{turbo_source}" unless File.exist?(turbo_source)
FileUtils.mkdir_p(File.join(PUBLIC_DIR, "js"))
FileUtils.cp(turbo_source, File.join(PUBLIC_DIR, "js", "turbo.min.js"))

IMG_DIR = File.join(PUBLIC_DIR, "img")
FileUtils.mkdir_p(IMG_DIR)
{
  "magic-link-background.gif" => "banner.gif",
  "logo-horizontal.png" => "logo.png"
}.each do |source_name, target_name|
  source = File.join(ROOT, "app", "assets", "images", "emails", source_name)
  FileUtils.cp(source, File.join(IMG_DIR, target_name)) if File.exist?(source)
end

# ---- The geo grid's flag art -------------------------------------------------
#
# The geo lab page renders 52 subdivision squares, each with its flag. The dummy
# has no asset pipeline, so `image_path` resolves to /images/<logical path> and
# these have to exist under public/ or every square 404s — which this lane counts
# as console noise, not as the missing pictures they are.
FLAG_SOURCE = File.join(ROOT, "app", "assets", "images", "state-flags", "thumb")
FLAG_DIR = File.join(ROOT, "test", "dummy", "public", "images", "state-flags", "thumb")
if Dir.exist?(FLAG_SOURCE)
  FileUtils.mkdir_p(FLAG_DIR)
  FileUtils.cp_r(Dir.glob(File.join(FLAG_SOURCE, "*")), FLAG_DIR)
end

# ---- Serve -------------------------------------------------------------------
ENV["RAILS_ENV"] ||= "test"
require_relative "../test/dummy/config/environment"

# ---- THE LAB HOST'S OWN IDENTITY ---------------------------------------------
#
# A NAVBAR LOGO AND A TWO-WORD APP NAME, because every real consumer has both and
# the bare dummy has neither. This is not dressing — it is the difference between
# a lane that can see a header width defect and one that structurally cannot.
#
# MEASURED, on this exact page: with Studio's defaults (app_name "Studio", no
# theme_logos, so logo_for returns nil) the signed-in header at 390px measured
# scrollWidth 390 / clientWidth 390 and reported ZERO overflowing elements — a
# perfectly green read over the header this task exists to fix. The left column
# is `flex-1` (min-width: auto, so it floors at its own min-content) and the
# right column is flex-shrink-0 at 14rem; with no logo and a 6-letter title the
# left min-content happened to fit in the 166px the right column left behind.
# Add the 48px logo and a real word and it does not.
#
# Set HERE and not in test/dummy/config — the minitest suites boot that same
# dummy and several interpolate Studio.app_name into expected strings. This is
# the LANE's host config, the same relationship E2eLabController::AssetDelivery
# has to the host asset pipeline.
#
# WHY THIS NAME. "McRitchie Industries" is one of the TWO apps that render
# layouts/_navbar rather than a fork of it (the other is "Acquisition Studio");
# the hub and turf-monster both fork the header, so their names say nothing
# about this partial. Picking a name from an app that does not render the file
# would be dressing; this is the file's own widest real consumer.
#
# NO ENV OVERRIDE, deliberately. An earlier cut of this read the name from
# E2E_APP_NAME so the widths could be swept by hand. That is a knob which
# changes what the lane MEASURES without appearing in any diff, which is the
# exact shape config/e2e_lane.yml exists to refuse. Sweep by editing this line
# in a branch you throw away.
#
# WHAT THESE TWO LINES MOVE, measured, because they change EVERY spec that
# reads the header's height — e2e/nav_collapse.spec.js's endpoint table was
# re-derived in the same commit and carries the same numbers:
#
#   one-word name, no logo (the old bare dummy)   mobile 113 / desktop 84 expanded
#   two-word name, no logo                        mobile 117 (320-399), 124 (400-767)
#   two-word name + logo  (what ships here)       mobile 125 / desktop 96 expanded
#
# The logo raises BOTH bands (it is 48px, taller than a title line); the second
# word raises only the mobile band, where .nav-title stacks into a column. A
# one-word, logo-less host is a shape no consumer has ever been in.
Studio.app_name = "McRitchie Industries"
Studio.theme_logos = [{ file: "e2e/img/nav-logo.png", title: "Navbar Logo" }]

nav_logo = File.join(PUBLIC_DIR, "img", "nav-logo.png")
FileUtils.mkdir_p(File.dirname(nav_logo))
File.binwrite(nav_logo, Base64.decode64(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk" \
  "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
))
# FAIL LOUD, for the same reason the favicon does: the navbar logo is an <img>
# whose failed load surfaces to watchPageErrors as a console.error, which would
# fail whichever spec happened to observe it rather than naming the cause. The
# CSS sizes it off --nav-logo-size, so the intrinsic pixels are irrelevant — the
# REQUEST is what has to succeed.
abort "e2e/boot: nav logo not written at #{nav_logo}" if File.size?(nav_logo).to_i.zero?

# ---- The geo table -----------------------------------------------------------
#
# The one lab page that needs a SCHEMA. It runs the REAL migration the gem ships
# rather than a hand-written CREATE, so the lane also proves that migration runs
# on a non-Postgres adapter — the reason it picks its json type at runtime.
#
# ON A FILE, NOT `:memory:`, and that is the whole trick: an in-memory sqlite
# database belongs to ONE CONNECTION, so a table created here is invisible to the
# pooled connection that serves the request — which is exactly how this first
# failed ("Could not find table 'studio_geo_settings'" on a page whose migration
# had just run). The file is this boot's own, created fresh each time and never
# shared with a minitest run, so the header's rule above still holds: the lab
# seeds its own state and reaches for nobody else's database.
require_relative "../db/migrate/20260818120000_create_studio_geo_settings"
# The site identity page (/lab/site_identity) renders its form from the real
# model, which needs its real table.
require_relative "../db/migrate/20260930120000_create_studio_site_identities"
require_relative "../db/migrate/20261005120000_create_studio_survey_responses"

lab_db = File.join(ROOT, "tmp", "e2e-lab.sqlite3")
FileUtils.mkdir_p(File.dirname(lab_db))
FileUtils.rm_f(lab_db)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: lab_db)
ActiveRecord::Migration.suppress_messages do
  CreateStudioGeoSettings.new.migrate(:up)
  CreateStudioSiteIdentities.new.migrate(:up)
  CreateStudioSurveyResponses.new.migrate(:up)
  # The host's users table, as far as the survey pages read it.
  ActiveRecord::Base.connection.create_table(:users) do |t|
    t.string :email
    t.string :username
    t.string :role
    t.timestamps
  end
  ActiveRecord::Base.connection.create_table(:error_logs) do |t|
    t.string :slug
    t.text :message
    t.text :inspect
    t.text :backtrace
    t.string :target_type
    t.bigint :target_id
    t.string :parent_type
    t.bigint :parent_id
    t.timestamps
  end
end
abort "e2e/boot: survey table missing" unless ActiveRecord::Base.connection.table_exists?(:studio_survey_responses)
abort "e2e/boot: survey definition not loaded from test/dummy/config/surveys" unless Studio.survey("first-game")

# The HOST's base controller, which the engine's survey controllers inherit.
# Shaped like every consumer's: Studio::ErrorHandling (current_user, the admin
# gate, require_authentication) in the lab's real layout and asset delivery.
class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  helper E2eLabController::AssetDelivery
  # The survey Turbo spec sets the survey_lab_turbo cookie to get the same page
  # under Turbo (layouts/survey_turbo_lab); everything else stays Turbo-free.
  layout -> { cookies[:survey_lab_turbo] == "1" ? "survey_turbo_lab" : "e2e_lab" }
end

class User < ApplicationRecord
  def admin? = role == "admin"
  def display_name = username.presence || email.to_s.split("@").first
end
abort "e2e/boot: geo table missing" unless ActiveRecord::Base.connection.table_exists?(:studio_geo_settings)

require "puma"
require "puma/server"

port = Integer(ENV.fetch("E2E_PORT", "3620"))
host = ENV.fetch("E2E_HOST", "127.0.0.1")

server = Puma::Server.new(Rails.application)
server.add_tcp_listener(host, port)

warn "e2e/boot: serving the dummy lab on http://#{host}:#{port}"
server.run
sleep
