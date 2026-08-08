# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [component] The shared environment banner, rendered. Boots the dummy app on
# purpose so the partial calls the REAL Studio wrappers (lib/studio.rb) rather
# than test_helper's pure-Ruby stand-in.
#
# The contract hosts adopt:
#   A. One render call. `studio/banners/environment` decides for itself whether
#      to appear — hosts no longer carry a show_environment_banner? of their own.
#   B. It is silent in real production, and speaks on QA (Rails-production +
#      QA_ENV), which is a review target, not production.
#   C. The Local Inbox is linked ONLY where it resolves. Studio::LocalEmailsController
#      gates on the same call, so the banner can never advertise a 404 — off-box
#      it degrades to an inert status chip.
#   D. `preview: true` renders nothing, so a navbar-preview copy can't duplicate
#      live chrome (a duplicate vt-pinned-header kills view transitions).
class EnvironmentBannerTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  class StubRequest
    def initialize(local:)
      @local = local
    end

    def local?
      @local
    end
  end

  setup do
    @original_qa_env = ENV["QA_ENV"]
    ENV.delete("QA_ENV")
  end

  teardown do
    ENV["QA_ENV"] = @original_qa_env
    ENV.delete("QA_ENV") if @original_qa_env.nil?
  end

  # ── A. one render call, self-gating ─────────────────────────

  test "renders the environment label in a non-production environment" do
    html = render_banner

    assert_includes html, "Test Environment"
    assert_includes html, "DEV MODE"
  end

  test "renders nothing in real production" do
    html = with_rails_env("production") { render_banner }

    assert_equal "", html.strip
  end

  # ── B. QA speaks up ─────────────────────────────────────────

  test "a QA app names itself non-production instead of production" do
    ENV["QA_ENV"] = "true"
    html = with_rails_env("production") { render_banner }

    assert_includes html, "QA Environment · Non-production"
    refute_includes html, "Production Environment"
  end

  test "devnet reads as a message segment on QA and a chip elsewhere" do
    ENV["QA_ENV"] = "true"
    qa = with_rails_env("production") { render_banner(devnet: true) }
    assert_includes qa, "QA Environment · Non-production · Devnet"
    refute_includes qa, "DEVNET"

    ENV.delete("QA_ENV")
    dev = render_banner(devnet: true)
    assert_includes dev, "DEVNET"
    refute_includes dev, "· Devnet"
  end

  # ── C. the inbox link tells the truth ───────────────────────

  test "links the local inbox when the viewer resolves for this request" do
    html = render_banner(request_local: true)

    assert_includes html, %(href="/_studio/local_emails")
    refute_includes html, %(role="status")
  end

  test "degrades to an inert status chip when the viewer would 404" do
    html = render_banner(request_local: false)

    refute_includes html, %(href="/_studio/local_emails")
    assert_includes html, %(role="status")
    assert_includes html, "Inbox: local only"
  end

  # The gate the banner asks is the SAME one the controller enforces. Assert the
  # shared mechanism, not two spellings that happen to agree today.
  test "the banner and the controller consult one gate" do
    assert_equal Studio.local_tool_enabled?(request_local: true),
                 Studio.local_inbox_reachable?(request_local: true)
    assert_equal Studio.local_tool_enabled?(request_local: false),
                 Studio.local_inbox_reachable?(request_local: false)

    controller = File.read(File.join(ENGINE_ROOT, "app/controllers/studio/local_emails_controller.rb"))
    assert_includes controller, "Studio.local_tool_enabled?(request_local: request.local?)"
  end

  # ── D. preview renders nothing ──────────────────────────────

  test "a preview render emits no banner" do
    assert_equal "", render_banner(preview: true).strip
  end

  private

  # Narrowly swaps the single Rails seam (Studio.rails_env_name) so the REAL
  # show?/message rules run underneath. Deliberately not `Rails.env =`, which
  # poisons lazily-drawn routes for the rest of the process.
  def with_rails_env(name)
    original = Studio.method(:rails_env_name)
    Studio.define_singleton_method(:rails_env_name) { name }
    yield
  ensure
    Studio.define_singleton_method(:rails_env_name, original)
  end

  def render_banner(request_local: true, **locals)
    view = ActionView::Base.with_empty_template_cache.with_view_paths(
      [File.join(ENGINE_ROOT, "app/views")]
    )
    view.extend(StudioEmailDeliveryHelper)
    stub_request = StubRequest.new(local: request_local)
    view.define_singleton_method(:request) { stub_request }

    view.render(partial: "studio/banners/environment", locals: locals).to_s
  end
end
