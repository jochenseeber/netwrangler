# frozen_string_literal: true

require "yaml"

module Demo
  # The YAML files of an example directory, read on the host and handed to
  # `kubectl` in the control plane through its standard input.
  module Manifests
    # The project's examples, by directory.
    ROOT = File.expand_path("../../examples", __dir__)

    # Every document of the directory's YAML files as one stream, namespaces
    # first, so the objects that live in a namespace find it on a first apply.
    #
    # @param directory [String] relative to the project
    # @return [String]
    def self.stream(directory)
      namespaces, others = documents(directory).partition { |document| namespace?(document) }
      (namespaces + others).join("\n---\n")
    end

    # The kind and name of every object in the directories under `examples/`
    # whose kind is one of +kinds+. Hidden directories are not examples.
    #
    # @return [Array<Array(String, String)>] kind and name pairs
    def self.objects(kinds, exclude: [])
      directories = Dir.glob(File.join(ROOT, "*/")).map { |path| path.chomp("/") }.sort
      directories.reject { |path| exclude.include?(File.basename(path)) }.flat_map do |path|
        documents(path).filter_map do |document|
          object = YAML.safe_load(document)
          [object["kind"], object.dig("metadata", "name")] if object.is_a?(Hash) && kinds.include?(object["kind"])
        end
      end
    end

    # The non-empty YAML documents of the directory's files, in file name order.
    def self.documents(directory)
      path = File.expand_path(directory, File.dirname(ROOT))
      files = Dir.glob(File.join(path, "*.{yaml,yml}"))
      raise "#{directory} has no YAML files" if files.empty?

      files.sort.flat_map { |file| File.read(file).split(%r{^---[ \t]*$}) }.reject { |text| YAML.safe_load(text).nil? }
    end

    def self.namespace?(document) = document.match?(%r{^kind:\s*Namespace\s*$})
    private_class_method :namespace?
  end
end
