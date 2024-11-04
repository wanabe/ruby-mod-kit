# frozen_string_literal: true

# rbs_inline: enabled

require "prism"

require "ruby_mod_kit/node"

module RubyModKit
  # The class of transpiler.
  class Transpiler
    # @rbs @index_offsets: [[Integer, Integer]]
    # @rbs @dst: String

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
      @mod_data = []

      previous_error_count = 0
      loop do
        src = @dst.dup
        parse_result = Prism.parse(src)
        node = Node.new(parse_result.value)
        parse_errors = parse_result.errors
        @index_offsets = []
        @typed_parameter_offsets = Set.new
        break if parse_errors.empty?

        parse_errors.each do |parse_error|
          case parse_error.type
          when :argument_formal_ivar
            src_index = parse_error.location.start_offset
            dst_index = dst_index(src_index)

            name = parse_error.location.slice[1..]
            if parse_error.location.slice[0] != "@" || !name
              raise RubyModKit::Error,
                    "Expected ivar but '#{parse_error.location.slice}'"
            end

            self[src_index, parse_error.location.length] = name
            insert_mod_data(dst_index, :ivar_arg, "@#{name} = #{name}")
          when :unexpected_token_ignore
            next if parse_error.location.slice != "=>"

            def_node = node[parse_error.location.start_offset, Prism::DefNode]
            parameters_node, body_node, = def_node&.children
            next if !parameters_node || !body_node

            last_parameter_offset = parameters_node.children.map { _1.prism_node.location.start_offset }.max
            next if @typed_parameter_offsets.include?(last_parameter_offset)

            @typed_parameter_offsets << last_parameter_offset
            right_node = body_node.children.find do |child_node|
              child_node.prism_node.location.start_offset >= parse_error.location.end_offset
            end
            next unless right_node

            right_offset = right_node.prism_node.location.start_offset
            self[last_parameter_offset, right_offset - last_parameter_offset] = ""
          end
        end

        if previous_error_count.positive? && previous_error_count <= parse_errors.size
          parse_errors.each do |error|
            warn(
              ":#{error.location.start_line}:#{error.message} (#{error.type})",
              parse_result.source.lines[error.location.start_line - 1],
              "#{" " * error.location.start_column}^#{"~" * [error.location.length - 1, 0].max}",
            )
          end
          raise RubyModKit::Error, "Syntax error"
        end
        previous_error_count = parse_errors.size
      end
    end

    # @rbs src_index: Integer
    # @rbs length: Integer
    # @rbs str: String
    # @rbs return: String
    def []=(src_index, length, str)
      diff = str.length - length
      @dst[dst_index(src_index), length] = str
      insert_offset(src_index + 1, diff)
    end

    # @rbs return: void
    def apply_collected_data
      root_node = Node.new(Prism.parse(@dst).value)
      @mod_data.each do |(index, type, modify_script)|
        case type
        when :ivar_arg
          def_node = root_node[index, Prism::DefNode]
          raise RubyModKit::Error, "DefNode not found" if !def_node || !def_node.prism_node.is_a?(Prism::DefNode)

          def_body_location = def_node.prism_node.body&.location
          if def_body_location
            indent = def_body_location.start_column
            src_index = def_body_location.start_offset - indent
          elsif def_node.prism_node.end_keyword_loc
            indent = def_node.prism_node.end_keyword_loc.start_column + 2
            src_index = def_node.prism_node.end_keyword_loc.start_offset - indent + 2
          else
            raise RubyModKit::Error, "Invalid DefNode #{def_node.prism_node.inspect}"
          end

          self[src_index, 0] = "#{" " * indent}#{modify_script}\n"
        else
          raise RubyModKit::Error, "Unexpected type #{type}"
        end
      end
    end

    # @rbs src_index: Integer
    # @rbs return: Integer
    def dst_index(src_index)
      dst_index = src_index
      @index_offsets.each do |(index, offset)|
        break if index >= src_index

        dst_index += offset
      end
      dst_index
    end

    # @rbs src_index: Integer
    # @rbs new_diff: Integer
    # @rbs return: void
    def insert_offset(src_index, new_diff)
      array_index = @index_offsets.find_index do |(index, _)|
        src_index < index
      end
      @index_offsets.insert(array_index || -1, [src_index, new_diff])
      @mod_data.each do |line|
        break if line[0] < src_index

        line[0] += new_diff
      end
    end

    # @rbs new_index: Integer
    # @rbs type: Symbol
    # @rbs modify_script: String
    # @rbs return: void
    def insert_mod_data(new_index, type, modify_script)
      array_index = @mod_data.find_index do |(index, _)|
        new_index >= index
      end
      @mod_data.insert(array_index || -1, [new_index, type, modify_script])
    end
  end
end
