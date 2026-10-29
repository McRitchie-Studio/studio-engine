# frozen_string_literal: true

require_relative "../test_helper"

# [unit] The type scale is ONE contract in two places (task engine-type-scale-roles):
# Studio::TypeScale::ROLES (Ruby, what the brand kit and the docs read) and the
# type-* utilities in engine.css (what a page draws). This pins that each role's
# multiple and weight in the stylesheet are the ones ROLES names, so changing
# one without the other goes red here.
class TypeScaleContractTest < ActiveSupport::TestCase
  ENGINE_CSS = File.expand_path("../../app/assets/tailwind/studio_engine/engine.css", __dir__)

  def utility(name)
    File.read(ENGINE_CSS)[/^@utility #{Regexp.escape(name)} \{(.*?)^\}/m, 1] or flunk "engine.css has no @utility #{name}"
  end

  test "each type-* utility multiplies --type-base by the multiple ROLES names, at its weight" do
    Studio::TypeScale::ROLES.each do |name, multiple, weight|
      body = utility(name)
      assert_includes body, "font-size: calc(var(--type-base, 16px) * #{multiple});", name
      assert_includes body, "font-weight: var(--type-#{weight}-weight, #{weight == :display ? 800 : 400});", name
    end
  end

  test "type-dense swaps the dense base in for everything inside it" do
    assert_includes utility("type-dense"), "--type-base: var(--type-dense-base, 14px);"
  end

  test "the stylesheet fallbacks are the engine defaults" do
    assert_equal [16, 14, 800, 400], [Studio.type_base, Studio.type_dense_base, Studio.type_display_weight, Studio.type_text_weight]
  end
end
