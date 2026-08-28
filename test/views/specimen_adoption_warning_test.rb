# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"

# [unit] The primitives an app adopts must warn that a SPECIMEN'S VALUES are not
# the app's. Filed twice before this and archived unbuilt both times, so it is
# pinned rather than left to a reviewer noticing prose went missing.
#
# The incident: an adopter took U+1F39F from style/modals/_ds_wallet_topup onto a
# rail whose markup had always drawn U+1F3AB, and it landed on the primary CTA of
# the web2 kill-switch face of Top Up Wallet. CI was 6/6 green; no assertion
# pinned the glyph. Caught only by rendering before and after.
class SpecimenAdoptionWarningTest < Minitest::Test
  BLOCKS = %w[
    app/views/studio/modals/blocks/_rail_row.html.erb
    app/views/studio/modals/blocks/_close_x.html.erb
  ].freeze

  def test_each_adoptable_block_warns_that_specimens_show_structure_not_content
    BLOCKS.each do |path|
      doc = File.read(path)[/\A<%#(.*?)%>/m, 1].to_s

      assert_includes doc, "SPECIMENS SHOW STRUCTURE, NOT CONTENT",
                      "#{path}: the adoption warning is missing from its doc comment"
      # Asserted inside the DOC COMMENT, not the file: the warning is only useful
      # where an adopter reads the locals, and a match anywhere in the file would
      # stay green with the paragraph moved somewhere nobody looks.
      assert_includes doc, "take every VALUE", "#{path}: the warning lost its instruction"
    end
  end

  def test_the_warning_names_the_incident_that_earned_it
    # This codebase's hard-won comments name their incident. A rule with no
    # story gets deleted by the next person who finds it verbose.
    BLOCKS.each do |path|
      doc = File.read(path)[/\A<%#(.*?)%>/m, 1].to_s

      assert_includes doc, "U+1F3AB", "#{path}: the warning should name the glyph incident"
    end
  end
end
