# frozen_string_literal: true

module Studio
  # /admin/knowledge — the knowledge layer's browser + intake surface.
  #
  # A plain host-inherited controller whose views are bare content wrappers,
  # like /admin/geo, so pages render inside each host's application layout and
  # pick up that app's navbar and theme. Routes are opt-in
  # (Studio.draw_knowledge_routes) — see Studio.routes.
  #
  # Uploads land as status "inbox"; an agent running the knowledge-intake SOP
  # (or the operator, on the show page) files them — classification is a
  # deliberate second step, not a side effect of upload.
  class KnowledgeDocsController < ApplicationController
    before_action :require_admin
    before_action :set_doc, only: [:show, :update, :download]

    VIEWS = %w[folders flat].freeze

    def index
      @view    = VIEWS.include?(params[:view]) ? params[:view] : "folders"
      @folder  = Studio::KnowledgeDoc.normalize_path(params[:folder])
      @entity  = params[:entity].presence
      @status  = Studio::KnowledgeDoc::STATUSES.include?(params[:status]) ? params[:status] : nil

      scope = Studio::KnowledgeDoc.order(created_at: :desc)
      scope = scope.for_entity(@entity) if @entity

      @entities = Studio::KnowledgeDoc.distinct.pluck(:entity).sort
      # Counted BEFORE the status filter: the badge answers "what waits for
      # triage in this entity", and filtering to status=filed must not zero it.
      @inbox_size = scope.inbox.count

      scope = scope.where(status: @status) if @status

      if @view == "folders"
        @folders = scope.folders_under(@folder)
        @docs    = scope.in_folder(@folder)
      else
        @folders = []
        @docs    = scope
      end
    end

    def show
    end

    def create
      file = params.dig(:knowledge_doc, :file)
      doc  = Studio::KnowledgeDoc.intake!(
        doc_params.merge(uploaded_by: current_user&.email, status: "inbox"),
        file: file
      )
      redirect_to admin_knowledge_doc_path(doc), notice: "#{doc.title} landed in the inbox."
    rescue Studio::S3::NotConfigured, Studio::KnowledgeDoc::MissingTable => e
      redirect_to admin_knowledge_path, alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_knowledge_path, alert: e.message
    end

    def update
      @doc.update!(doc_params)
      redirect_to admin_knowledge_doc_path(@doc), notice: "#{@doc.title} updated."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_knowledge_doc_path(@doc), alert: e.message
    end

    def download
      return redirect_to admin_knowledge_doc_path(@doc), alert: "No file attached." unless @doc.file?

      redirect_to @doc.signed_url, allow_other_host: true
    end

    private

    def set_doc
      @doc = Studio::KnowledgeDoc.find(params[:id])
    end

    def doc_params
      permitted = params.require(:knowledge_doc)
                        .permit(:title, :entity, :path, :category, :summary,
                                :document_date, :source_note, :status, access: {})
      # The access map arrives as {"samson" => "full", ...}; drop blanks so an
      # untouched select doesn't write a "none" the map means by absence anyway.
      if permitted[:access]
        permitted[:access] = permitted[:access].to_h.reject { |_agent, level| level.blank? }
      end
      permitted
    end
  end
end
