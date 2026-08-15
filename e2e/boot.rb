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

ROOT = File.expand_path("..", __dir__)
PUBLIC_DIR = File.join(ROOT, "test", "dummy", "public", "e2e")

FileUtils.mkdir_p(PUBLIC_DIR)

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
{ "javascripts" => "js", "stylesheets" => "css" }.each do |source_dir, public_sub|
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
IMG_DIR = File.join(PUBLIC_DIR, "img")
FileUtils.mkdir_p(IMG_DIR)
{
  "magic-link-background.gif" => "banner.gif",
  "logo-horizontal.png" => "logo.png"
}.each do |source_name, target_name|
  source = File.join(ROOT, "app", "assets", "images", "emails", source_name)
  FileUtils.cp(source, File.join(IMG_DIR, target_name)) if File.exist?(source)
end

# ---- Serve -------------------------------------------------------------------
ENV["RAILS_ENV"] ||= "test"
require_relative "../test/dummy/config/environment"

require "puma"
require "puma/server"

port = Integer(ENV.fetch("E2E_PORT", "3620"))
host = ENV.fetch("E2E_HOST", "127.0.0.1")

server = Puma::Server.new(Rails.application)
server.add_tcp_listener(host, port)

warn "e2e/boot: serving the dummy lab on http://#{host}:#{port}"
server.run
sleep
