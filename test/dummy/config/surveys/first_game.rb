# The dummy app's survey, defined exactly where a consuming app defines one:
# config/surveys/*.rb, which the engine loads on boot (Studio.survey_definitions_path).
# The browser lane (e2e/survey_flow.spec.js) walks it; the integration suites
# reset the registry and define their own.
Studio.define_survey "first-game" do
  title "How was your first game?"
  intro "Six quick questions about your first game. Your answers shape what we build next."
  thank_you "We read every single answer."
  next_action label: "Play another game", url: "/"
  allow_anonymous true

  emoji_scale :overall, "How was your first game?", required: true
  rating :rules, "How clear were the rules?", low_label: "Lost", high_label: "Crystal clear"
  choice :found_us, "How did you find us?", options: ["An email from us", "A friend", "Search", "Somewhere else"]
  multi_choice :liked, "What did you enjoy?", options: ["The board", "The pace", "The art", "Playing a friend"]
  short_text :one_word, "Describe it in one word."
  long_text :anything_else, "Anything else we should know?", help: "Bugs, ideas, complaints — all welcome."
end
