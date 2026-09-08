# frozen_string_literal: true

require "test_helper"
require "action_view"
require "action_view/helpers"

# [unit] THE ACTIONVIEW BEHAVIOUR EVERY ASSEMBLED-ATTRIBUTE REPAIR IN THIS ENGINE
# STANDS ON, pinned as a contract test on the dependency.
#
# The engine emits Alpine handlers as `tag.attributes("@click": expr.html_safe)`
# rather than hand-assembling `@click="#{expr}"`. That form is only correct because
# of a property of ActionView's tag_option that is easy to miss and is NOT implied
# by "html_safe means do not escape": the double-quote escape runs UNCONDITIONALLY,
# on the line AFTER the escape ternary, so it fires on a value ERB itself would
# leave alone.
#
#     value = escape ? ERB::Util.unwrapped_html_escape(value) : value.to_s
#     value = value.gsub('"', "&quot;") if value.include?('"')
#
# That single line is what lets an Alpine EXPRESSION keep its `'`, `<`, `&` and
# backslash byte-for-byte — which is the whole point, since the caller is handing
# the engine JS on purpose — while still being unable to close the attribute.
#
# WITHOUT THIS FILE THE PROPERTY HAS NO GUARD. Every seam-level test in
# test/views/assembled_attribute_locals_test.rb would go red together if a future
# Rails moved that gsub inside the ternary, but each would report itself as a bug in
# a partial. This file names the real cause once, in one assertion, in the layer
# that changed. It is a dependency contract, in the same spirit as
# test/integration/engine_rails_8_1_boot_test.rb.
class AttributeEncodingContractTest < ActiveSupport::TestCase
  include ActionView::Helpers::TagHelper

  EXPRESSION = %q{$store.modals.open('next') /* it's "code" */}

  test "tag.attributes quote-escapes an html_safe value, so a marked expression cannot close the attribute" do
    rendered = tag.attributes("@click": EXPRESSION.html_safe)

    assert_equal %q{@click="$store.modals.open('next') /* it's &quot;code&quot; */"}, rendered,
      "only the double quotes may move — the apostrophes are part of the JS"
    refute_includes rendered[/\A@click="(.*)"\z/m, 1], '"',
      "a raw double quote left inside the value would end the attribute early"
  end

  test "tag.attributes leaves every other character of a marked expression alone" do
    # The half that makes .html_safe worth keeping. An Alpine expression carries
    # apostrophes, angle brackets and ampersands as CODE; entity-escaping them would
    # still work in a browser but would move the bytes every consumer test reads.
    value = %q{a < b && c > d ? e('x') : f}
    assert_equal %(:class="#{value}"), tag.attributes(":class": value.html_safe)
  end

  test "tag.attributes fully escapes an UNMARKED value, which is what a content attribute is owed" do
    # The other half of the rule the engine follows: the marking tracks whether the
    # value is CODE or CONTENT. A pattern or a tooltip is content and takes the full
    # escaping, so a bare & reaches the browser as a literal & rather than opening an
    # entity.
    assert_equal %{title="Tom &amp; Jerry&#39;s &quot;best&quot;"},
                 tag.attributes(title: %q{Tom & Jerry's "best"})
  end

  test "an Alpine attribute NAME survives tag.attributes intact" do
    # xml_name_escape runs on the key. `@`, `.` and `:` are all legal in the names
    # Alpine and Turbo use, and a mangled key would silently unbind every handler
    # this engine emits — a failure that renders perfectly.
    %w[@click @click.outside @keydown.escape.window @turbo:before-cache.window
       x-data x-init :href].each do |name|
      assert_equal %(#{name}="v"), tag.attributes(name.to_sym => "v"),
        "#{name} must reach the markup unmangled"
    end
  end
end
