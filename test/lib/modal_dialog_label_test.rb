# frozen_string_literal: true

require "bundler/setup"
ENV["RAILS_ENV"] ||= "test"
require_relative "../dummy/config/environment"
require "minitest/autorun"
require "active_support/test_case"

# [unit] dialogLabel's fallback chain, run as JavaScript.
#
# A dialog with no accessible name announces as just "dialog". The chain is
# ariaLabel -> title -> the humanised id, and the LAST rung is what makes the name
# unconditional: every entry has an id, so there is no path to an empty name. That
# is the property worth pinning, and it is pure logic — no browser needed, unlike
# the focus behaviour, which is only observable as document.activeElement.
class ModalDialogLabelTest < ActiveSupport::TestCase
  # Rails.root is the DUMMY app here, not the engine — the engine root is two up
  # from test/lib.
  HOST = File.expand_path("../../app/views/studio/modals/_host.html.erb", __dir__)

  def label_for(entry)
    src = File.read(HOST)
    body = src[/dialogLabel: function\(\) \{(.*?)\n        \},/m, 1]
    raise "dialogLabel not found in #{HOST}" unless body

    js = <<~JS
      const current = #{entry.nil? ? 'null' : JSON.generate(entry)};
      const store = { current: () => current, dialogLabel: function() {#{body}} };
      console.log(JSON.stringify(store.dialogLabel()));
    JS
    out = IO.popen(["node", "-e", js], &:read)
    raise "node failed: #{out}" unless $?.success?

    JSON.parse(out)
  end

  test "an explicit ariaLabel wins" do
    assert_equal "Wallet changed",
                 label_for({ id: "wallet-changed", props: { ariaLabel: "Wallet changed", title: "T" } })
  end

  test "a title is used when no ariaLabel is given" do
    assert_equal "Confirm entry", label_for({ id: "enter", props: { title: "Confirm entry" } })
  end

  test "the id is humanised as the last resort, so a name is never empty" do
    assert_equal "wallet changed", label_for({ id: "wallet-changed", props: {} }),
      "every entry has an id, which is what makes the accessible name unconditional"
  end

  test "no open modal still yields a name rather than undefined" do
    assert_equal "Dialog", label_for(nil)
  end
end
