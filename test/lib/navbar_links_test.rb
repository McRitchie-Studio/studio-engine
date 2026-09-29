# frozen_string_literal: true

require "test_helper"

# Resolution rules for Studio.navbar_links (lib/studio/navbar_links.rb).
class NavbarLinksTest < Minitest::Test
  Request = Struct.new(:path)
  PathView = Struct.new(:path, :user) do
    def request = Request.new(path)
  end
  BareView = Struct.new(:name)

  def resolve(declared, path: "/contests")
    Studio::NavbarLinks.resolve(declared, PathView.new(path, "pat"))
  end

  def test_default_config_resolves_empty
    assert_equal [], Studio.navbar_links
    assert_equal [], Studio.navbar_links_for(BareView.new("x"))
  end

  def test_static_list_normalizes_to_the_four_keys
    resolved = resolve([{ "label" => "Contests", "href" => "/contests", "badge" => "#12" }])

    assert_equal [{ label: "Contests", href: "/contests", active: true, badge: "#12" }], resolved
  end

  def test_callable_receives_the_view_so_a_badge_can_read_the_user
    config = ->(view) { [{ label: "Rank", href: "/rank", badge: "for #{view.user}" }] }

    assert_equal "for pat", resolve(config).first[:badge]
  end

  def test_nil_and_empty_resolve_empty
    assert_equal [], resolve(nil)
    assert_equal [], resolve([])
    assert_equal [], resolve(->(_) {})
  end

  def test_active_accepts_bool_regexp_and_lambda
    links = [
      { label: "A", href: "/a", active: true },
      { label: "B", href: "/b", active: false },
      { label: "C", href: "/c", active: %r{\A/contests} },
      { label: "D", href: "/d", active: %r{\A/nope} },
      { label: "E", href: "/e", active: ->(path) { path.start_with?("/con") } }
    ]

    assert_equal [true, false, true, false, true], resolve(links).map { |l| l[:active] }
  end

  def test_omitted_active_matches_the_href_path_exactly
    links = [{ label: "Here", href: "/contests?tab=open" }, { label: "Home", href: "/" }]

    assert_equal [true, false], resolve(links).map { |l| l[:active] }
  end

  def test_view_without_a_request_is_never_active_by_match
    links = [{ label: "Home", href: "/", active: %r{/} }, { label: "Also", href: "/" }]

    assert_equal [false, false], Studio::NavbarLinks.resolve(links, BareView.new("x")).map { |l| l[:active] }
  end

  def test_blank_badge_is_nil_and_numeric_badge_is_text
    resolved = resolve([{ label: "A", href: "/a", badge: "" }, { label: "B", href: "/b", badge: 12 }])

    assert_equal [nil, "12"], resolved.map { |l| l[:badge] }
  end

  def test_bad_entries_raise_naming_the_index_and_the_problem
    {
      [{ href: "/a" }] => /navbar_links\[0\].*:label/,
      [{ label: "A" }] => /navbar_links\[0\].*:href/,
      [{ label: "A", href: "/a" }, "Home"] => /navbar_links\[1\].*Hash/,
      [{ label: "A", href: "/a", icon: "x" }] => /navbar_links\[0\].*unknown key :icon/,
      [{ label: "A", href: "/a", active: "yes" }] => /navbar_links\[0\].*:active/,
      [{ label: "A", href: "/a", badge: [1] }] => /navbar_links\[0\].*:badge/,
      { label: "A", href: "/a" } => /Array or a callable/,
      ->(_) { { label: "A", href: "/a" } } => /Array/
    }.each do |declared, message|
      error = assert_raises(Studio::NavbarLinks::InvalidLink, declared.inspect) { resolve(declared) }
      assert_match message, error.message
    end
  end

  def test_validate_checks_a_static_list_without_a_request
    assert_nil Studio::NavbarLinks.validate!([{ label: "A", href: "/a", active: /a/ }])
    assert_nil Studio::NavbarLinks.validate!(->(_) { raise "not called" })
    assert_raises(Studio::NavbarLinks::InvalidLink) { Studio::NavbarLinks.validate!([{ label: "A" }]) }
  end
end
