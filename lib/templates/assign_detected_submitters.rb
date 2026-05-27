# frozen_string_literal: true

module Templates
  module AssignDetectedSubmitters
    module_function

    Result = Struct.new(:fields, :submitters, keyword_init: true)

    SOURCE = 'role_context_v1'
    HIGH_CONFIDENCE_SCORE = 10
    HIGH_CONFIDENCE_MARGIN = 3
    LOW_CONFIDENCE_MARGIN = 2
    ROW_Y_THRESHOLD = 0.012
    LOCAL_LINE_LIMIT = 180

    GENERIC_SUBMITTER_NAME_REGEXP = /
      \A(?:
        first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth
      )\s+party\z
    /ix

    ROLE_GROUPS = {
      'operator' => {
        aliases: ['operator', 'landlord', 'owner', 'lessor', 'facility', 'storage facility'],
        labels: [
          'employee signature', 'operator signature', 'landlord signature', 'owner signature',
          'lessor signature', 'authorized representative', 'agent signature',
          'lease is made on', 'prorated rent', 'prepaid rent', 'administration fee',
          'storage building', 'space unit', 'space/unit', 'unit price', 'gate code',
          'discounts', 'promotions', 'total', 'vehicle/trailer addendum',
          'boat addendum', 'other addendum', 'supplemental rules', 'move-out notice',
          'addendum to agreement', 'rental agreement'
        ]
      },
      'tenant' => {
        aliases: ['tenant', 'tenants', 'lessee', 'renter', 'occupant', 'customer'],
        labels: [
          'tenant signature', 'tenant name', 'date of birth', 'social security',
          'home address', 'cell phone', 'email address', 'employer', 'emergency contact',
          'authorized access', 'proof of my own insurance', 'property protection plan',
          'contact information', 'authorization for automatic electronic payments',
          'tenant hereby authorizes', 'i accept', 'i would like', '*initial', 'initial'
        ]
      },
      'seller' => {
        aliases: ['seller', 'vendor'],
        labels: ['seller signature']
      },
      'buyer' => {
        aliases: ['buyer', 'purchaser'],
        labels: ['buyer signature']
      }
    }.freeze

    ALIAS_DISPLAY_NAMES = {
      'operator' => 'Operator',
      'landlord' => 'Landlord',
      'owner' => 'Owner',
      'lessor' => 'Lessor',
      'tenant' => 'Tenant',
      'tenants' => 'Tenant',
      'lessee' => 'Lessee',
      'renter' => 'Renter',
      'seller' => 'Seller',
      'buyer' => 'Buyer',
      'purchaser' => 'Purchaser'
    }.freeze

    def call(fields:, head_node:, submitters:, template_has_fields: false)
      fields = fields.to_a
      submitters = normalize_submitters(submitters)
      field_nodes = collect_field_nodes(head_node)
      inferred_roles = infer_roles(head_node)
      submitters, roles = build_submitters(submitters, inferred_roles, template_has_fields:)
      rows = build_field_rows(field_nodes)

      fields.zip(field_nodes).each do |field, node|
        assign_field!(field, node, roles, rows[node.object_id])
      end

      Result.new(fields:, submitters:)
    end

    def normalize_submitters(submitters)
      Array.wrap(submitters).map do |submitter|
        submitter.to_h.deep_dup.stringify_keys.slice('name', 'uuid', 'is_requester', 'linked_to_uuid',
                                                     'invite_via_field_uuid', 'invite_by_uuid',
                                                     'optional_invite_by_uuid', 'email', 'order').compact
      end.presence || [{ 'name' => 'First Party', 'uuid' => SecureRandom.uuid }]
    end

    def collect_field_nodes(head_node)
      nodes = []
      node = head_node

      while node
        nodes << node if node.elem.is_a?(Templates::ImageToFields::Field)

        node = node.next
      end

      nodes
    end

    def infer_roles(head_node)
      text = collect_all_text(head_node)

      ROLE_GROUPS.filter_map do |group, config|
        match = first_alias_match(text, config.fetch(:aliases))

        next unless match

        { group:, name: display_name(match[:alias]), position: match[:position] }
      end.sort_by { |role| role[:position] }
    end

    def collect_all_text(head_node)
      text = +''
      node = head_node

      while node
        text << node.elem if node.elem.is_a?(String)

        node = node.next
      end

      text
    end

    def first_alias_match(text, aliases)
      normalized = normalize_text(text)

      aliases.filter_map do |role_alias|
        position = phrase_position(normalized, role_alias)

        { alias: role_alias, position: } if position
      end.min_by { |match| match[:position] }
    end

    def build_submitters(submitters, inferred_roles, template_has_fields:)
      generic_indexes = submitters.each_index.select { |index| generic_submitter?(submitters[index]) }

      if inferred_roles.present? && generic_indexes.present?
        if template_has_fields
          inferred_roles.each do |role|
            next if role_covered?(submitters, role)

            submitters << { 'name' => role[:name], 'uuid' => SecureRandom.uuid }
          end
        else
          inferred_roles.each do |role|
            next if role_covered?(submitters, role)

            if (index = generic_indexes.shift)
              submitters[index]['name'] = role[:name]
            else
              submitters << { 'name' => role[:name], 'uuid' => SecureRandom.uuid }
            end
          end
        end
      end

      roles = submitters.map { |submitter| build_role(submitter) }

      [submitters, roles]
    end

    def generic_submitter?(submitter)
      submitter['name'].to_s.match?(GENERIC_SUBMITTER_NAME_REGEXP)
    end

    def role_covered?(submitters, inferred_role)
      submitters.any? do |submitter|
        normalize_text(submitter['name']) == normalize_text(inferred_role[:name]) ||
          role_group_for(submitter['name']) == inferred_role[:group]
      end
    end

    def build_role(submitter)
      group = role_group_for(submitter['name'])
      config = group ? ROLE_GROUPS[group] : nil

      {
        name: submitter['name'],
        uuid: submitter['uuid'],
        group:,
        aliases: role_aliases(submitter['name'], config),
        labels: config&.fetch(:labels, []) || []
      }
    end

    def role_group_for(name)
      normalized_name = normalize_text(name)

      ROLE_GROUPS.find do |_group, config|
        config.fetch(:aliases).any? { |role_alias| normalize_text(role_alias) == normalized_name }
      end&.first
    end

    def role_aliases(name, config)
      aliases = [name]
      aliases.concat(config.fetch(:aliases, [])) if config
      aliases.map { |role_alias| normalize_text(role_alias) }.compact_blank.uniq
    end

    def build_field_rows(field_nodes)
      rows = []

      field_nodes.each do |node|
        row = rows.find do |candidate|
          candidate.any? { |row_node| row_node.page == node.page && (row_node.elem.y - node.elem.y).abs <= ROW_Y_THRESHOLD }
        end

        if row
          row << node
        else
          rows << [node]
        end
      end

      rows.each_with_object({}) do |row, acc|
        sorted_row = row.sort_by { |node| node.elem.x }
        sorted_row.each { |node| acc[node.object_id] = sorted_row }
      end
    end

    def assign_field!(field, node, roles, row)
      default_role = roles.first

      unless node && roles.present?
        apply_assignment!(field, default_role, 'low', true, 'No role context found')

        return field
      end

      if (row_role = role_from_row_order(node, row, roles))
        apply_assignment!(field, row_role, 'high', false, "Matched #{row_role[:name]} column")

        return field
      end

      scores = roles.map { |role| [role, score_role(role, context_for(node))] }.sort_by { |(_, score)| -score }
      best_role, best_score = scores.first
      runner_up_score = scores[1]&.last || 0

      winning_margin = best_score - runner_up_score

      if best_score >= HIGH_CONFIDENCE_SCORE && winning_margin >= HIGH_CONFIDENCE_MARGIN
        apply_assignment!(field, best_role, 'high', false, "Matched #{best_role[:name]} context")
      elsif best_score.positive? && winning_margin >= LOW_CONFIDENCE_MARGIN
        apply_assignment!(field, best_role, 'low', true, "Possible #{best_role[:name]} context")
      elsif best_score.positive?
        apply_assignment!(field, default_role, 'low', true, 'Conflicting role context')
      else
        apply_assignment!(field, default_role, 'low', true, 'No clear role context')
      end

      field
    end

    def role_from_row_order(node, row, roles)
      return if row.blank? || row.size < 2

      row_context_candidates(row).each do |row_text|
        ordered_roles = ordered_roles_in_text(row_text, roles)

        return ordered_roles[row.index(node)] if ordered_roles.size >= row.size
        break if ordered_roles.present?
      end

      nil
    end

    def row_context_candidates(row)
      first_node = row.first
      last_node = row.last
      before = collect_text(first_node, direction: :prev, limit: 400).split(/\n/).last.to_s
      after_lines = collect_text(last_node, direction: :next, limit: 400).split(/\n/)
      after = after_lines.first.to_s
      after_with_next_line = after_lines.first(2).join(' ')

      [after, before, after_with_next_line].compact_blank.uniq
    end

    def ordered_roles_in_text(text, roles)
      normalized = normalize_text(text)

      roles.filter_map do |role|
        tokens = role[:aliases] + role[:labels].map { |label| normalize_text(label) }
        position = tokens.filter_map { |token| phrase_position(normalized, token) }.min

        [role, position] if position
      end.sort_by(&:last).map(&:first).uniq
    end

    def context_for(node)
      before = collect_text(node, direction: :prev, limit: 1600)
      after = collect_text(node, direction: :next, limit: 1600)

      before_line = before.split(/\n/).last.to_s
      after_line = after.split(/\n/).first.to_s

      {
        line: "#{before_line} #{after_line}",
        before_close: before_line.last(LOCAL_LINE_LIMIT).to_s,
        after_close: after_line.first(LOCAL_LINE_LIMIT).to_s,
        near: "#{before} #{after}"
      }
    end

    def collect_text(node, direction:, limit:)
      parts = []
      current = node.public_send(direction)
      length = 0
      page = node.page

      while current && current.page == page && length < limit
        content = current.elem.is_a?(String) ? current.elem : ' '

        if direction == :prev
          parts.unshift(content)
        else
          parts << content
        end

        length += content.length
        current = current.public_send(direction)
      end

      text = parts.join

      direction == :prev ? text.last(limit) : text.first(limit)
    end

    def score_role(role, context)
      line = normalize_text(context[:line])
      before_close = normalize_text(context[:before_close])
      after_close = normalize_text(context[:after_close])
      close = "#{before_close} #{after_close}"
      near = normalize_text(context[:near])
      score = 0

      role[:aliases].each do |role_alias|
        score += direct_alias_score(role_alias, before_close:, after_close:, line:)
        score += 2 if phrase_position(close, role_alias)
        score += 1 if phrase_position(line, role_alias)
      end

      role[:labels].each do |label|
        normalized_label = normalize_text(label)
        score += 14 if phrase_position(close, normalized_label)
        score += 10 if phrase_position(line, normalized_label)
        score += 4 if phrase_position(near, normalized_label)
      end

      score
    end

    def direct_alias_score(role_alias, before_close:, after_close:, line:)
      role_alias = normalize_text(role_alias)

      return 0 if role_alias.blank?

      score = 0

      role_alias_pattern = "#{Regexp.escape(role_alias)}(?:s|\s+s)?"

      score += 80 if after_close.match?(/\A(?:_+\s*)?(?:as\s+)?#{role_alias_pattern}\b/)
      score += 18 if line.match?(/#{role_alias_pattern}\s*(?:name|signature|information)\b/)
      score += 10 if before_close.match?(/#{role_alias_pattern}\s*[:\-]?\z/)

      score
    end

    def apply_assignment!(field, role, confidence, review, reason)
      return field unless role

      preferences = (field[:preferences] ||= {})
      metadata = preferences[:detected_submitter] ||= {}

      field[:submitter_uuid] = role[:uuid]

      metadata[:source] = SOURCE
      metadata[:confidence] = confidence
      metadata[:review] = review
      metadata[:reason] = reason

      field
    end

    def display_name(role_alias)
      ALIAS_DISPLAY_NAMES[normalize_text(role_alias)] || role_alias.to_s.split.map(&:capitalize).join(' ')
    end

    def phrase_position(text, phrase)
      normalized_phrase = normalize_text(phrase)

      return if normalized_phrase.blank?

      text.index(/(?:\A|\s)#{Regexp.escape(normalized_phrase)}(?:\s|\z)/)
    end

    def normalize_text(text)
      text.to_s
          .downcase
          .gsub(/[’']s\b/, '')
          .gsub(/[^a-z0-9*]+/, ' ')
          .squish
    end
  end
end
