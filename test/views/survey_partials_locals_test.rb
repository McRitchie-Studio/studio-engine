# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"

# [unit] The survey partials declare strict locals (studio/surveys/_question,
# _script, _styles), so a caller that passes a local the partial does not take,
# or leaves out one it needs, fails loudly at render instead of painting a
# question with a blank count or a silently ignored option.
#
# Every caller is studio/surveys/show, thanks, not_found and sign_in_required;
# no consuming app renders these partials directly.
class SurveyPartialsLocalsTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  setup do
    Studio::Survey.reset!
    @survey = Studio::Survey.define("locals-check") do
      title "How was it?"
      rating :overall, "How was it?", required: true, low_label: "Bad", high_label: "Great"
    end
  end

  teardown { Studio::Survey.reset! }

  # ── _question ──────────────────────────────────────────────

  test "_question renders with exactly the locals show passes" do
    doc = render_partial("studio/surveys/question",
                         question: question, index: 0, total: 3, response: nil, error: "Pick one")

    assert_includes doc.at_css("legend").text, "Question 1 of 3"
    assert_equal "Pick one", doc.at_css("[data-survey-error]").text
    assert_nil doc.at_css("[data-survey-error]")["hidden"]
  end

  test "_question's error is optional and hides the alert when absent" do
    doc = render_partial("studio/surveys/question", question: question, index: 1, total: 3, response: nil)

    assert_includes doc.at_css("legend").text, "Question 2 of 3"
    assert doc.at_css("[data-survey-error]").key?("hidden"), "no error, no alert"
  end

  test "_question refuses a local it does not declare" do
    error = assert_raises(ActionView::Template::Error) do
      render_partial("studio/surveys/question",
                     question: question, index: 0, total: 3, response: nil, step: 0)
    end
    assert_match(/unknown local: :step/, error.message)
  end

  test "_question refuses a render that leaves out a required local" do
    error = assert_raises(ActionView::Template::Error) do
      render_partial("studio/surveys/question", question: question, index: 0, response: nil)
    end
    assert_match(/missing local: :total/, error.message)
  end

  # ── _styles and _script ────────────────────────────────────

  test "_styles takes no locals" do
    assert_includes render_raw("studio/surveys/styles"), ".studio-survey__head--later"

    error = assert_raises(ActionView::Template::Error) do
      render_raw("studio/surveys/styles", theme: "dark")
    end
    assert_match(/no locals accepted/, error.message)
  end

  test "_script takes no locals" do
    assert_includes render_raw("studio/surveys/script"), "studio-survey__head--later"

    error = assert_raises(ActionView::Template::Error) do
      render_raw("studio/surveys/script", survey: @survey)
    end
    assert_match(/no locals accepted/, error.message)
  end

  # ── the accent fallback is the engine's default primary ────

  test "the accent falls back to the theme resolver's default primary, not a copied hex" do
    css = render_raw("studio/surveys/styles")

    assert_includes css, "var(--color-cta, #{Studio::ThemeResolver::DEFAULT_PRIMARY})"
    source = File.read(File.join(ENGINE_ROOT, "app/views/studio/surveys/_styles.html.erb"))
    refute_match(/--color-cta,\s*#/, source, "the fallback reads the constant, never a pasted hex")
  end

  private

  def question = @survey.questions.first

  def view
    view = ActionView::Base.with_empty_template_cache.with_view_paths([ File.join(ENGINE_ROOT, "app/views") ])
    # javascript_tag(nonce: true) asks the request for its CSP nonce.
    view.define_singleton_method(:content_security_policy_nonce) { "test-nonce" }
    view
  end

  def render_raw(partial, **locals)
    view.render(partial: partial, locals: locals).to_s
  end

  def render_partial(partial, **locals)
    Nokogiri::HTML::DocumentFragment.parse(render_raw(partial, **locals))
  end
end
