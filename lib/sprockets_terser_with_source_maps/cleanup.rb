# frozen_string_literal: true

require 'json'
require 'set'
require 'fileutils'
require 'English'

module SprocketsTerserWithSourceMaps
  # Removes generated dependencies no retained bundle needs.
  class Cleanup
    def initialize(manifest, age)
      @manifest = manifest
      @config = Rails.application.config.assets
      @directory = File.expand_path(manifest.directory)
      @cutoff = Time.now - age
    end

    def call
      expected_directory = File.expand_path(File.join(Rails.public_path.to_s, @config.prefix))
      return unless @directory == expected_directory

      maps = generated_files(@config.sourcemaps_prefix, 'js.map')
      sources = generated_files(@config.uncompressed_prefix, 'js')
      return unless maps && sources

      retained = retained_dependencies(maps, sources)
      remove_unretained(maps.merge(sources), retained)
    rescue KeyError, JSON::ParserError, SystemCallError
      Rails.logger.warn("Source map cleanup skipped: #{$ERROR_INFO.message}")
    end

    private

    def remove_unretained(files, retained)
      files.each do |path, variants|
        next if retained.include?(path) || recent?(variants)

        variants.each { |variant| FileUtils.rm_f(variant) }
      end
    end

    def retained_dependencies(maps, sources)
      map_urls = index_urls(maps)
      source_urls = index_urls(sources)
      retained = Set.new

      maps.each do |path, variants|
        retain_map(path, source_urls, retained) if recent?(variants)
      end

      @manifest.files.each do |filename, attributes|
        next unless attributes['logical_path'].end_with?('.js')

        retain_bundle(filename, map_urls, source_urls, retained)
      end
      retained
    end

    def retain_bundle(filename, map_urls, source_urls, retained)
      javascript = File.read(File.join(@directory, filename))
      javascript.scan(%r{^//# sourceMappingURL=(.+)$}).flatten.each do |url|
        retain_map(map_urls.fetch(url.strip), source_urls, retained)
      end
    end

    def retain_map(path, source_urls, retained)
      return unless retained.add?(path)

      map = JSON.parse(File.read(path))
      return if map['sourcesContent']

      map.fetch('sources').each do |source_url|
        retained.add(source_urls.fetch(source_url))
      end
    end

    def recent?(variants)
      variants.any? { |path| File.mtime(path) >= @cutoff }
    end

    def generated_files(prefix, extension)
      directory = generated_directory(prefix)
      return unless directory

      pattern = /-[0-9a-f]{32,64}\.#{Regexp.escape(extension)}(?:\.(?:gz|br|zst))?\z/
      Dir.glob(File.join(directory, '**', '*')).each_with_object({}) do |path, files|
        next unless File.file?(path) && pattern.match?(path)

        original = path.sub(/\.(?:gz|br|zst)\z/, '')
        (files[original] ||= []) << path
      end
    end

    def generated_directory(prefix)
      return unless prefix.is_a?(String) && !prefix.empty?

      directory = File.expand_path(File.join(@directory, prefix))
      directory if directory.start_with?("#{@directory}/")
    end

    def index_urls(files)
      files.each_key.with_object({}) do |path, urls|
        filename = File.join(@config.prefix, path.delete_prefix("#{@directory}/"))
        root = @config.sourcemaps_url_root
        url = case root
              when FalseClass, NilClass
                filename
              when Proc
                root.call(filename)
              else
                File.join(root.to_s, filename)
              end
        urls[url] = path
      end
    end
  end

  # Runs dependency cleanup after Sprockets has selected retained assets.
  module ManifestCleanup
    def clean(count = 2, age = 3600)
      result = super
      Cleanup.new(self, age).call
      result
    end
  end
end
