# frozen_string_literal: true

require "test_helper"

# Wording rules for the engine's auth pages (lib/studio/auth_labels.rb): every
# form derives from Studio.sign_in_label, and the default label reproduces the
# words the pages printed before the label reached them.
class AuthLabelsTest < Minitest::Test
  L = Studio::AuthLabels

  def test_the_default_label_reproduces_the_pre_feature_words
    label = Studio::NavbarIdentity::DEFAULT_SIGN_IN_LABEL

    refute L.configured?(label)
    assert_equal "Log in", L.link(label)
    assert_equal "Log In", L.button(label)
    assert_equal "Log in to continue", L.prompt(label)
    assert_equal "Sign in to Cyvasse", L.to_app(label, "Cyvasse")
    assert_equal "or sign in below", L.or_below(label)
    assert_equal "sign-in link", L.link_noun(label)
  end

  def test_sign_in_says_sign_in_everywhere
    label = "Sign in"

    assert L.configured?(label)
    assert_equal "Sign in", L.link(label)
    assert_equal "Sign In", L.button(label)
    assert_equal "Sign in to continue", L.prompt(label)
    assert_equal "Sign in to Cyvasse", L.to_app(label, "Cyvasse")
    assert_equal "or sign in below", L.or_below(label)
    assert_equal "sign-in link", L.link_noun(label)
  end

  # A label unlike either default shows every form is derived, not looked up.
  def test_any_other_label_derives_every_form
    label = "Log on"

    assert_equal "Log On", L.button(label)
    assert_equal "Log on to continue", L.prompt(label)
    assert_equal "Log on to Cyvasse", L.to_app(label, "Cyvasse")
    assert_equal "or log on below", L.or_below(label)
    assert_equal "log-on link", L.link_noun(label)
  end

  def test_the_button_capitalises_only_first_letters
    assert_equal "Sign In", L.button("Sign In")
    assert_equal "Enter", L.button("enter")
    assert_equal "Log In With Google", L.button("log in with Google")
  end
end
