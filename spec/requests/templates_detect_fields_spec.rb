# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Template detected fields' do
  def detected_field(x:, y:)
    Templates::ImageToFields::Field.new(type: 'text', x:, y:, w: 0.1, h: 0.02, confidence: 0.9)
  end

  def field_hash(field, attachment)
    {
      uuid: SecureRandom.uuid,
      type: field.type,
      required: false,
      preferences: {},
      areas: [{ x: field.x, y: field.y, w: field.w, h: field.h, page: 0, attachment_uuid: attachment.uuid }]
    }
  end

  def page_node_stream(*elements)
    head = Templates::DetectFields::PageNode.new(elem: ''.b, page: 0, attachment_uuid: 'doc')
    tail = head

    elements.each do |element|
      node = Templates::DetectFields::PageNode.new(prev: tail, elem: element, page: 0, attachment_uuid: 'doc')
      tail.next = node
      tail = node
    end

    head
  end

  it 'streams completed detected fields with submitter assignments and inferred submitters' do
    account = create(:account)
    user = create(:user, account:)
    template = create(:template, account:, author: user, submitter_count: 2)
    attachment = template.schema_documents.first

    template.update!(
      fields: [],
      submitters: [
        { 'name' => 'First Party', 'uuid' => 'operator-uuid' },
        { 'name' => 'Second Party', 'uuid' => 'tenant-uuid' }
      ]
    )

    sign_in(user)

    operator_signature = detected_field(x: 0.1, y: 0.7)
    tenant_signature = detected_field(x: 0.55, y: 0.7)
    fields = [field_hash(operator_signature, attachment), field_hash(tenant_signature, attachment)]
    head_node = page_node_stream(
      "LIDDELL STOR-ALL, OPERATOR TENANT:\nBy: ",
      operator_signature,
      ' ',
      tenant_signature,
      "\nEmployee Signature Tenant Signature"
    )

    allow(Templates::DetectFields).to receive(:call) do |_io, **_kwargs, &block|
      block.call([attachment.uuid, 0, fields])

      [fields, head_node]
    end

    post "/templates/#{template.id}/detect_fields"

    events = response.body.scan(/^data: (.+)$/).flatten.map { |json| JSON.parse(json) }
    completed_event = events.find { |event| event['completed'] }

    expect(response).to have_http_status(:ok)
    expect(completed_event['submitters'].pluck('name')).to eq(%w[Operator Tenant])
    expect(completed_event['fields'].pluck('submitter_uuid')).to eq(%w[operator-uuid tenant-uuid])
    expect(completed_event['fields'].map { |field| field.dig('preferences', 'detected_submitter', 'review') })
      .to eq([false, false])
  end
end
