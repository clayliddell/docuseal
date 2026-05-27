# frozen_string_literal: true

class TemplatesDetectFieldsController < ApplicationController
  include ActionController::Live

  load_and_authorize_resource :template

  def create
    response.headers['Content-Type'] = 'text/event-stream'

    sse = SSE.new(response.stream)

    documents = @template.schema_documents.preload(:blob)
    documents = documents.where(uuid: params[:attachment_uuid]) if params[:attachment_uuid].present?

    page_number = params[:page].presence&.to_i
    submitters = @template.submitters
    template_has_fields = @template.fields.present?
    detected_fields = []

    documents.each do |document|
      io = StringIO.new(document.download)

      fields, head_node = Templates::DetectFields.call(io, attachment: document, page_number:) do |(attachment_uuid, page, fields)|
        sse.write({ attachment_uuid:, page:, fields: })
      end

      if head_node
        result = Templates::AssignDetectedSubmitters.call(fields:, head_node:, submitters:, template_has_fields:)
        fields = result.fields
        submitters = result.submitters
      end

      detected_fields.concat(fields)
    end

    sse.write({ completed: true, submitters:, fields: detected_fields })
  ensure
    response.stream.close
  end
end
