# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Templates::AssignDetectedSubmitters do
  let(:operator_uuid) { 'operator-uuid' }
  let(:tenant_uuid) { 'tenant-uuid' }

  def detected_field(x:, y:, type: 'text')
    Templates::ImageToFields::Field.new(type:, x:, y:, w: 0.1, h: 0.02, confidence: 0.9)
  end

  def field_hash(field)
    {
      uuid: SecureRandom.uuid,
      type: field.type,
      required: false,
      preferences: {},
      areas: [{ x: field.x, y: field.y, w: field.w, h: field.h, page: 0, attachment_uuid: 'doc' }]
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

  def call_assigner(fields, head_node, submitters:, template_has_fields: false)
    described_class.call(fields:, head_node:, submitters:, template_has_fields:)
  end

  it 'renames generic submitters from document roles and assigns same-row signatures by role column' do
    operator_signature = detected_field(x: 0.1, y: 0.7)
    tenant_signature = detected_field(x: 0.55, y: 0.7)
    fields = [field_hash(operator_signature), field_hash(tenant_signature)]
    head_node = page_node_stream(
      "AGREED TO by Operator and Tenant.\nLIDDELL STOR-ALL, OPERATOR TENANT:\nBy: ",
      operator_signature,
      ' ',
      tenant_signature,
      "\nEmployee Signature Tenant Signature"
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'First Party', 'uuid' => operator_uuid },
        { 'name' => 'Second Party', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.submitters.pluck('name')).to eq(%w[Operator Tenant])
    expect(result.fields.pluck(:submitter_uuid)).to eq([operator_uuid, tenant_uuid])
    expect(result.fields.map { |field| field.dig(:preferences, :detected_submitter, :review) }).to eq([false, false])
  end

  it 'assigns tenant information fields to the tenant submitter' do
    tenant_name = detected_field(x: 0.28, y: 0.12)
    birth_date = detected_field(x: 0.2, y: 0.16)
    fields = [field_hash(tenant_name), field_hash(birth_date)]
    head_node = page_node_stream(
      'Tenant Name (PRINT): ',
      tenant_name,
      "\nDate of Birth: ",
      birth_date,
      ' Social Security #: '
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Operator', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.fields.pluck(:submitter_uuid)).to eq([tenant_uuid, tenant_uuid])
    expect(result.fields.map { |field| field.dig(:preferences, :detected_submitter, :confidence) }).to eq(%w[high high])
  end

  it 'marks fields for review when role context is ambiguous' do
    amount = detected_field(x: 0.3, y: 0.3)
    fields = [field_hash(amount)]
    head_node = page_node_stream('Reference: ', amount, "\n")

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Operator', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.fields.first[:submitter_uuid]).to eq(operator_uuid)
    expect(result.fields.first.dig(:preferences, :detected_submitter)).to include(
      source: 'role_context_v1',
      confidence: 'low',
      review: true,
      reason: 'No clear role context'
    )
  end

  it 'uses existing custom role names without renaming them' do
    signature = detected_field(x: 0.1, y: 0.7)
    fields = [field_hash(signature)]
    head_node = page_node_stream('LIDDELL STOR-ALL, OPERATOR', signature, "\nEmployee Signature")

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Landlord', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.submitters.pluck('name')).to eq(%w[Landlord Tenant])
    expect(result.fields.first[:submitter_uuid]).to eq(operator_uuid)
  end

  it 'adds inferred roles instead of renaming generic submitters when the template already has fields' do
    operator_signature = detected_field(x: 0.1, y: 0.7)
    tenant_signature = detected_field(x: 0.55, y: 0.7)
    fields = [field_hash(operator_signature), field_hash(tenant_signature)]
    head_node = page_node_stream(
      "LIDDELL STOR-ALL, OPERATOR TENANT:\nBy: ",
      operator_signature,
      ' ',
      tenant_signature,
      "\nEmployee Signature Tenant Signature"
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'First Party', 'uuid' => 'first-party-uuid' },
        { 'name' => 'Second Party', 'uuid' => 'second-party-uuid' }
      ],
      template_has_fields: true
    )

    expect(result.submitters.pluck('name')).to eq(['First Party', 'Second Party', 'Operator', 'Tenant'])
    expect(result.fields.pluck(:submitter_uuid)).to eq(result.submitters.last(2).pluck('uuid'))
  end
  it 'prefers a direct post-field role label over broader page context' do
    tenant_name = detected_field(x: 0.16, y: 0.16)
    fields = [field_hash(tenant_name)]
    head_node = page_node_stream(
      'This LEASE is made on ___ between Liddell Stor-All as Operator and ',
      tenant_name,
      "___as Tenant(s), for the below listed unit located at\nProrated Rent: $___\tStorage Building #: ___\n"
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Landlord', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.fields.first[:submitter_uuid]).to eq(tenant_uuid)
  end

  it 'does not turn ordinary two-column admin rows into landlord and tenant role columns' do
    discount = detected_field(x: 0.35, y: 0.27)
    gate_code = detected_field(x: 0.72, y: 0.27)
    fields = [field_hash(discount), field_hash(gate_code)]
    head_node = page_node_stream(
      discount,
      ' ',
      gate_code,
      "Any Discounts/Promotions: ___\tGate Code: ___\nProperty Protection Plan: $___"
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Landlord', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.fields.pluck(:submitter_uuid)).to eq([operator_uuid, operator_uuid])
  end

  it 'assigns tenant initials from the immediate field label even when operator appears nearby' do
    initial = detected_field(x: 0.67, y: 0.15)
    fields = [field_hash(initial)]
    head_node = page_node_stream(
      'Operator is not liable for damage caused by theft ',
      initial,
      'by others, war, acts of terrorism, or any other cause unless prohibited by law. *Initial: ___'
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Landlord', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.fields.first[:submitter_uuid]).to eq(tenant_uuid)
  end

  it 'uses strong section context for continuation-page tenant authorization fields' do
    signature = detected_field(x: 0.27, y: 0.9)
    fields = [field_hash(signature)]
    head_node = page_node_stream(
      '40. AUTHORIZATION FOR AUTOMATIC ELECTRONIC PAYMENTS: Tenant hereby authorizes Owner to initiate recurring debits. ',
      'Notwithstanding any revocation, Tenant shall remain obligated to timely remit all rent. ',
      signature,
      'Signature: ___ Date: ___'
    )

    result = call_assigner(
      fields,
      head_node,
      submitters: [
        { 'name' => 'Landlord', 'uuid' => operator_uuid },
        { 'name' => 'Tenant', 'uuid' => tenant_uuid }
      ]
    )

    expect(result.fields.first[:submitter_uuid]).to eq(tenant_uuid)
  end

end
