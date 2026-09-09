module Studio
  # ONE home for the CONTRACT a host-supplied value must meet when a partial
  # splices it into JS **identifier position** — a bare NAME rather than a string:
  #
  #     <button @click="$store.<%= modal_store %>.close()">
  #
  # THE SIBLING OF Studio::JsLiteral, AND ITS OPPOSITE. Both exist for the same
  # silent failure: a host value that makes an Alpine expression a SyntaxError, so
  # the component mounts as a NO-OP that still renders every element. Perfect
  # markup, dead card, nothing raised and nothing logged. The two differ on the
  # only question that matters — WHAT THE VALUE IS:
  #
  #   STRING position  — the value is DATA inside a JS literal. Any character is
  #     legal; the repair is to ESCAPE it (Studio::JsLiteral.in_attribute).
  #   IDENTIFIER position — the value is a NAME. Most characters are not legal at
  #     all; the repair is to REFUSE it, which is this module.
  #
  # ESCAPING IS ACTIVELY WRONG HERE, which is why this is a second module rather
  # than a second method on the first. escape_javascript also escapes `$`, so a
  # perfectly legal store name like `dsModals$2` comes back as `dsModals\$2` and
  # `$store.dsModals\$2.close()` is a SyntaxError — the same dead card, reached a
  # longer way, on a value that was never hostile. And for a value that IS hostile,
  # `$store.a\'b.close()` is not a rescued identifier either. There is no escaping
  # of identifier position; there is only validity.
  #
  # A PATTERN, NOT AN ALLOWLIST, and the reason outlives this engine. An allowlist
  # would be a shared primitive enumerating its own CONSUMERS — "modals" and the
  # style guide's "dsModals" today — so the next app to mount a page-scoped host
  # would be refused by its own dependency until a gem release admitted the name.
  # The real contract is narrower and stateless: the value is spliced into
  # member-access position, so it must be an identifier, and WHICH identifier is
  # none of the engine's business.
  #
  # IT RAISES RATHER THAN FALLING BACK TO A DEFAULT. A silent fallback is the worse
  # of the two repairs: the card would mount, look perfect, and talk to a store that
  # is not the host's — the same SILENT class this guard exists to leave behind,
  # only now with a working-looking page in front of it. A host meets this the first
  # time it renders, in development, with the local named.
  #
  # WHAT IT DOES NOT COVER. A value in string position that is ALSO a store name
  # (blocks/_birthday's `store: '<%= j modal_store %>'`, which reaches
  # `Alpine.store(name)` — a lookup by string, where any character is legal) needs no
  # identifier. Validate where the value reaches a SPLICE, not everywhere the word
  # "store" appears; test/views/js_identifier_locals_test.rb carries the census.
  module JsIdentifier
    # ASCII IdentifierName — what member access after a dot accepts. It admits every
    # store name a host would plausibly write (`modals`, `dsModals`, `ds_Modals$2`)
    # and rejects every character that could leave identifier position: quote,
    # apostrophe, backslash, dot, space, semicolon, angle bracket, and the empty
    # string.
    #
    # DELIBERATELY NOT THE FULL ECMAScript GRAMMAR, which admits most of Unicode.
    # Widening it is a decision, not a bug fix — and it would have to be taken
    # together with the marking note on #validate! below, because the value's safety
    # under ERB is what the narrow set buys.
    PATTERN = /\A[A-Za-z_$][A-Za-z0-9_$]*\z/

    module_function

    # Return +value+ as a String, or raise ArgumentError naming +local+.
    #
    #     modal_store = Studio::JsIdentifier.validate!(
    #                     local_assigns.fetch(:modal_store, "modals"), local: :modal_store)
    #
    # +local+ is REQUIRED and has no default on purpose. Fifteen of the engine's
    # call sites name this local `modal_store` and two name it `store`; a default
    # that is right fifteen times out of seventeen is exactly how the other two
    # would hand a host the wrong local to go and fix.
    #
    # RETURNS A PLAIN STRING, NOT AN html_safe ONE, and that is load-bearing rather
    # than an omission. A value that satisfies PATTERN contains no character ERB
    # escapes, so ERB's pass over it is a byte-for-byte no-op and the identifier
    # reaches the browser exactly as the host wrote it — the marking would buy
    # nothing today. What it would cost is the day PATTERN is widened: ERB's
    # escaping is the second layer that would still be standing, and a value marked
    # safe here skips it. So the pattern is the only thing holding the line, and it
    # is holding it alone by choice, in one place.
    def validate!(value, local:)
      name = "#{value}"
      return name if name.match?(PATTERN)

      raise ArgumentError,
            "#{local} must be a JS identifier (it is spliced into $store.<name>); " \
            "got #{value.inspect}. Escaping it would not help — an escaped " \
            "identifier is a different SyntaxError, and the card would mount dead."
    end
  end
end
