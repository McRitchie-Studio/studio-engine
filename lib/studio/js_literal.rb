require "action_view"

module Studio
  # ONE home for the repair that keeps a host-supplied value from bricking an
  # Alpine component when it is spliced into a JS-evaluating HTML attribute.
  #
  # THE FAILURE THIS EXISTS FOR is silent, which is the whole reason it is worth a
  # module instead of a convention. A local sits inside a JS single-quoted literal
  # in a double-quoted attribute:
  #
  #     <button @click="$dispatch('<%= cta_event %>')">
  #
  # A bare apostrophe in `cta_event` closes that literal, the expression becomes a
  # SyntaxError, and Alpine mounts the component as a NO-OP that still renders
  # every element. Perfect-looking markup, dead card. Nothing raises, nothing logs
  # a server-side warning, and every string assertion about the response bytes
  # still passes — which is how this class of defect survives a review.
  #
  # BOTH ESCAPERS HAVE TO RUN, and that is the part a hand-written call gets wrong.
  # There are two nested contexts, so there are two ways out of the attribute:
  #
  #   * out of the JS STRING, with `'` — repaired by escape_javascript
  #   * out of the HTML ATTRIBUTE, with `"` — repaired by ERB's own escaping
  #
  # escape_javascript covers the first. ERB covers the second, but ONLY for a value
  # it believes is unsafe, and `escape_javascript(SafeBuffer)` answers true to
  # html_safe?. Hand an html_safe string straight to escape_javascript and ERB
  # steps aside, a raw double quote reaches the attribute, and the attribute closes
  # early — the same dead card by a longer route.
  #
  # So the interpolation wrapper below is LOAD-BEARING, not a style tic: `"#{value}"`
  # produces a plain String, escape_javascript therefore returns a plain String, and
  # ERB does its half on the way into the attribute. That subtlety was re-derived at
  # every call site before this module existed, and it had no test cover anywhere;
  # it now has exactly one implementation and one guard
  # (test/lib/studio/js_literal_test.rb).
  #
  # DELIBERATELY NARROW — there is no script-body variant here, and adding one is
  # not a copy of this method. Inside <script>…</script> the HTML parser does no
  # entity decoding, so ERB's escaping is not a second layer of safety there, it is
  # CORRUPTION: `\"` would arrive as `\&quot;` and break the JS this method exists
  # to protect. A script body wants JS escaping ONLY (escape_javascript, marked
  # safe). The name says `in_attribute` so that the next person reaching for this in
  # a <script> has to stop and notice the difference.
  #
  # AND IT IS THE WRONG REPAIR FOR AN ATTRIBUTE THE PARTIAL ASSEMBLES ITSELF —
  # `<%= "x-init=\"#{expr}\"".html_safe %>`, where the attribute's OWN QUOTES are
  # built in Ruby. Nothing here helps: escaping the value would break the Alpine
  # EXPRESSION the caller deliberately handed the engine, and the marking has already
  # told ERB to stand down, so a double quote closes the ATTRIBUTE and the remainder
  # is parsed as MARKUP. The repair is to stop writing the quotes and let ActionView
  # write them — `tag.attributes("x-init": expr.html_safe)` — because tag_option
  # quote-escapes the finished value UNCONDITIONALLY, outside the escape branch it
  # skips for a marked String. The expression survives byte-for-byte and cannot end
  # the attribute. modals/blocks/_rail_row:112 and components/_sidebar_panel carry
  # the worked examples; test/lib/studio/attribute_encoding_contract_test.rb pins the
  # ActionView behaviour the whole thing rests on.
  #
  # AND IT IS THE WRONG REPAIR FOR IDENTIFIER POSITION. A local spliced in as a bare
  # NAME — `$store.<%= modal_store %>.close()` — must be VALIDATED, never escaped:
  # escape_javascript also escapes `$`, so a legitimate store name like `dsModals$2`
  # comes back mangled and the card dies anyway. The SHAPE of the splice decides the
  # repair, never the name of the local. studio/modals/onboarding/_first_name
  # carries the worked example of both.
  module JsLiteral
    extend ActionView::Helpers::JavaScriptHelper

    module_function

    # Escape +value+ for a JS string literal that lives inside an HTML attribute.
    #
    # Returns a plain (NOT html_safe) String on purpose — see the note above. The
    # caller interpolates it inside the JS quotes, exactly as it would have
    # interpolated the raw local:
    #
    #     cta_event_js = Studio::JsLiteral.in_attribute(cta_event)
    #     # …
    #     <button @click="$dispatch('<%= cta_event_js %>')">
    #
    # nil becomes "" rather than "nil", because every current caller reaches this
    # with an optional local and an empty JS string is the honest rendering of an
    # absent value.
    # ONE MECHANISM, DELIBERATELY. An earlier draft also re-stripped the marking on
    # the way out, as belt-and-braces. That made both halves redundant, and a
    # redundant guard is one that survives being deleted: removing the interpolation
    # below left every test green, because the second stripper covered for it. There
    # is one way this works now, and test/lib/studio/js_literal_test.rb fails when it
    # is removed.
    def in_attribute(value)
      JsLiteral.escape_javascript("#{value}")
    end
  end
end
