# frozen_string_literal: true

module YARP
  # This represents a source of Ruby code that has been parsed. It is used in
  # conjunction with locations to allow them to resolve line numbers and source
  # ranges.
  class Source
    attr_reader :source, :offsets

    def initialize(source, offsets = compute_offsets(source))
      @source = source
      @offsets = offsets
    end

    private def compute_offsets(code)
      offsets = [0]
      code.b.scan("\n") { offsets << $~.end(0) }
      offsets
    end

    def slice(offset, length)
      source.byteslice(offset, length)
    end

    def line(value)
      offsets.bsearch_index { |offset| offset > value } || offsets.length
    end

    def column(value)
      value - offsets[line(value) - 1]
    end
  end

  # This represents a location in the source.
  class Location
    # A Source object that is used to determine more information from the given
    # offset and length.
    private attr_reader :source

    # The byte offset from the beginning of the source where this location
    # starts.
    attr_reader :start_offset

    # The length of this location in bytes.
    attr_reader :length

    def initialize(source, start_offset, length)
      @source = source
      @start_offset = start_offset
      @length = length
    end

    def inspect
      "#<YARP::Location @start_offset=#{@start_offset} @length=#{@length}>"
    end

    # The source code that this location represents.
    def slice
      source.slice(start_offset, length)
    end

    # The byte offset from the beginning of the source where this location ends.
    def end_offset
      start_offset + length
    end

    # The line number where this location starts.
    def start_line
      source.line(start_offset)
    end

    # The line number where this location ends.
    def end_line
      source.line(end_offset - 1)
    end

    # The column number in bytes where this location starts from the start of
    # the line.
    def start_column
      source.column(start_offset)
    end

    # The column number in bytes where this location ends from the start of the
    # line.
    def end_column
      source.column(end_offset - 1)
    end

    def deconstruct_keys(keys)
      { start_offset: start_offset, end_offset: end_offset }
    end

    def pretty_print(q)
      q.text("(#{start_offset}...#{end_offset})")
    end

    def ==(other)
      other.is_a?(Location) &&
        other.start_offset == start_offset &&
        other.end_offset == end_offset
    end

    def self.null
      new(0, 0)
    end
  end

  # This represents a comment that was encountered during parsing.
  class Comment
    TYPES = [:inline, :embdoc, :__END__]

    attr_reader :type, :location

    def initialize(type, location)
      @type = type
      @location = location
    end

    def deconstruct_keys(keys)
      { type: type, location: location }
    end
  end

  # This represents an error that was encountered during parsing.
  class ParseError
    attr_reader :message, :location

    def initialize(message, location)
      @message = message
      @location = location
    end

    def deconstruct_keys(keys)
      { message: message, location: location }
    end
  end

  # This represents a warning that was encountered during parsing.
  class ParseWarning
    attr_reader :message, :location

    def initialize(message, location)
      @message = message
      @location = location
    end

    def deconstruct_keys(keys)
      { message: message, location: location }
    end
  end

  # A class that knows how to walk down the tree. None of the individual visit
  # methods are implemented on this visitor, so it forces the consumer to
  # implement each one that they need. For a default implementation that
  # continues walking the tree, see the Visitor class.
  class BasicVisitor
    def visit(node)
      node&.accept(self)
    end

    def visit_all(nodes)
      nodes.map { |node| visit(node) }
    end

    def visit_child_nodes(node)
      visit_all(node.child_nodes)
    end
  end

  class Visitor < BasicVisitor
  end

  # This represents the result of a call to ::parse or ::parse_file. It contains
  # the AST, any comments that were encounters, and any errors that were
  # encountered.
  class ParseResult
    attr_reader :value, :comments, :errors, :warnings, :source

    def initialize(value, comments, errors, warnings, source)
      @value = value
      @comments = comments
      @errors = errors
      @warnings = warnings
      @source = source
    end

    def deconstruct_keys(keys)
      { value: value, comments: comments, errors: errors, warnings: warnings }
    end

    def success?
      errors.empty?
    end

    def failure?
      !success?
    end

    # Keep in sync with Java MarkNewlinesVisitor
    class MarkNewlinesVisitor < YARP::Visitor
      def initialize(newline_marked)
        @newline_marked = newline_marked
      end

      def visit_block_node(node)
        old_newline_marked = @newline_marked
        @newline_marked = Array.new(old_newline_marked.size, false)
        begin
          super(node)
        ensure
          @newline_marked = old_newline_marked
        end
      end
      alias_method :visit_lambda_node, :visit_block_node

      def visit_if_node(node)
        node.set_newline_flag(@newline_marked)
        super(node)
      end
      alias_method :visit_unless_node, :visit_if_node

      def visit_statements_node(node)
        node.body.each do |child|
          child.set_newline_flag(@newline_marked)
        end
        super(node)
      end
    end
    private_constant :MarkNewlinesVisitor

    def mark_newlines
      newline_marked = Array.new(1 + @source.offsets.size, false)
      visitor = MarkNewlinesVisitor.new(newline_marked)
      value.accept(visitor)
      value
    end
  end

  # This represents a token from the Ruby source.
  class Token
    attr_reader :type, :value, :location

    def initialize(type, value, location)
      @type = type
      @value = value
      @location = location
    end

    def deconstruct_keys(keys)
      { type: type, value: value, location: location }
    end

    def pretty_print(q)
      q.group do
        q.text(type.to_s)
        self.location.pretty_print(q)
        q.text("(")
        q.nest(2) do
          q.breakable("")
          q.pp(value)
        end
        q.breakable("")
        q.text(")")
      end
    end

    def ==(other)
      other.is_a?(Token) &&
        other.type == type &&
        other.value == value
    end
  end

  # This represents a node in the tree.
  class Node
    attr_reader :location

    def newline?
      @newline ? true : false
    end

    def set_newline_flag(newline_marked)
      line = location.start_line
      unless newline_marked[line]
        newline_marked[line] = true
        @newline = true
      end
    end

    # Slice the location of the node from the source.
    def slice
      location.slice
    end

    def pretty_print(q)
      q.group do
        q.text(self.class.name.split("::").last)
        location.pretty_print(q)
        q.text("[Li:#{location.start_line}]") if newline?
        q.text("(")
        q.nest(2) do
          deconstructed = deconstruct_keys([])
          deconstructed.delete(:location)

          q.breakable("")
          q.seplist(deconstructed, lambda { q.comma_breakable }, :each_value) { |value| q.pp(value) }
        end
        q.breakable("")
        q.text(")")
      end
    end
  end

  # Load the serialized AST using the source as a reference into a tree.
  def self.load(source, serialized)
    Serialize.load(source, serialized)
  end

  # This module is used for testing and debugging and is not meant to be used by
  # consumers of this library.
  module Debug
    def self.newlines(source)
      YARP.parse(source).source.offsets
    end

    def self.parse_serialize_file(filepath)
      parse_serialize_file_metadata(filepath, [filepath.bytesize, filepath.b, 0].pack("LA*L"))
    end
  end

  # Marking this as private so that consumers don't see it. It makes it a little
  # annoying for testing since you have to const_get it to access the methods,
  # but at least this way it's clear it's not meant for consumers.
  private_constant :Debug
end

require_relative "yarp/lex_compat"
require_relative "yarp/node"
require_relative "yarp/ripper_compat"
require_relative "yarp/serialize"
require_relative "yarp/pack"

if RUBY_ENGINE == 'ruby' and !ENV["YARP_FFI_BACKEND"]
  require "yarp/yarp.so"
else
  require "rbconfig"
  require "ffi"

  module YARP
    BACKEND = :FFI

    module LibRubyParser
      extend FFI::Library

      class Buffer < FFI::Struct
        layout value: :pointer, length: :size_t, capacity: :size_t

        def to_ruby_string
          self[:value].read_string(self[:length])
        end
      end

      ffi_lib File.expand_path("../build/librubyparser.#{RbConfig::CONFIG['SOEXT']}", __dir__)

      def self.resolve_type(type)
        type = type.strip.sub(/^const /, '')
        type.end_with?('*') ? :pointer : type.to_sym
      end

      def self.load_exported_functions_from(header, functions)
        File.readlines(File.expand_path("../include/#{header}", __dir__)).each do |line|
          if line.start_with?('YP_EXPORTED_FUNCTION ')
            if functions.any? { |function| line.include?(function) }
              /^YP_EXPORTED_FUNCTION (?<return_type>.+) (?<name>\w+)\((?<arg_types>.+)\);$/ =~ line or raise "Could not parse #{line}"
              arg_types = arg_types.split(',')
              arg_types = [] if arg_types == %w[void]
              arg_types = arg_types.map { |type| resolve_type(type.sub(/\w+$/, '')) }
              return_type = resolve_type return_type
              attach_function name, arg_types, return_type
            end
          end
        end
      end

      load_exported_functions_from("yarp.h",
        %w[yp_version yp_parse_serialize yp_lex_serialize])
      load_exported_functions_from("yarp/util/yp_buffer.h",
        %w[yp_buffer_init yp_buffer_free])
      load_exported_functions_from("yarp/util/yp_string.h",
        %w[yp_string_mapped_init yp_string_free yp_string_source yp_string_length yp_string_sizeof])

      SIZEOF_YP_STRING = yp_string_sizeof

      def self.pointer(size)
        pointer = FFI::MemoryPointer.new(size)
        begin
          yield pointer
        ensure
          pointer.free
        end
      end

      def self.yp_string(&block)
        pointer(LibRubyParser::SIZEOF_YP_STRING, &block)
      end
    end
    private_constant :LibRubyParser

    VERSION = LibRubyParser.yp_version.to_s

    def self.dump_internal(source, source_size, filepath)
      buffer = LibRubyParser::Buffer.new
      begin
        raise unless LibRubyParser.yp_buffer_init(buffer)
        metadata = nil
        if filepath
          metadata = [filepath.bytesize].pack('L') + filepath + [0].pack('L')
        end
        LibRubyParser.yp_parse_serialize(source, source_size, buffer, metadata)
        buffer.to_ruby_string
      ensure
        LibRubyParser.yp_buffer_free(buffer)
        buffer.pointer.free
      end
    end
    private_class_method :dump_internal

    def self.dump(code, filepath = nil)
      dump_internal(code, code.bytesize, filepath)
    end

    def self.dump_file(filepath)
      LibRubyParser.yp_string do |contents|
        raise unless LibRubyParser.yp_string_mapped_init(contents, filepath)
        dump_internal(LibRubyParser.yp_string_source(contents), LibRubyParser.yp_string_length(contents), filepath)
      ensure
        LibRubyParser.yp_string_free(contents)
      end
    end

    def self.lex(code, filepath = nil)
      buffer = LibRubyParser::Buffer.new
      begin
        raise unless LibRubyParser.yp_buffer_init(buffer)
        LibRubyParser.yp_lex_serialize(code, code.bytesize, filepath, buffer)
        serialized = buffer.to_ruby_string

        source = Source.new(code)
        parse_result = YARP::Serialize.load_tokens(source, serialized)

        ParseResult.new(parse_result.value, parse_result.comments, parse_result.errors, parse_result.warnings, source)
      ensure
        LibRubyParser.yp_buffer_free(buffer)
        buffer.pointer.free
      end
    end

    def self.lex_file(filepath)
      LibRubyParser.yp_string do |contents|
        raise unless LibRubyParser.yp_string_mapped_init(contents, filepath)
        # We need the Ruby String for the YARP::Source anyway, so just use that
        code_string = LibRubyParser.yp_string_source(contents).read_string(LibRubyParser.yp_string_length(contents))
        lex(code_string, filepath)
      ensure
        LibRubyParser.yp_string_free(contents)
      end
    end

    def self.parse(code, filepath = nil)
      serialized = dump(code, filepath)
      parse_result = YARP.load(code, serialized)
      source = Source.new(code)
      ParseResult.new(parse_result.value, parse_result.comments, parse_result.errors, parse_result.warnings, source)
    end

    def self.parse_file(filepath)
      LibRubyParser.yp_string do |contents|
        raise unless LibRubyParser.yp_string_mapped_init(contents, filepath)
        # We need the Ruby String for the YARP::Source anyway, so just use that
        code_string = LibRubyParser.yp_string_source(contents).read_string(LibRubyParser.yp_string_length(contents))
        parse(code_string, filepath)
      ensure
        LibRubyParser.yp_string_free(contents)
      end
    end
  end
end
