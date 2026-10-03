# frozen_string_literal: true

# Guard: the footer's docs ship in the installed gem.
#
# WHY. Consumers cite docs/SITE_FOOTER.md from their own initializers as the
# footer's contract (rantly's config/initializers/studio.rb does), and the
# footer helper cites it and docs/BOOKING.md. The gemspec's `files` used to
# leave docs/ out entirely, so the citation pointed at nothing in the copy a
# consumer actually has. This reads the gemspec itself, from the engine root
# (its `files` are globs relative to the working directory).

require "bundler/setup"
require "minitest/autorun"
require "rubygems"

class GemspecShipsFooterDocsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHIPPED_DOCS = %w[docs/SITE_FOOTER.md docs/BOOKING.md].freeze

  def files
    Dir.chdir(ROOT) { Gem::Specification.load(File.join(ROOT, "studio-engine.gemspec")).files }
  end

  def test_the_footer_and_booking_docs_are_in_the_gem
    SHIPPED_DOCS.each do |doc|
      assert File.file?(File.join(ROOT, doc)), "#{doc} is gone from the repo"
      assert_includes files, doc, "#{doc} must ship in the gem: consumers cite it"
    end
  end

  # The rest of docs/ is the engine's own operating material, and stays out.
  def test_no_other_doc_rides_along
    assert_equal SHIPPED_DOCS.sort, files.grep(%r{\Adocs/}).sort
  end
end
