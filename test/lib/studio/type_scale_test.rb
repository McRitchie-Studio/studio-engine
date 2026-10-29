# frozen_string_literal: true

require_relative "../../test_helper"

# [unit] Studio::TypeScale (task engine-type-scale-roles): the per-app variables
# the type-* utilities read, and the sizes each base gives.
class StudioTypeScaleTest < Minitest::Test
  SETTINGS = %i[type_base type_dense_base type_display_weight type_text_weight].freeze

  def setup = @saved = SETTINGS.to_h { |name| [name, Studio.public_send(name)] }
  def teardown = @saved.each { |name, value| Studio.public_send(:"#{name}=", value) }

  def test_defaults_are_a_16px_public_base_and_a_14px_dense_base
    css = Studio::TypeScale.css
    assert_includes css, "--type-base: 16px;"
    assert_includes css, "--type-dense-base: 14px;"
    assert_includes css, "--type-display-weight: 800;"
    assert_includes css, "--type-text-weight: 400;"
  end

  def test_an_app_sets_its_own_bases_and_weights
    Studio.type_base = 18
    Studio.type_dense_base = 13.5
    Studio.type_display_weight = 700
    Studio.type_text_weight = 300
    css = Studio::TypeScale.css
    assert_includes css, "--type-base: 18px;"
    assert_includes css, "--type-dense-base: 13.5px;"
    assert_includes css, "--type-display-weight: 700;"
    assert_includes css, "--type-text-weight: 300;"
  end

  def test_the_public_and_dense_sizes_of_option_b
    assert_equal [96, 48, 24, 16, 12], Studio::TypeScale.sizes(16).values
    assert_equal [84, 42, 21, 14, 10.5], Studio::TypeScale.sizes(14).values
    assert_equal %w[type-title type-heading type-subhead type-body type-fine], Studio::TypeScale.sizes(16).keys
  end

  def test_a_bad_setting_is_refused_by_name
    Studio.type_base = "16px"
    error = assert_raises(ArgumentError) { Studio::TypeScale.css }
    assert_match(/Studio\.type_base/, error.message)
    Studio.type_base = 16
    Studio.type_text_weight = 450
    error = assert_raises(ArgumentError) { Studio::TypeScale.css }
    assert_match(/Studio\.type_text_weight/, error.message)
  end
end
