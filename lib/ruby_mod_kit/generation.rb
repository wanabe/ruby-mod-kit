# frozen_string_literal: true

# rbs_inline: enabled

require "prism"
require "sorted_set"

require "ruby_mod_kit/node"
require "ruby_mod_kit/mission"
require "ruby_mod_kit/mission/ivar_arg"
require "ruby_mod_kit/mission/type_parameter"

module RubyModKit
  # The class of transpiler generation.
  class Generation
    # @rbs @diffs: SortedSet[[Integer, Integer, Integer]]
    # @rbs @missions: Array[Mission]
    # @rbs @script: String

    attr_reader :parse_result #: Prism::ParseResult
    attr_reader :script #: String

    OVERLOAD_METHOD_MAP = {
      "*": "_mul",
    }.freeze #: Hash[Symbol, String]

    # @rbs src: String
    # @rbs previous_error_count: Integer
    # @rbs return: void
    def initialize(script, missions: [], previous_error_count: 0)
      @script = script
      @missions = missions
      @previous_error_count = previous_error_count
      @diffs = SortedSet.new
      @parse_result = Prism.parse(@script)
      @root_node = Node.new(@parse_result.value)
    end

    # @rbs return: Generation
    def generate_next
      Generation.new(@script, missions: @missions, previous_error_count: @parse_result.errors.size)
    end

    def resolve
      if !@parse_result.errors.empty?
        resolve_parse_errors
      elsif !@missions.empty?
        perform_missions
      end
    end

    def completed?
      @parse_result.errors.empty? && @missions.empty?
    end

    # @rbs return: void
    def resolve_parse_errors
      overload_methods = {} if @missions.empty?
      typed_parameter_offsets = Set.new

      @parse_result.errors.each do |parse_error|
        case parse_error.type
        when :argument_formal_ivar
          src_offset = parse_error.location.start_offset

          name = parse_error.location.slice[1..]
          if parse_error.location.slice[0] != "@" || !name
            raise RubyModKit::Error,
                  "Expected ivar but '#{parse_error.location.slice}'"
          end

          self[src_offset, parse_error.location.length] = name
          @missions << Mission::IvarArg.new(src_offset, "@#{name} = #{name}")
        when :unexpected_token_ignore
          next if parse_error.location.slice != "=>"

          def_node = @root_node[parse_error.location.start_offset, Prism::DefNode]
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
          parameter_type_location_range = dst_offset(last_parameter_offset)...dst_offset(right_offset)
          parameter_type = @script[parameter_type_location_range]&.sub(/\s*=>\s*\z/, "")
          raise RubyModKit::Error unless parameter_type

          if overload_methods
            overload_id = [def_parent_node.prism_node.location.start_offset, def_node.named_node!.name]
            overload_methods[overload_id] ||= {}
            overload_methods[overload_id][def_node] ||= []
            overload_methods[overload_id][def_node] << parameter_type
          end

          self[last_parameter_offset, right_offset - last_parameter_offset] = ""
          @missions << Mission::TypeParameter.new(last_parameter_offset, parameter_type)
        end
      end

      overload_methods&.each do |(_, name), def_node_part_pairs|
        next if def_node_part_pairs.size <= 1

        first_def_node = def_node_part_pairs.first[0]
        src_offset = @parse_result.source.offsets[first_def_node.prism_node.location.start_line - 1]
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

      @missions.each do |mission|
        mission.offset = dst_offset(mission.offset)
      end
      @diffs.clear

      return if @previous_error_count == 0 || @previous_error_count > @parse_result.errors.size

      @parse_result.errors.each do |parse_error|
        warn(
          ":#{parse_error.location.start_line}:#{parse_error.message} (#{parse_error.type})",
          @parse_result.source.lines[parse_error.location.start_line - 1],
          "#{" " * parse_error.location.start_column}^#{"~" * [parse_error.location.length - 1, 0].max}",
        )
      end
      raise RubyModKit::Error, "Syntax error"
    end

    # @rbs src_offset: Integer
    # @rbs length: Integer
    # @rbs str: String
    # @rbs return: String
    def []=(src_offset, length, str)
      diff = str.length - length
      @script[dst_offset(src_offset), length] = str
      insert_diff(src_offset, diff)
    end

    # @rbs return: void
    def perform_missions
      @missions.each do |mission|
        mission.perform(self, @root_node, parse_result)
      end
      @missions.clear
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
  end
end
