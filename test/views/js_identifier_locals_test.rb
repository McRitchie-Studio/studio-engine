# frozen_string_literal: true

require "bundler/setup"

ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"

require "minitest/autorun"
require "active_support/test_case"
require "action_view"
require "nokogiri"

# [integration] The CENSUS: every engine partial that takes a store-name local, and
# what each one does with a value that is not a JS identifier.
#
# THE SIBLING OF test/views/js_attribute_locals_test.rb, AND ITS OPPOSITE. That file
# covers values in STRING position, where any character is legal and the repair is to
# ESCAPE. This one covers values in IDENTIFIER position — spliced in as a bare NAME,
# `$store.<name>.close()` — where most characters are not legal at all and the repair
# is to REFUSE. Studio::JsIdentifier carries why escaping is actively wrong here.
#
# THE DEFECT THIS LEAVES BEHIND is a SILENT HALF-failure, which is worse than the
# silent whole one. Measured on this tree at accepted 90e01ea, before the change:
# `modal_store: "mo dals"` rendered `blocks/_birthday`'s x-data perfectly (a JS
# STRING, correctly escaped, and the factory looks it up with Alpine.store(name)) and
# rendered `$store.mo dals.close()` into the × one line down. Half the card worked.
# Nothing raised, nothing logged, and every string assertion about the response bytes
# passed. Seventeen partials emitted at least one such dead splice; the counts are in
# the PR body.
#
# HOW IT ASSERTS, and why source text is not allowed. `@click` and `x-if` are not
# legal HTML4 attribute names, so Nokogiri's HTML4 parser SILENTLY DROPS them —
# `button["@click"]` reads nil on a perfectly correct page, and any assertion built on
# that can never fail. Everything below is read through Nokogiri::HTML5, from the
# DECODED attribute value the browser will hand its JS parser, or from a <script>
# element's text (which the HTML parser does NOT entity-decode — the reason
# _scoped_host's `var STORE_NAME = '…'` could never be repaired by escaping).
#
# EVERY SEAM CARRIES A CONTROL. A refusal test alone is vacuous: a partial that
# raised for an unrelated reason (a missing required local, say) would pass it. So
# each partial is driven TWICE — hostile refused, and a real host identifier reaching
# the splice VERBATIM — and a third assertion says the default store name is NOT
# there, which is what a silent fallback would leave behind. #test_the_probe_can_miss
# proves the finder is capable of finding nothing.
class JsIdentifierLocalsTest < ActiveSupport::TestCase
  ENGINE_ROOT = File.expand_path("../..", __dir__)

  # A real host store name, and one that exercises the whole alphabet the pattern
  # admits: a leading letter, an underscore, an uppercase run, a `$`, and a digit.
  # `$` is the character that makes escaping the wrong repair — escape_javascript
  # would return `ds_Modals\$2` and kill a card that was never in danger.
  HOST_STORE = "ds_Modals$2"

  # Values a host could plausibly pass, each of which leaves identifier position by a
  # different door. NONE of them is repairable by escaping.
  HOSTILE_STORES = [
    "mo dals",          # a space — the plainest one, and escaping is a no-op on it
    "modals'x",         # ends the JS literal a STRING-position value would sit in
    %(modals"x),        # ends the HTML attribute
    "modals.foo",       # leaves member-access position by continuing it
    "modals-x",         # subtraction, not a name
    "2modals",          # a number, then a name
    "modals; alert(1)", # a statement
    "modals</script>",  # ends a script body
    "modals\nx",        # a newline INSIDE — catches an unanchored /^…$/ pattern
    ""                  # absent-but-present, which reads as `$store..close()`
  ].freeze

  # The census. partial => [store local, other required locals, renders as a layout?]
  #
  # THE LIST IS THE CLAIM. Nineteen partials in this engine fetch a store-name local;
  # seventeen of them reach identifier position and are here. The two that do not are
  # asserted separately below, because "we left it alone" is a finding that has to be
  # provable rather than an omission that looks like one.
  VALIDATED = {
    "studio/modals/saving"                   => [:store, {}, false],
    "studio/modals/scoped_host"              => [:store, {}, false],
    "studio/modals/auth/resend_footer"       => [:modal_store, {}, false],
    "studio/modals/blocks/age_gate"          => [:modal_store, {}, false],
    "studio/modals/blocks/close_x"           => [:modal_store, {}, false],
    "studio/modals/blocks/cta_redirect"      => [:modal_store, { href_key: "props.url" }, false],
    "studio/modals/blocks/entry_confirmed"   => [:modal_store, { title: "Confirmed" }, false],
    "studio/modals/blocks/free_entry_earned" => [:modal_store, {}, false],
    "studio/modals/blocks/leveling_activity" => [:modal_store, { title: "Quest", submit_url: "/l" }, false],
    "studio/modals/blocks/onchain_success"   => [:modal_store, { tx_signature_key: "props.tx",
                                                                 title_key: "props.title",
                                                                 subtitle_key: "props.subtitle",
                                                                 cta_label_key: "props.ctaLabel",
                                                                 cta_href_key: "props.ctaHref" }, false],
    "studio/modals/blocks/shell"             => [:modal_store, { title: "Title" }, true],
    "studio/modals/onboarding/first_name"    => [:modal_store, {}, false],
    "studio/modals/templates/action"         => [:modal_store, {}, false],
    "studio/modals/templates/form"           => [:modal_store, {}, false],
    "studio/modals/templates/status"         => [:modal_store, {}, false],
    "studio/modals/templates/success"        => [:modal_store, {}, false],
    "studio/modals/templates/wizard"         => [:modal_store, {}, false]
  }.freeze

  def view
    ActionView::Base.with_empty_template_cache.with_view_paths([File.join(ENGINE_ROOT, "app/views")])
                    .tap { |v| v.extend(Studio::Engine.helpers) }
  end

  def render_partial(name, layout: false, **locals)
    if layout
      view.render(layout: name, locals: locals) { "BODY".html_safe }
    else
      view.render(partial: name, locals: locals)
    end
  end

  # ActionView wraps whatever a template raises; unwrap to the error the partial
  # actually raised.
  def refusal_for(name, layout: false, **locals)
    render_partial(name, layout: layout, **locals)
    nil
  rescue StandardError => e
    e = e.cause while e.cause
    e
  end

  # Every attribute value in the fragment, DECODED, plus every <script> body RAW.
  #
  # Two readings because the browser does two things. In an attribute the parser
  # decodes entities before the JS parser ever sees the value, so `&#39;` is an
  # apostrophe by then. In a script body it decodes NOTHING, so an entity that
  # reached there is corruption rather than safety — which is exactly why the store
  # name in _scoped_host's `var STORE_NAME = '…'` had to be validated at the source
  # and could never have been escaped on the way in.
  def js_bearing_strings(html)
    fragment = Nokogiri::HTML5.fragment(html)
    values = []
    walk = lambda do |node|
      node.children.each do |child|
        next unless child.element?

        child.attribute_nodes.each { |attr| values << attr.value }
        values << child.text if child.name == "script"
        walk.call(child)
      end
    end
    walk.call(fragment)
    values
  end

  # How many places this render splices `$store.<name>` for the given name.
  def store_splices(html, name)
    js_bearing_strings(html).sum { |value| value.scan("$store.#{name}").size }
  end

  # --- The seventeen partials that splice a store name into identifier position ---

  VALIDATED.each do |partial, (local, extra, layout)|
    slug = partial.tr("/", "_")

    define_method(:"test_#{slug}_REFUSES_every_non_identifier_store") do
      HOSTILE_STORES.each do |bad|
        err = refusal_for(partial, layout: layout, **extra.merge(local => bad))

        assert_instance_of ArgumentError, err,
                           "#{partial} rendered #{bad.inspect} instead of refusing it — " \
                           "that is the silent half-failure this guard exists to end"
        assert_includes err.message, local.to_s,
                        "the refusal has to name the local a host would have to fix"
      end
    end

    define_method(:"test_#{slug}_splices_a_host_identifier_VERBATIM") do
      # THE CONTROL for the refusal above, and the half only this can prove: a guard
      # that refused EVERYTHING, or that quietly substituted the default, would pass
      # the refusal test and fail here.
      html = render_partial(partial, layout: layout, **extra.merge(local => HOST_STORE))

      assert_operator store_splices(html, HOST_STORE), :>=, 1,
                      "#{partial} must reach the host's own store — `$store.#{HOST_STORE}` is " \
                      "not in any attribute or script this render emitted"
      assert_equal 0, store_splices(html, "modals"),
                   "#{partial} fell back to the default store; a host that named its store may " \
                   "not be silently handed a different one"
    end
  end

  # --- The two that are deliberately NOT validated -----------------------------

  def test_crop_photo_is_already_safe_and_is_left_alone
    # PROVEN BY RENDERING, not by reading the partial. The store name here never
    # reaches identifier position: it is a JS STRING argument to cropPhotoModal, and
    # the factory resolves it with `this.$store[this._storeName]` — a lookup by
    # string, where a space is as legal as a letter. Escaping is the whole repair,
    # and it already shipped (bucket A). Demanding an identifier here would break a
    # host for no gain.
    html = render_partial("studio/modals/crop_photo", store: "mo dals")

    assert_equal 0, store_splices(html, "mo dals"),
                 "crop_photo must not splice the store name in identifier position"
    assert_includes html, %q{cropPhotoModal({ store: 'mo dals' })},
                    "the name still has to ARRIVE — as an escaped JS string"
  end

  def test_birthday_refuses_through_the_shell_it_renders
    # NO GUARD OF ITS OWN, deliberately. _birthday's own splice is STRING position
    # (birthdayModal resolves it with Alpine.store(name)); the identifier contract is
    # owed by blocks/_shell, which it renders one line down. A second guard here would
    # be a redundant one — it would survive being deleted, which is the same as not
    # being there. What matters to a host is that the whole render still refuses, and
    # with the local's own name on it.
    err = refusal_for("studio/modals/blocks/birthday", modal_store: "mo dals", submit_url: "/b")

    assert_instance_of ArgumentError, err
    assert_includes err.message, "modal_store"
  end

  def test_birthday_passes_a_host_identifier_through_to_the_shell
    html = render_partial("studio/modals/blocks/birthday", modal_store: HOST_STORE, submit_url: "/b")

    assert_operator store_splices(html, HOST_STORE), :>=, 1,
                    "the shell's × must close the HOST's store, not the default"

    # AND ITS OWN STRING-POSITION USE STILL CARRIES THE SAME NAME — asserted through a
    # JS unescape rather than as bytes, because the two halves are NOT byte-identical
    # and that is correct. `j` escapes `$`, so the literal reads `'ds_Modals\$2'`
    # while the identifier one line down reads `ds_Modals$2`. In a JS string `\$` is
    # just `$` (a NonEscapeCharacter), so both halves resolve to the same store — but
    # only after the JS parser has run, which is why the assertion has to model it.
    # In IDENTIFIER position there is no parser step to undo it, and the same escaping
    # would have been fatal. That is the whole distinction in one render.
    literal = html[/store: '([^']*)'/, 1]
    assert literal, "_birthday no longer passes a store name to birthdayModal"
    assert_equal HOST_STORE, literal.gsub(/\\(.)/m) { Regexp.last_match(1) },
                 "a JS parser must recover the host's own store name from the x-data literal"
  end

  # --- The probe's own honesty --------------------------------------------------

  def test_the_probe_can_miss
    # NON-VACUITY. Every assertion above rests on store_splices finding, or not
    # finding, a name in the DECODED attribute values. If that reader returned
    # something for any input — or scanned the raw source and matched the partial's
    # own ERB — the whole file would be green no matter what shipped. So: the same
    # reader, the same render, a name the partial was never given.
    html = render_partial("studio/modals/blocks/shell", layout: true,
                                                        title: "Title", modal_store: HOST_STORE)

    assert_operator store_splices(html, HOST_STORE), :>=, 1
    assert_equal 0, store_splices(html, "neverPassedThisStore")
  end

  def test_the_probe_reads_attributes_html4_would_have_dropped
    # THE OTHER HALF of the probe's honesty, and the trap that has bitten this repo
    # before: `@click` is not a legal HTML4 attribute name, so Nokogiri's HTML4 parser
    # drops it and an assertion made through it reads nil on a CORRECT page. The
    # shell's × is exactly that attribute, so this pins that the reader above is
    # seeing it.
    html = render_partial("studio/modals/blocks/shell", layout: true,
                                                        title: "Title", modal_store: HOST_STORE)

    assert_nil Nokogiri::HTML::DocumentFragment.parse(html).at_css("button")["@click"],
               "if HTML4 now keeps @click, this test's premise is stale — but the file " \
               "should still read through HTML5"
    assert_includes js_bearing_strings(html), "$store.#{HOST_STORE}.close()"
  end
end
