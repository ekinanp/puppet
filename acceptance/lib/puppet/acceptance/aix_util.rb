module Puppet
  module Acceptance
    module AixUtil
      def to_kv_array(attributes)
        attributes.map { |attribute, value| "#{attribute}=#{value}" }
      end

      def assert_object_attributes_on(agent, object_getter, object, expected_attributes)
        agent.send(object_getter, object) do |result|
          actual_attrs_kv_pairs = result.stdout.chomp.split(' ')[(1..-1)]
          actual_attrs = actual_attrs_kv_pairs.map do |kv_pair|
            attribute, value = kv_pair.split('=')
            next nil unless value
            [attribute, value]
          end.compact.to_h

          expected_attributes.each do |attribute, value|
            attribute_str = "attributes[#{object}][#{attribute}]"
            actual_value = actual_attrs[attribute]
            assert_match(
              /\A#{value}\z/,
              actual_value,
              "EXPECTED: #{attribute_str} = \"#{value}\", ACTUAL:  #{attribute_str} = \"#{actual_value}\""
            )
          end
        end
      end

      def assert_puppet_changed_object_attributes(result, object_resource, object, changed_attributes)
        stdout = result.stdout.chomp
        changed_attributes.each do |attribute, value|
          prefix = /#{object_resource}\[#{object}\].*attributes changed.*/
          attribute_str = "attributes[#{object}][#{attribute}]"
    
          assert_match(
            /#{prefix}#{attribute}=#{value}/,
            stdout,
            "Puppet did not indicate that #{attribute_str} changed to #{value}"
          )
        end
      end

      def object_resource_manifest(object_resource, object, params)
        params_str = params.map do |param, value|
          value_str = value.to_s
          value_str = "\"#{value_str}\"" if value.is_a?(String)
    
          "  #{param} => #{value_str}"
        end.join(",\n")
    
        <<-MANIFEST
#{object_resource} { '#{object}':
  #{params_str}
}
MANIFEST
      end
    end
  end
end
