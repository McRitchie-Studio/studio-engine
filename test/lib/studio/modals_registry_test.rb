# frozen_string_literal: true

require "test_helper"

# [unit] Studio.modals, the on-demand modal registry: what it accepts, what it
# refuses, how locals resolve, and what the host advertises from it.
class ModalsRegistryTest < Minitest::Test
  def setup
    @registry = Studio::Modals::Registry.new
  end

  def test_studio_modals_is_one_registry
    assert_kind_of Studio::Modals::Registry, Studio.modals
    assert_same Studio.modals, Studio.modals
  end

  def test_register_lists_every_id_with_its_options
    @registry.register :contest_rules, partial: "modals/contest_rules"
    @registry.register "wallet-setup", partial: "modals/wallet_setup", auth: :user, prefetch: true

    assert_equal %w[contest_rules wallet-setup], @registry.ids
    rules = @registry[:contest_rules]
    assert_equal "modals/contest_rules", rules.partial
    assert_equal :any, rules.auth
    assert_equal false, rules.prefetch
    assert @registry["wallet-setup"].user_only?
    assert @registry["wallet-setup"].prefetch
    assert @registry.registered?("contest_rules")
    refute @registry.registered?("nope")
    assert_nil @registry["nope"]
  end

  def test_re_registering_an_id_replaces_it
    @registry.register :rules, partial: "a"
    @registry.register :rules, partial: "b"
    assert_equal ["rules"], @registry.ids
    assert_equal "b", @registry[:rules].partial
  end

  def test_refuses_an_id_that_would_need_escaping
    ["Rules", "rules'x", "a b", "../x", "", "-lead"].each do |id|
      assert_raises(ArgumentError, "accepted #{id.inspect}") { @registry.register id, partial: "x" }
    end
  end

  def test_refuses_a_missing_partial_an_unknown_auth_and_bad_locals
    assert_raises(ArgumentError) { @registry.register :a, partial: "" }
    assert_raises(ArgumentError) { @registry.register :a, partial: "x", auth: :admin }
    assert_raises(ArgumentError) { @registry.register :a, partial: "x", locals: 42 }
  end

  def test_locals_resolve_from_a_hash_a_helper_or_a_callable
    view = Struct.new(:name) { def rules_locals = { who: name } }.new("view")

    @registry.register :none, partial: "x"
    @registry.register :hash, partial: "x", locals: { who: "hash" }
    @registry.register :helper, partial: "x", locals: :rules_locals
    @registry.register :callable, partial: "x", locals: ->(v) { { who: "callable #{v.name}" } }
    @registry.register :bare, partial: "x", locals: -> { { who: "bare #{name}" } }

    assert_equal({}, @registry[:none].locals_for(view))
    assert_equal({ who: "hash" }, @registry[:hash].locals_for(view))
    assert_equal({ who: "view" }, @registry[:helper].locals_for(view))
    assert_equal({ who: "callable view" }, @registry[:callable].locals_for(view))
    assert_equal({ who: "bare view" }, @registry[:bare].locals_for(view), "a zero-arity block runs in the view")
  end

  def test_locals_that_are_not_a_hash_raise
    @registry.register :bad, partial: "x", locals: ->(_v) { "nope" }
    assert_raises(ArgumentError) { @registry[:bad].locals_for(Object.new) }
  end

  def test_client_config_prefetches_user_modals_only_for_a_signed_in_viewer
    @registry.register :auth, partial: "x", prefetch: true
    @registry.register :wallet, partial: "x", auth: :user, prefetch: true
    @registry.register :rules, partial: "x"

    out = @registry.client_config(url_template: "/_studio/modals/__id__", logged_in: false)
    assert_equal({ url: "/_studio/modals/__id__", ids: %w[auth wallet rules], prefetch: %w[auth] }, out)
    assert_equal %w[auth wallet], @registry.client_config(url_template: "/u", logged_in: true)[:prefetch]
  end

  def test_unregister_and_clear
    @registry.register :a, partial: "x"
    @registry.register :b, partial: "x"
    @registry.unregister(:a)
    assert_equal ["b"], @registry.ids
    @registry.clear!
    assert @registry.empty?
    refute @registry.any?
  end
end
