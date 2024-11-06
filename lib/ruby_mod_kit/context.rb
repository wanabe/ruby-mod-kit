# frozen_string_literal: true

# rbs_inline: enabled

require "prism"
require "sorted_set"

require "ruby_mod_kit/node"

module RubyModKit
  # The class of transpiler context.
  class Context
    # @rbs @diffs: SortedSet[[Integer, Integer, Integer]]
    # @rbs @dst: String

    OVERLOAD_METHOD_MAP = {
      "*": "_mul",
    }.freeze #: Hash[Symbol, String]

    # @rbs src: String
    # @rbs return: void
    def initialize(src)
      @src = src
    end

    # @rbs return: String
    def transpile
      correct_and_collect
      apply_collected_data
      @dst
    end

    # @rbs return: void
    def correct_and_collect
      @dst = @src.dup
      @mod_data = SortedSet.new

      previous_error_count = 0
      loop do
        src = @dst.dup
        parse_result = Prism.parse(src)
        node = Node.new(parse_result.value)
        parse_errors = parse_result.errors
        @diffs = SortedSet.new
        typed_parameter_offsets = Set.new
        break if parse_errors.empty?

        overload_methods = {} if previous_error_count == 0

        parse_errors.each do |parse_error|
          case parse_error.type
          when :argument_formal_ivar
            src_offset = parse_error.location.start_offset

            name = parse_error.location.slice[1..]
            if parse_error.location.slice[0] != "@" || !name
              raise RubyModKit::Error,
                    "Expected ivar but '#{parse_error.location.slice}'"
            end

            self[src_offset, parse_error.location.length] = name
            insert_mod_data(src_offset, :ivar_arg, "@#{name} = #{name}")
          when :unexpected_token_ignore
            next if parse_error.location.slice != "=>"

            def_node = node[parse_error.location.start_offset, Prism::DefNode]
            next unless def_node

            def_parent_node = def_node.parent
            parameters_node, body_node, = def_node.children
            next if !def_parent_node || !parameters_node || !body_node

            last_parameter_offset = parameters_node.children.map { _1.prism_node.location.start_offset }.max
            next if typed_parameter_offsets.include?(last_parameter_offset)

            typed_parameter_offsets << last_parameter_offset
            right_node = body_node.children.find do |child_node|
              child_node.prism_node.location.start_offset >= parse_error.location.end_offset
            end
            next unless right_node

            right_offset = right_node.prism_node.location.start_offset
            parameter_type = @dst[dst_offset(last_parameter_offset)...dst_offset(right_offset)]&.sub(/\s*=>\s*\z/, "")
            raise RubyModKit::Error unless parameter_type

            if overload_methods
              overload_id = [def_parent_node.prism_node.location.start_offset, def_node.named_node!.name]
              overload_methods[overload_id] ||= {}
              overload_methods[overload_id][def_node] ||= []
              overload_methods[overload_id][def_node] << parameter_type
            end

            self[last_parameter_offset, right_offset - last_parameter_offset] = ""
            insert_mod_data(last_parameter_offset, :type_parameter, parameter_type)
          end
        end

        overload_methods&.each do |(_, name), def_node_part_pairs|
          next if def_node_part_pairs.size <= 1

          first_def_node = def_node_part_pairs.first[0]
          src_offset = parse_result.source.offsets[first_def_node.prism_node.location.start_line - 1]
          script = +""
          def_node_part_pairs.each_value do |parts|
            script << if script.empty?
              "# @rbs"
            else
              "#    |"
            end
            script << " (#{parts.join(", ")}) -> untyped\n"
          end
          script << "def #{name}(*args)\n  case args\n"
          overload_prefix = +"#{OVERLOAD_METHOD_MAP[name] || name}_"
          def_node_part_pairs.each_with_index do |(def_node, parts), i|
            overload_name = "#{overload_prefix}_overload#{i}"
            name_loc = def_node.prism_node.name_loc
            self[name_loc.start_offset, name_loc.length] = overload_name
            script << "  in [#{parts.join(", ")}]\n"
            script << "    #{overload_name}(*args)\n"
          end
          script << "  end\nend\n\n"
          indent = first_def_node.prism_node.location.start_offset - src_offset
          script.gsub!(/^(?=.)/, " " * indent)
          self[src_offset, 0] = script
        end

        @mod_data.each do |line|
          line[0] = dst_offset(line[0])
        end

        if previous_error_count > 0 && previous_error_count <= parse_errors.size
          parse_errors.each do |parse_error|
            warn(
              ":#{parse_error.location.start_line}:#{parse_error.message} (#{parse_error.type})",
              parse_result.source.lines[parse_error.location.start_line - 1],
              "#{" " * parse_error.location.start_column}^#{"~" * [parse_error.location.length - 1, 0].max}",
            )
          end
          raise RubyModKit::Error, "Syntax error"
        end
        previous_error_count = parse_errors.size
      end
    end

    # @rbs src_offset: Integer
    # @rbs length: Integer
    # @rbs str: String
    # @rbs return: String
    def []=(src_offset, length, str)
      diff = str.length - length
      @dst[dst_offset(src_offset), length] = str
      insert_diff(src_offset, diff)
    end

    # @rbs return: void
    def apply_collected_data
      parse_result = Prism.parse(@dst)
      root_node = Node.new(parse_result.value)
      @mod_data.each do |(index, _, type, modify_script)|
        case type
        when :ivar_arg
          def_node = root_node[index, Prism::DefNode]
          raise RubyModKit::Error, "DefNode not found" if !def_node || !def_node.prism_node.is_a?(Prism::DefNode)

          def_body_location = def_node.prism_node.body&.location
          if def_body_location
            indent = def_body_location.start_column
            src_offset = def_body_location.start_offset - indent
          elsif def_node.prism_node.end_keyword_loc
            indent = def_node.prism_node.end_keyword_loc.start_column + 2
            src_offset = def_node.prism_node.end_keyword_loc.start_offset - indent + 2
          else
            raise RubyModKit::Error, "Invalid DefNode #{def_node.prism_node.inspect}"
          end

          self[src_offset, 0] = "#{" " * indent}#{modify_script}\n"
        when :type_parameter
          def_node = root_node[index, Prism::DefNode]
          raise RubyModKit::Error, "DefNode not found" if !def_node || !def_node.prism_node.is_a?(Prism::DefNode)

          parameter_node = root_node[index]
          raise RubyModKit::Error, "ParameterNode not found" unless parameter_node

          src_offset = parse_result.source.offsets[def_node.prism_node.location.start_line - 1]
          indent = def_node.prism_node.location.start_offset - src_offset
          self[src_offset, 0] = "#{" " * indent}# @rbs #{parameter_node.name}: #{modify_script}\n"
        else
          raise RubyModKit::Error, "Unexpected type #{type}"
        end
      end
    end

    # @rbs src_offset: Integer
    # @rbs return: Integer
    def dst_offset(src_offset)
      dst_offset = src_offset
      @diffs.each do |(offset, _, diff)|
        break if offset > src_offset
        break if offset == src_offset && diff < 0

        dst_offset += diff
      end
      dst_offset
    end

    # @rbs src_offset: Integer
    # @rbs new_diff: Integer
    # @rbs return: void
    def insert_diff(src_offset, new_diff)
      @diffs << [src_offset, @diffs.size, new_diff]
    end

    # @rbs src_offset: Integer
    # @rbs type: Symbol
    # @rbs modify_script: String
    # @rbs return: void
    def insert_mod_data(src_offset, type, modify_script)
      @mod_data << [src_offset, @mod_data.size, type, modify_script]
    end
  end
end