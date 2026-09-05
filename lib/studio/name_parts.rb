# frozen_string_literal: true

module Studio
  # The two halves of a person's name, derived from the one string they typed.
  #
  # WHY THIS IS A PRIMITIVE AND NOT THREE LINES IN A CONTROLLER. Every Studio
  # host derives `first_name`/`last_name` from `name` in a `before_save`
  # (`set_name_parts` — byte-identical in mcritchie-studio and turf-monster), so
  # any writer that steps around callbacks owes the SAME derivation or the row
  # lands split differently depending on which door it came through. The engine
  # has exactly such a writer: Studio::OnboardingController writes with
  # `update_columns`, and it does so for a reason worth keeping (see there).
  # Parity is the whole requirement, so the rule lives in one named, tested
  # place instead of being retyped at each door.
  #
  # PURE ON PURPOSE — no record, no columns, no ActiveRecord. That is what lets
  # the engine's pure-Ruby unit lane exercise it directly, and what lets a host
  # callback delegate to it later without inheriting anything.
  #
  # `last_name` is OMITTED, not nil, for a one-word name. That is parity, not
  # tidiness: the host callback has always left an existing last name standing
  # (`self.last_name = parts.last if parts.size > 1`), so a hash that nulled it
  # would make the callback-free writer disagree with the callback in the
  # opposite direction — someone with a last name on file would lose it by
  # answering a first-name prompt. Whether that carry-over is itself the right
  # rule is a separate question from this one; matching it is this file's job.
  #
  # Mirrors mcritchie-studio's `User.name_parts`, which the hub extracted for its
  # own callback-free writers (seeds and the identity migrations). The engine
  # cannot call that one — it ships to hosts that do not define it, and
  # mcritchie-industries has no `first_name` column at all — so it carries its
  # own copy of a rule both must agree on. test/lib/studio/name_parts_test.rb
  # pins the parity for every shape of name.
  module NameParts
    module_function

    # A hash ready for `update_columns` / `assign_attributes`.
    #
    #   Studio::NameParts.from("Ada Lovelace")     # => { first_name: "Ada", last_name: "Lovelace" }
    #   Studio::NameParts.from("Ada")              # => { first_name: "Ada" }
    #   Studio::NameParts.from("Ada B. Lovelace")  # => { first_name: "Ada", last_name: "Lovelace" }
    #   Studio::NameParts.from("")                 # => { first_name: nil }
    def from(name)
      words = name.to_s.strip.split(" ")
      parts = { first_name: words.first }
      parts[:last_name] = words.last if words.size > 1
      parts
    end
  end
end
