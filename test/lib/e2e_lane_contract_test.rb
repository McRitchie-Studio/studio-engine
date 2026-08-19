# frozen_string_literal: true

require "test_helper"
require "yaml"

# THE STATIC HALF of the browser lane's guard. bin/e2e-executed-set-check is the
# runtime half — it reads Playwright's own receipt and asserts what RAN. This file
# asserts the things a receipt cannot see, because they are properties of the
# committed source and configuration:
#
#   · the contract's arithmetic is internally consistent and matches the tree
#   · nothing in playwright.config.js or the CI command NARROWS the set
#   · no spec carries a selection modifier on any receiver
#   · the CI lane cannot be made conditional, and its verdict job cannot go quiet
#   · the lab pages render ENGINE partials, so the lane grades the engine not the lab
#
# WHY BOTH HALVES. The runtime gate catches a set that shrank; these catch the
# EDIT that would shrink it, at review time, with a message that names the property.
# Neither is sufficient: a static guard cannot see a runtime skip, and the runtime
# gate cannot see a `--grep` that has not run yet.
class E2eLaneContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONTRACT_PATH = File.join(ROOT, "config", "e2e_lane.yml")
  CONFIG_PATH = File.join(ROOT, "playwright.config.js")
  WORKFLOW_PATH = File.join(ROOT, ".github", "workflows", "engine-ci.yml")
  SPEC_GLOB = File.join(ROOT, "e2e", "*.spec.js")

  # Flags the CI command may carry. DEFAULT-DENY: anything else, and any positional
  # argument (a spec path), narrows the set. This is the FILTER axis that defeated
  # the hub's guard once — the ratchet bounded the tag and nothing bounded the flag
  # that consumed it.
  ALLOWED_FLAGS = %w[--reporter --shard].freeze
  VALUE_FLAGS = %w[--reporter --shard --grep --grep-invert --project --workers --config].freeze

  # Modifiers that do NOT remove a test from the set. Everything else on `test.`,
  # `it.` or `describe.` is refused BY NAME, including a modifier Playwright ships
  # next year — the point is that the guard does not have to have heard of it.
  INERT_MODIFIERS = %w[
    describe describe.configure beforeEach afterEach beforeAll afterAll use step
    setTimeout slow info
  ].freeze
  MODIFIER_CALL = /\b(?<callee>test|it|describe)\.(?<modifier>\w+(?:\.\w+)*)\s*\(/

  # RECEIVER-AGNOSTIC. `testInfo.skip()` and an aliased `const t = test; t.skip()`
  # are the same event as `test.skip()`, and anchoring on the receiver is exactly how
  # the hub's round-3 guard was walked past.
  SELECTION_VERBS = %w[only skip fixme fail].freeze
  SELECTION_CALL = /(?<receiver>[\w$()\].]+)\s*\.\s*(?<verb>#{Regexp.union(SELECTION_VERBS)})\s*\(/

  def contract = @contract ||= YAML.safe_load_file(CONTRACT_PATH)
  def config_source = @config_source ||= File.read(CONFIG_PATH)
  def workflow_source = @workflow_source ||= File.read(WORKFLOW_PATH)
  def spec_paths = @spec_paths ||= Dir.glob(SPEC_GLOB).sort

  # The spec files name every one of these tokens in their own prose. Strip comments
  # before scanning or the guard fires on its own documentation.
  def strip_comments(source)
    source.gsub(%r{/\*.*?\*/}m, "").gsub(%r{^\s*//.*$}, "")
  end

  def test_unit_the_contract_arithmetic_is_internally_consistent
    assert_equal contract.fetch("total_specs"), contract.fetch("executed"),
                 "this lane has NO quarantine, so every committed spec must execute. If these " \
                 "two numbers ever differ, an exclusion has appeared without a name."
    assert_operator contract.fetch("shards"), :>=, 1
    assert_operator contract.fetch("executed"), :>=, contract.fetch("shards"),
                    "more shards than specs guarantees an EMPTY shard, and an empty shard exits 0 " \
                    "silently — sharding suppresses Playwright's own 'No tests found' guard."
  end

  # THE CONTRACT MUST DESCRIBE THE TREE. Without this, adding a spec and forgetting
  # the contract leaves the runtime gate red for a reason nobody can act on; worse,
  # DELETING a spec would sail through with the contract quietly over-counting.
  def test_unit_the_contract_counts_the_specs_actually_committed
    declared = spec_paths.sum { |path| strip_comments(File.read(path)).scan(/^\s*test\s*\(/).size }

    assert_equal contract.fetch("total_specs"), declared,
                 "config/e2e_lane.yml says #{contract.fetch("total_specs")} spec(s); the tree " \
                 "holds #{declared}. Move total_specs AND executed in the same commit, then " \
                 "confirm with `npx playwright test --list`."
  end

  def test_unit_no_spec_carries_a_selection_modifier
    spec_paths.each do |path|
      source = strip_comments(File.read(path))
      name = File.basename(path)

      source.scan(MODIFIER_CALL) do
        modifier = Regexp.last_match[:modifier]
        next if INERT_MODIFIERS.include?(modifier)

        flunk "#{name} calls #{Regexp.last_match[:callee]}.#{modifier}(...). Only #{INERT_MODIFIERS.join(", ")} " \
              "are inert; anything else removes tests from the executed set."
      end

      source.scan(SELECTION_CALL) do
        flunk "#{name} calls #{Regexp.last_match[:receiver]}.#{Regexp.last_match[:verb]}(...). A selection verb " \
              "removes a spec from the lane whatever object it is called on — the receiver is " \
              "not the point, the verb is."
      end
    end
  end

  # A TEST THAT COUNTS CONSOLE ERRORS MUST ALSO CLOSE THE NETWORK.
  #
  # `watchPageErrors` fails a spec on any console.error, and a FAILED RESOURCE LOAD is
  # one. Every lab page links Montserrat from fonts.googleapis.com through
  # layouts/studio/_head, so a spec that counts console errors with the network open
  # fails on a slow or unreachable font — naming an assertion that had nothing to do
  # with fonts. Measured at 2 failures in 10 runs before the helper existed.
  #
  # WHY THIS IS A GUARD AND NOT FOUR EDITS. The helper was written for exactly this and
  # then applied only to the specs added AFTER it; the four older files kept counting
  # errors over an open network for months. Fixing them by hand fixes today and regresses
  # at spec #9. The property is structural, so it is asserted structurally.
  #
  # It is also the only honest way to test this. The failure is an INTERMITTENT network
  # event — it cannot be mutation-tested by reproducing it on demand. This CAN be:
  # delete the call from any spec and this reddens, deterministically.
  #
  # A block in the preamble (a `beforeEach`) covers every test in the file, and is the
  # RIGHT place when the file navigates there — a block installed inside a test body
  # would arrive after that navigation had already fetched the fonts.
  def test_unit_a_spec_that_counts_console_errors_closes_the_network
    spec_paths.each do |path|
      source = strip_comments(File.read(path))
      name = File.basename(path)

      # Chunk per `test(...)`. `test.describe(` / `test.beforeEach(` do not match — the
      # paren must follow the word — so both land in the preamble, which is what covers
      # a file-level block.
      chunks = source.split(/^\s*test\(/)
      preamble = chunks.first.to_s
      covered_file_wide = preamble.include?("blockOffsiteRequests(")

      chunks.drop(1).each_with_index do |body, index|
        next unless body.include?("watchPageErrors(")
        next if covered_file_wide || body.include?("blockOffsiteRequests(")

        title = body.lines.first.to_s.strip[0, 70] || "##{index + 1}"

        flunk "#{name}: the test \"#{title}\" counts console errors (watchPageErrors) but never " \
              "calls blockOffsiteRequests. Every lab page links Montserrat from a third party, so " \
              "this spec fails whenever that fetch is slow or unreachable — reporting it as a " \
              "failure of whatever it actually asserts. Add `await blockOffsiteRequests(page);` " \
              "before the navigation (or in a beforeEach if the file navigates there)."
      end
    end
  end

  def test_unit_playwright_config_does_not_narrow_the_test_set
    assert_match(/testDir:\s*["']\.\/e2e["']/, config_source,
                 "the lane must collect from ./e2e")

    %w[testIgnore testMatch grepInvert].each do |key|
      refute_match(/#{key}/, config_source, "#{key} in playwright.config.js narrows the executed set")
    end
    # `grep` on its own, but not as part of grepInvert (already refuted above).
    refute_match(/\bgrep\s*:/, config_source, "grep: in playwright.config.js narrows the executed set")
  end

  def test_unit_playwright_forbids_only_under_ci
    assert_match(/forbidOnly:\s*!!process\.env\.CI/, config_source,
                 "forbidOnly must be on under CI — a stray test.only would otherwise green the " \
                 "lane over one spec")
  end

  # THE LANE MUST RUN UNCONDITIONALLY. A job-level `if:` is the cheapest way to turn a
  # gate off while leaving a green check behind, and it reads as configuration rather
  # than as a decision.
  def test_integration_the_browser_lane_runs_unconditionally
    lane = workflow_job(workflow_source, "playwright")

    # FOUR SPACES EXACTLY — a JOB-level `if:`. Step-level conditions sit at eight and
    # are legitimate (the receipt upload is deliberately `if: always()`), so a looser
    # `\s{4,}` here would refuse the lane's own correct configuration.
    refute_match(/^ {4}if:/, lane, "the playwright job must carry no job-level `if:` — a conditional gate is an off switch")
    refute_match(/continue-on-error/, lane, "continue-on-error makes a red lane report green")
    assert_match(/playwright\s+test/, lane, "the playwright job must actually run the lane")
  end

  # `if: always()` IS LOAD-BEARING AND IS THE ONLY CONDITION THIS JOB MAY CARRY.
  # Without it a red `playwright` job makes `needs:` SKIP the verdict job — and a
  # skipped required check does not report failure, so the gate would go quiet at
  # exactly the moment it matters.
  def test_integration_the_verdict_job_cannot_go_quiet
    verdict = workflow_job(workflow_source, "e2e_executed_set")

    assert_match(/^ {4}if:\s*always\(\)/, verdict,
                 "e2e_executed_set must be `if: always()` at the JOB level; on `needs: playwright` " \
                 "alone a red lane SKIPS it, and a skipped check reports no failure")
    assert_match(/bin\/e2e-executed-set-check/, verdict)
  end

  def test_integration_the_ci_command_carries_no_narrowing_flag
    command = workflow_source[/npx playwright test[^\n]*/]
    refute_nil command, "could not find the playwright command in engine-ci.yml"

    tokens = command.sub(/\Anpx playwright test/, "").split
    until tokens.empty?
      token = tokens.shift
      unless token.start_with?("-")
        flunk "the CI command carries a positional argument (#{token}). A spec path narrows the " \
              "lane to that file and every other spec silently leaves the executed set."
      end

      flag = token.split("=").first
      assert_includes ALLOWED_FLAGS, flag,
                      "#{flag} is not on the allowlist #{ALLOWED_FLAGS.inspect}. Flags are " \
                      "DEFAULT-DENY here because narrowing the set is the failure this lane " \
                      "cannot see in its own green check."
      tokens.shift if VALUE_FLAGS.include?(flag) && !token.include?("=")
    end
  end

  # The lane is judged on a receipt, so the receipt must exist. `--reporter=json`
  # alone writes to STDOUT and no file is produced; PLAYWRIGHT_JSON_OUTPUT_NAME is
  # what turns it into an artifact the verdict job can read.
  def test_integration_the_lane_emits_the_receipt_it_is_judged_on
    lane = workflow_job(workflow_source, "playwright")

    assert_match(/--reporter[= ]\S*\bjson\b/, lane, "the lane must emit a JSON report")
    assert_match(/PLAYWRIGHT_JSON_OUTPUT_NAME/, lane,
                 "without PLAYWRIGHT_JSON_OUTPUT_NAME the json reporter writes to stdout and no " \
                 "receipt file exists for bin/e2e-executed-set-check to read")
    assert_match(/if:\s*always\(\)/, lane,
                 "the receipt upload must be `if: always()` — a FAILING spec still ran, and the " \
                 "executed-set gate must count it")
  end

  # THE INVARIANT THAT KEEPS THE LANE HONEST. The lab pages exist to host ENGINE
  # partials. The moment a lab page hand-rolls what a partial does — its own sticky
  # header, its own copy of the re-stamper — the specs start grading the lab, and the
  # lane reports green over engine code no browser touched. That failure would be
  # invisible: every spec still passes.
  def test_integration_the_lab_pages_render_engine_partials
    lab = File.join(ROOT, "test", "dummy", "app", "views", "e2e_lab")

    {
      "bar_stack.html.erb" => ["studio/banners/stack", "layouts/navbar"],
      "at_time.html.erb" => ["studio/at_time_script"],
      # THE SAVE CONTROLS ARE NO LONGER NAMED ON THE READ PAGE, and the reason is
      # the change itself: they used to be a bar fixed across the bottom of the
      # viewport, which any page could render, and they now live INSIDE the
      # editable identity card. The read lab renders identity with editable
      # false, so it has nothing to save and nothing to name — every save-control
      # spec moved to profile_edit.html.erb, which is where that card lives.
      #
      # The naming rule itself still earns its keep for the rest: a lab page that
      # reimplements a partial turns its spec into a test of the lab page.
      "profile.html.erb" => [
        "studio/profiles/identity", "studio/profiles/name_fields",
        "studio/profiles/form_script",
        # The modal host is named here because the lane's sharpest finding lives
        # in how it is MOUNTED: it declares no x-data of its own, so a page that
        # renders it outside an Alpine scope gets a store that opens and a dialog
        # that never appears.
        "studio/modals/scoped_host"
      ],
      # editable_identity is what carries the save controls now — it renders
      # studio/profiles/identity, which renders studio/profiles/save_controls into
      # both the card and the compact bar. Naming editable_identity is therefore
      # enough, and naming save_controls directly would be WRONG: this lab must
      # not mount them itself, because where they mount is exactly what is under
      # test.
      "profile_edit.html.erb" => [
        "studio/cropper_assets", "studio/profiles/editable_identity",
        "studio/profiles/birthday_fields", "studio/profiles/name_fields",
        "studio/profiles/form_script"
      ]
    }.each do |page, partials|
      source = File.read(File.join(lab, page))

      partials.each do |partial|
        assert_match(/render\s+"#{Regexp.escape(partial)}"/, source,
                     "#{page} must render the engine partial #{partial} BY NAME. A lab page that " \
                     "reimplements the partial turns its spec into a test of the lab.")
      end

      refute_match(/<script/, source,
                   "#{page} carries its own <script>. The browser program under test must come " \
                   "from the ENGINE partial, never from the lab page around it.")
    end
  end

  # NO PATH FILTER ON THE GATING TRIGGERS — the subtler spelling of the same hole.
  #
  # Adding `paths:` is the obvious way to make CI cheaper, and docs/E2E_LANE.md
  # already refused it for the browser lane on two grounds: a path-filtered
  # required check reports SKIPPED rather than passed, and predicting from paths
  # which changes affect behaviour is the inference this codebase declines to make.
  #
  # It is worse HERE than in the general case, and worth its own guard rather than
  # prose. The commit the G3 gate most needs a verdict for is a gem release's
  # version bump, and that commit touches exactly `lib/studio/version.rb` and
  # `Gemfile.lock` — nothing else. Any filter written around app or view paths
  # skips precisely that commit, the gate finds no check-run, and the release
  # aborts exactly as it did on 2026-08-15. The trigger would still say `release`;
  # the hole would just be harder to see.
  def test_unit_the_gating_triggers_carry_no_path_filter
    %w[engine-ci.yml consumer-ci.yml].each do |file|
      triggers = File.read(File.join(ROOT, ".github", "workflows", file))[/^on:\n(?:.*\n)*?(?=^jobs:)/]

      refute_match(/^\s*paths(-ignore)?:/, triggers.to_s,
                   "#{file} filters its triggers by path. A gem release's version commit touches " \
                   "only lib/studio/version.rb and Gemfile.lock, so a path filter skips the very " \
                   "SHA the G3 gate polls for — and a skipped required check reports no failure.")
    end
  end

  # THE RELEASE BRANCH MUST BE BUILDABLE, in every workflow that gates a release.
  #
  # The G3 pre-QA gate reads GitHub CI's conclusion for the RELEASE SHA and fails
  # closed on anything but green. A gem release pushes a version + Gemfile.lock
  # commit DIRECTLY onto `release` — not a pull_request — so with `push` limited
  # to `main` that SHA gets no run at all, and the gate polls for a verdict that
  # can never exist.
  #
  # Measured 2026-08-15: `gh run list --branch release` returned ZERO runs in this
  # repo's entire history, `f339f45` (the 0.50.0 version commit) had 0 check-runs,
  # and the release aborted after ~1200s of polling WITH THE GEM ALREADY PUBLISHED
  # to RubyGems. The promote PR that produced that tree was green on all six
  # checks, so nothing was wrong with the code — only with what CI was watching.
  #
  # Asserted for BOTH workflows because the gate reads the SHA's whole check set,
  # not one lane, so either one reverting reopens the hole.
  def test_integration_every_gating_workflow_builds_the_release_branch
    { "engine-ci.yml" => "the engine suite", "consumer-ci.yml" => "the consumer suites" }.each do |file, what|
      path = File.join(ROOT, ".github", "workflows", file)
      triggers = File.read(path)[/^on:\n(?:.*\n)*?(?=^jobs:)/]

      refute_nil triggers, "#{file} has no `on:` block above `jobs:`"
      assert_match(/^\s*branches:.*\brelease\b/, triggers,
                   "#{file} does not build `release`, so #{what} produces NO check-run for a " \
                   "release SHA — and the G3 gate, which fails closed on a missing verdict, " \
                   "can never pass. A gem's version commit reaches `release` outside a PR.")
    end
  end

  # THE `accepted` RUNG MUST BE BUILDABLE — by the DECLARED suite workflow.
  #
  # Scoped to engine-ci.yml alone, and the scope is the point rather than an omission.
  # Ci::BranchGate resolves this repo's verdict through its DECLARED suite workflow
  # name ("Engine CI"), never "any run on the branch" — a rule added after an unrelated
  # downstream run once authorised a merge on its own. So Consumer CI building
  # `accepted` would not make this repo certified, and its absence does not make it
  # blind. Whether the consumer matrix should build the rung is a separate question
  # about consumer coverage, deliberately not settled here.
  #
  # WHAT WENT WRONG WITHOUT IT. `bin/release prepare` refuses to promote a RED
  # `accepted` (refuse_red_accepted!). With no run on this branch the verdict resolved
  # to :none, which by design does not block — refusing on an absent verdict would
  # wedge the release lane on every race. The guard therefore passed over studio-engine
  # in every release without ever having been CAPABLE of failing, while naming it as
  # checked. Measured 2026-08-18, task certify-accepted-everywhere.
  def test_integration_the_declared_suite_workflow_builds_the_accepted_branch
    triggers = File.read(File.join(ROOT, ".github", "workflows", "engine-ci.yml"))[/^on:\n(?:.*\n)*?(?=^jobs:)/]

    refute_nil triggers, "engine-ci.yml has no `on:` block above `jobs:`"
    assert_match(/^\s*branches:.*\baccepted\b/, triggers,
                 "engine-ci.yml does not build `accepted`. Review merges several approved PRs onto " \
                 "that branch, producing a combination no run has executed — a pull_request run only " \
                 "ever built its own head against the base AS IT THEN STOOD. Without this trigger the " \
                 "sweep's accepted guard reads :none for this repo and silently loses the ability to " \
                 "fail at all.")
  end

  # No quarantine, and no quiet arrival of one. The concept is refused in the
  # contract, the config and the CI command at once, because it only takes one of the
  # three to reintroduce an exclusion.
  def test_unit_the_lane_has_no_quarantine_concept
    refute contract.key?("quarantined"),
           "this lane has no quarantine — see the argument in config/e2e_lane.yml"
    refute contract.key?("quarantine_tag")
    refute_match(/grep-invert/, workflow_source,
                 "--grep-invert is the quarantine's delivery mechanism; there is nothing here to " \
                 "exclude")
  end

  private

  # Slice one job out of the workflow by its two-space-indented key.
  def workflow_job(source, name)
    job = source[/^  #{Regexp.escape(name)}:\n(?:.*\n)*?(?=^  \w|\z)/]
    refute_nil job, "no `#{name}` job in engine-ci.yml"
    job
  end
end
