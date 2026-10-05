# Surveys

A survey primitive every Studio app can run: define a survey in app code, send
people a link, and read the results in an admin panel. The respondent gets one
question per screen with a progress bar, big tap targets, keyboard shortcuts,
autosave and resume. Sending is not part of the engine: an app emails the link
itself (for now, through an agentic SOP).

| Piece | Where |
|-------|-------|
| Definition DSL and registry | `lib/studio/survey.rb` (`Studio.define_survey`, `Studio.surveys`, `Studio.survey`) |
| Results arithmetic, CSV | `lib/studio/survey/breakdown.rb`, `lib/studio/survey/export.rb` |
| Storage | `Studio::SurveyResponse`, table `studio_survey_responses` |
| Public pages | `Studio::SurveysController`, `app/views/studio/surveys/` |
| Admin panel | `Studio::AdminSurveysController`, `app/views/studio/admin_surveys/` |

## Adopt it in an app

1. Install the table and migrate:

   ```bash
   bin/rails studio_engine:install:migrations && bin/rails db:migrate
   ```

   Install them all with the task; never hand-copy the migration (a second copy
   raises `DuplicateMigrationNameError` on every `db:migrate`).

2. Turn on the routes in `config/initializers/studio.rb`. Both are off by
   default, because a route name the app already owns raises while its
   `routes.rb` loads and takes every route down with it:

   ```ruby
   Studio.configure do |config|
     config.draw_survey_routes = true        # /surveys/:slug
     config.draw_admin_survey_routes = true  # /admin/surveys
   end
   ```

3. Define a survey in `config/surveys/<name>.rb` (below).

4. Optionally wire the two hooks (below), and link the admin page from the
   app's admin sidebar:

   ```ruby
   { label: "Surveys", href: admin_surveys_path, emoji: "📋", desc: "Survey results" }
   ```

## Define a survey

Every `*.rb` under `config/surveys/` (`Studio.survey_definitions_path`) is loaded
at boot and again on each development reload. A definition is plain Ruby, so
one may also live in an initializer.

```ruby
# config/surveys/first_game.rb
Studio.define_survey "first-game" do
  title "How was your first game?"
  intro "Six quick questions. Your answers shape what we build next."
  thank_you "We read every single answer."
  next_action label: "Play another game", url: "/play"
  allow_anonymous true

  emoji_scale  :overall, "How was your first game?", required: true
  rating       :rules, "How clear were the rules?", low_label: "Lost", high_label: "Crystal clear"
  choice       :found_us, "How did you find us?", options: ["An email from us", "A friend", "Search", "Somewhere else"]
  multi_choice :liked, "What did you enjoy?", options: ["The board", "The pace", "The art"]
  short_text   :one_word, "Describe it in one word."
  long_text    :anything_else, "Anything else?", help: "Bugs, ideas, complaints — all welcome."
end
```

The slug is the URL: this survey lives at `/surveys/first-game`. Slugs are
lowercase words joined by hyphens; question keys are lowercase snake_case.

### Survey settings

| Setting | Meaning |
|---------|---------|
| `title` | Required. The intro heading and the page title |
| `intro` | Optional text under the title on the first screen |
| `thank_you` | The thank-you screen's copy (default "We appreciate you taking the time."), under a "Thank you!" heading |
| `next_action label:, url:` | Optional button on the thank-you screen. `url` is a `/path` or an `http(s)` URL |
| `allow_anonymous` | Let anyone answer. Off by default (see *Who may answer*) |
| `version` | Optional explicit version string; defaults to a digest of the questions |

### Question types

Every question takes a key, a label, `required:` (default `false`) and an
optional `help:` line.

| Type | Answer stored | Extra options |
|------|---------------|---------------|
| `emoji_scale` | 1–5, five faces | `labels:` five captions (default Awful … Loved it) |
| `rating` | 1–5 | `low_label:`, `high_label:` |
| `choice` | one option value | `options:` (two or more) |
| `multi_choice` | an array of option values | `options:` (two or more) |
| `short_text` | text, up to 280 characters | `max_length:`, `placeholder:` |
| `long_text` | text, up to 5,000 characters | `max_length:`, `placeholder:` |

An option is a label (`"A friend"`, value `a_friend`), a `[value, label]` pair or
`{ value:, label: }`. A definition that breaks a rule (a duplicate key, one
option, a `javascript:` next action, an unknown keyword) raises
`Studio::Survey::DefinitionError` at boot, so a bad survey never reaches a
respondent.

### Changing a survey later

Edit the definition freely. Each stored answer carries its own question key,
type, question label and chosen option label, and each response records the
version it was taken under, so old responses keep saying what the respondent was
actually asked. In the admin panel an answer whose option was later removed
still counts, marked *(retired)*, and the CSV keeps a column for a question key
the definition no longer has.

## The respondent's experience

- **One question per screen** with a progress bar, Back and Next. The first
  screen is the intro with a Start button.
- **Tap to answer**: a tap on a face, a number or an option saves it and moves
  on. Multiple choice and text wait for Next.
- **Keyboard**: number keys choose an option (and toggle one in multiple choice),
  Enter continues, Ctrl/⌘+Enter continues from a long-text box. Arrow keys move
  within a group and never skip ahead.
- **Autosave and resume**: each answer is saved as it is given. A respondent who
  leaves and comes back lands on their first unanswered question.
- **Accessible**: each question is a `fieldset` whose `legend` takes focus on
  every step, errors are announced, a required question says so, and
  `prefers-reduced-motion` turns the transitions off.
- **Theme**: it follows the app's theme tokens in dark and light mode.
- **Without JavaScript** every question shows in one form with a Submit button,
  and the server applies the same rules.
- A finished respondent who opens the link again sees the thank-you screen.

## Who may answer

A visitor may answer when ANY of these holds:

1. they are signed in (`current_user`); the response records their `user_id`;
2. they arrived by an attributed email link (`Studio.survey_ref_resolver`
   returns a ref); the response records it as `email_ref`;
3. the survey says `allow_anonymous true`.

Anyone else is asked to sign in. Anonymous answers are tied to the browser
session, so a refresh resumes rather than starting over, and a visitor who signs
in mid-survey keeps their answers.

The database allows one in-progress response per user, and per session, for each
survey. A response row is created at the first answer, never on a page view, so
a link-preview bot or a bounce is not counted as *started*. No IP address or raw
user agent is stored; `user_agent_class` is `mobile`, `tablet`, `desktop`, `bot`
or `unknown`.

## Hooks

```ruby
Studio.configure do |config|
  # Attribution for email arrivals: return the app's ref string, or nil.
  config.survey_ref_resolver = ->(controller) { controller.params[:ref].presence || controller.session[:email_ref] }

  # Runs once, after a response completes.
  config.on_survey_completed = ->(response) { GoalBeacon.fire("survey_completed", ref: response.email_ref) }
end
```

- `survey_ref_resolver` is called on every survey request; its value is stamped
  on the response the first time one is present.
- `on_survey_completed` receives the `Studio::SurveyResponse` (`survey_slug`,
  `answers`, `user`, `email_ref`, `completed_at`).
- A hook that raises is logged to `ErrorLog` and swallowed. The respondent still
  sees the thank-you screen.

## The admin panel

Admin-only (the engine's `require_admin`). With
`config.draw_admin_survey_routes = true`:

| Route | Helper | Shows |
|-------|--------|-------|
| `GET /admin/surveys` | `admin_surveys_path` | Every survey: started, completed, completion rate |
| `GET /admin/surveys/:slug` | `admin_survey_path(slug)` | Per-question breakdown |
| `GET /admin/surveys/:slug/export` | `admin_survey_export_path(slug)` | The same responses as CSV |

- Emoji, rating and choice questions show a distribution bar per option, as a
  percentage of the people who answered that question; scales show the average.
  Multiple-choice percentages are of respondents, so they can add up to more
  than 100%.
- Text questions list every answer, newest first, with the respondent's username
  or "anonymous" and the date.
- Filters: a start and end date (on when the response started, inclusive) and
  *Completed only*. The CSV export carries the filters.
- The CSV has one row per response: id, version, status, timestamps, respondent,
  user id, email ref, device class, then one column per question key. Cells a
  spreadsheet would run as a formula are prefixed with an apostrophe.

## Public routes

| Route | Helper |
|-------|--------|
| `GET /surveys/:slug` | `studio_survey_path(slug)` |
| `POST /surveys/:slug` | (the form's submit) |
| `PATCH /surveys/:slug/answers/:key` | `studio_survey_answer_path(slug, key:)` (autosave, JSON) |
| `GET /surveys/:slug/thanks` | `studio_survey_thanks_path(slug)` |

The pages render inside the app's own layout. `Studio.smooth_load` apps get
their view transition into the thank-you screen for free.

## Tests

- `test/lib/studio/survey_test.rb` — the DSL, validation, normalization,
  versioning, breakdown arithmetic, CSV.
- `test/integration/survey_response_test.rb` — storage against the real
  migration.
- `test/integration/survey_flow_test.rb` — the public flow over HTTP.
- `test/integration/admin_surveys_test.rb` — the admin gate, counts, filters,
  CSV.
- `e2e/survey_flow.spec.js` — the stepper in a browser at 375px.
