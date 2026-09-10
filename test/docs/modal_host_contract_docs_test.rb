# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] The modal host's DOCUMENTED CONTRACT, pinned to the artifacts it makes
# claims about.
#
# README.md's "Writing a modal's content partial" subsection states two rules the
# host imposes, and — since /tasks/modal-host-readme-misstates — states WHY they
# are recorded in the host's own docs rather than in the style guide's specimen
# headers. That "why" used to be two measurably false sentences (the rules were
# never specimen-only, and retiring two engine mirrors removed nothing from
# turf-monster, whose own _network_guard and _wallet_deposit state neither rule;
# turf states both rules elsewhere, just not in those two cards). They were
# replaced with a reason that is checkable, and this file is where it gets
# checked.
#
# WHY A DOC TEST AT ALL. A README that states a rule is exactly where a grep
# proves nothing: the prose can be edited into a lie and every behavioural test
# stays green. So this guard does NOT assert that the prose says particular
# words where it can avoid it. It asserts the FACTS THE PROSE RESTS ON, in the
# files that carry them:
#
#   1. the style guide wraps every registration in its own <div>  (the reason
#      the rules cannot live in specimen headers)
#   2. the vendored Alpine really does log for rule 2 and really is silent for
#      rule 1                                                     (the failure
#      modes the subsection describes)
#   3. the rule is stated in SHIPPED files, not only in deletable specimens
#
# Only the three doc sites' shared claim (the console error) is pinned as prose,
# and deliberately: the same false "both fail silently" sentence shipped in
# THREE files at once, so fixing one and leaving two is the live failure mode.
class ModalHostContractDocsTest < Minitest::Test
  ROOT        = File.expand_path("../..", __dir__)
  GUIDE       = File.join(ROOT, "app/views/style/_modals.html.erb")
  ALPINE      = File.join(ROOT, "app/assets/javascripts/studio/alpine.js")
  README      = File.join(ROOT, "README.md")
  HOST        = File.join(ROOT, "app/views/studio/modals/_host.html.erb")
  SCOPED_HOST = File.join(ROOT, "app/views/studio/modals/_scoped_host.html.erb")

  # ERB comments never reach the page, and the guide DISCUSSES registrations in
  # prose (including the shape of one). Scanning a comment would report a
  # sentence as a registration.
  def guide_body
    @guide_body ||= File.read(GUIDE).gsub(/<%#.*?%>/m, "")
  end

  # Every `<template x-if="$store.dsModals.current().id === '…'">` in the guide,
  # as [id, first_root_tag].
  #
  # The first root is found by walking forward from the template's opening tag to
  # the first ELEMENT, skipping whitespace and ERB output tags — not by reading
  # the next line, which would break the first time someone reflowed the file.
  def registrations
    body = guide_body
    body.to_enum(:scan, /<template\s+x-if="\$store\.dsModals\.current\(\)\.id\s*===\s*'([a-z0-9-]+)'\s*">/)
        .map do
      id    = Regexp.last_match(1)
      rest  = body[(Regexp.last_match.end(0))..]
      # Skip whitespace and any ERB tags that precede the first element.
      rest  = rest.sub(/\A(?:\s|<%[^%]*%>)*/m, "")
      [id, rest[/\A<([a-zA-Z][a-zA-Z0-9-]*)/, 1]]
    end
  end

  # ---- non-vacuity control -------------------------------------------------
  #
  # Every assertion below is a property of a scan. If the scan silently matched
  # nothing — a reflow, a renamed store, a changed quote style — they would all
  # pass while checking nothing at all.
  def test_the_registration_scan_actually_reads_the_guide
    refute_empty guide_body, "stripped the guide down to nothing"
    assert_operator registrations.length, :>=, 20,
                    "expected the guide to register many modals; the scan found " \
                    "#{registrations.length}, so it has stopped matching"
  end

  # ---- 1. the reason the rules cannot live in specimen headers --------------
  #
  # THE LOAD-BEARING ONE. README.md tells a partial author that their outer
  # <div> is the host's required root, and explains that a specimen could not
  # document this rule because the guide supplies that root itself. That is only
  # true while every registration really does wrap its render.
  #
  # It is also a real invariant in its own right: drop one wrapper and that
  # specimen's own root silently becomes load-bearing, so a specimen that broke
  # the single-root rule would start failing IN THE GUIDE — the exact coupling
  # the README says does not exist.
  def test_every_registration_wraps_its_partial_in_an_explicit_div
    unwrapped = registrations.reject { |(_id, tag)| tag == "div" }

    assert_empty unwrapped.map { |(id, tag)| "#{id} → #{tag.inspect}" },
                 "every <template x-if> registration in app/views/style/_modals.html.erb must wrap " \
                 "its render in an explicit <div>. That wrapper is what supplies the single root " \
                 "Alpine's x-if clones, and README.md's \"Writing a modal's content partial\" cites " \
                 "it as the reason the host's rules cannot be documented in specimen headers. " \
                 "Un-wrapping one makes that specimen's own root load-bearing and the README wrong."
  end

  # ---- 2. the failure modes the subsection describes ------------------------
  #
  # Rule 2 LOGS. The subsection sends a debugging engineer to the console for a
  # truncated x-data, which is only good advice while Alpine's default error
  # handler still warns. It is the handler in the VENDORED build (3.16.1) that
  # decides this, so the assertion is against the file that actually ships.
  def test_vendored_alpine_logs_an_expression_error_through_console_warn
    src   = File.read(ALPINE)
    index = src.index("Alpine Expression Error")

    refute_nil index,
               "vendored Alpine no longer contains the 'Alpine Expression Error' handler. " \
               "README.md and both modal hosts tell readers to look for that string in the " \
               "console when an x-data is truncated; if it is gone, they are sending people " \
               "to a console that says nothing."
    assert_includes src[[index - 40, 0].max...index], "console.warn",
                    "'Alpine Expression Error' is no longer emitted through console.warn"
  end

  # Rule 1 is SILENT — and the subsection explains that Alpine warns for the
  # multi-root case it does NOT apply here (x-for), which is why the x-if case
  # catches people out. Both halves are asserted: if a future Alpine adds an
  # x-if root check, rule 1 stops being silent and the docs need revisiting.
  def test_vendored_alpine_warns_for_multi_root_x_for_but_not_for_x_if
    src = File.read(ALPINE)

    assert_includes src, "x-for templates require a single root element",
                    "the x-for multi-root warning README.md contrasts against is gone"
    refute_match(/x-if\s+templates?\s+require\s+a\s+single\s+root/i, src,
                 "Alpine now checks x-if for multiple roots too, so the single-root rule is no " \
                 "longer the silent failure README.md and both hosts describe. Re-read the docs.")

    # The x-if handler clones firstElementChild and asks no questions — that IS
    # the silence. Anchored on the directive's own error string so the slice
    # cannot drift onto another handler.
    marker  = src.index("x-if can only be used on a <template> tag")
    refute_nil marker, "could not locate Alpine's x-if handler"
    assert_includes src[marker, 400], "firstElementChild",
                    "Alpine's x-if handler no longer takes firstElementChild"
  end

  # ---- 3. the rule was never confined to deletable specimens ---------------
  #
  # The retired claim was that the two rules "used to be recorded only in the
  # style guide's specimen headers, which made them deletable by a change that
  # removed a specimen". Asserted as a FLOOR, not a count: the exact census
  # moves with every specimen retirement, and a number in a test is a number
  # that goes stale. What matters is that shipped, non-deletable files state it.
  def test_the_single_root_rule_is_stated_in_shipped_files_not_only_specimens
    shipped = Dir[File.join(ROOT, "app/views/studio/**/*.erb"),
                  File.join(ROOT, "app/assets/javascripts/studio/*.js")]
              .select { |f| File.read(f).match?(/single[-\s]root/i) }
              .map    { |f| f.delete_prefix("#{ROOT}/") }

    refute_empty shipped,
                 "no SHIPPED file states the single-root rule any more. README.md's reasoning " \
                 "assumes the rule is stated in many places that each describe themselves, none " \
                 "of them the contract — if it is now specimen-only, the retired claim has " \
                 "become true and the subsection needs rewriting."
  end

  # ---- 4. the interpolated-quote vector, and the guard that is NOT the guard -
  #
  # README.md now tells a partial author that plain `<%= value %>` is what keeps
  # an interpolated double quote from closing `x-data`, and that
  # `escape_javascript` (`j`) is NOT that guard because it escapes for a
  # JavaScript string literal AND preserves the html_safe flag.
  #
  # That is the opposite of the obvious guess, and the review of this very task
  # proposed the obvious guess. A prose claim that a domain expert has already
  # got backwards once is exactly the claim that needs pinning, so the three
  # interpolation paths are asserted against ActionView itself.
  def test_plain_interpolation_escapes_the_quote_but_j_and_raw_do_not
    require "action_view"
    helper = Object.new.extend(ActionView::Helpers::JavaScriptHelper)
    value  = %(say "hi")

    assert_equal "say &quot;hi&quot;", ERB::Util.html_escape(value),
                 "plain <%= value %> no longer escapes a double quote to &quot;, so the README's " \
                 "advice to let Rails escape it is wrong"

    assert_equal %(say "hi"), ERB::Util.html_escape(value.html_safe),
                 "an html_safe value no longer reaches the attribute raw; re-read the README's " \
                 "raw/.html_safe vector"

    escaped = helper.escape_javascript(value.html_safe)
    assert_predicate escaped, :html_safe?,
                     "escape_javascript no longer preserves the html_safe flag, so it may now be " \
                     "a valid guard for x-data after all — the README says it is not"
    assert_includes ERB::Util.html_escape(escaped), %("),
                    "escape_javascript output no longer puts a bare double quote into the " \
                    "attribute. README.md tells authors j() will NOT save them; if it now does, " \
                    "that paragraph needs rewriting."
  end

  # ---- the one prose claim worth pinning -----------------------------------
  #
  # PR #311 shipped "both of these fail silently" into README.md, _host and
  # _scoped_host simultaneously. It was false in all three (rule 2 logs), and
  # correcting one file while leaving the others is how a repo ends up with two
  # answers to one question. So all three are pinned together, positively: each
  # must name the console error a reader is being sent to look for.
  def test_all_three_doc_sites_name_the_console_error
    { "README.md"                                     => README,
      "app/views/studio/modals/_host.html.erb"        => HOST,
      "app/views/studio/modals/_scoped_host.html.erb" => SCOPED_HOST }.each do |label, path|
      assert_includes File.read(path), "Alpine Expression Error",
                      "#{label} describes the host's two rules but no longer names the " \
                      "'Alpine Expression Error' the second one logs. All three sites state " \
                      "these rules; a reader who lands on this one must not be told the " \
                      "failure is silent when the console says otherwise."
    end
  end
end
