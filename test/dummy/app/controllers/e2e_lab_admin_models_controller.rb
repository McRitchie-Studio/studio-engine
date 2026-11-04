# frozen_string_literal: true

# /lab/admin_models: the engine's real studio/admin_models/show, through the real
# Studio::AdminModels concern, under the real navbar, with the sticky table header
# on for this request. The rows are plain objects: what is under test is the page's
# stack, and the dummy has no sessions table.
class E2eLabAdminModelsController < E2eLabController
  include Studio::AdminModels

  # Enough tabs that they overflow a phone, so the open tab can be off screen.
  MODELS = %w[Users Sessions Contests Entries Teams Players Games Markets Invoices].to_h { |label|
    [label.downcase, { label: label, description: "#{label} in the lab" }]
  }.freeze

  LabUser = Struct.new(:email)
  LabRow = Struct.new(:user, :admin, :started_at, :last_seen_at)

  # The three calls #show makes of a relation.
  class LabScope
    def initialize(rows) = @rows = rows
    def count = @rows.size
    def offset(by) = self.class.new(@rows.drop(by))
    def limit(to) = @rows.first(to)
  end

  helper_method :admin_model_path

  def show
    @lab_sticky_table_headers = true
    bar_stack_locals
    super
  end

  # The concern's #show renders the engine's view by name; the lab wraps it in the
  # navbar through this template, so the chrome is the host's.
  def render(*args, **options, &block)
    return super unless args == ["studio/admin_models/show"]

    super(template: "e2e_lab/admin_models")
  end

  private

  def admin_model_path(key, **query)
    "/lab/admin_models/#{key}#{"?#{query.to_query}" if query.any?}"
  end

  def admin_model_configs = MODELS
  def admin_model_scope(_key) = LabScope.new(lab_rows)
  def admin_models_table_partial(_key) = "studio/admin_models/sessions_table"

  def lab_rows
    Array.new(60) { |i| LabRow.new(LabUser.new("person#{i}@example.test"), i.zero?, (i + 1).hours.ago, i.minutes.ago) }
  end
end
