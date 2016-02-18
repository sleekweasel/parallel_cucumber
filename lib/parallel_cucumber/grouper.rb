require 'English'
require 'erb'
require 'json'
require 'open3'
require 'tempfile'
require 'yaml'

module ParallelCucumber
  class Grouper
    class << self
      def all_runnable_scenarios(options)
        distribution_data = generate_dry_run_report(options)
        distribution_data.map do |feature|
          next if feature['elements'].nil?
          feature['elements'].map do |scenario|
            "#{feature['uri']}:#{scenario['line']}" if ['Scenario', 'Scenario Outline'].include?(scenario['keyword'])
          end
        end.flatten.compact
      end

      private

      def generate_dry_run_report(options)
        cucumber_options = options[:cucumber_options]
        cucumber_options = expand_profiles(cucumber_options) unless cucumber_config_file.nil?
        cucumber_options = cucumber_options.gsub(/(--format|-f|--out|-o)\s+[^\s]+/, '')
        result = nil

        Tempfile.open(%w(dry-run .json)) do |f|
          dry_run_options = "--dry-run --format json --out #{f.path}"

          cmd = "cucumber #{cucumber_options} #{dry_run_options} #{options[:cucumber_args].join(' ')}"
          _stdout, stderr, status = Open3.capture3(cmd)
          f.close

          if status != 0
            cmd = "bundle exec #{cmd}" if ENV['BUNDLE_BIN_PATH']
            raise("Can't generate dry run report, command exited with #{status}:\n\t#{cmd}\n\t#{stderr}")
          end

          content = File.read(f.path)

          result = begin
            JSON.parse(content)
          rescue JSON::ParserError
            content = content.length > 1024 ? "#{content[0...1000]} ...[TRUNCATED]..." : content
            raise("Can't parse JSON from dry run:\n#{content}")
          end
        end
        result
      end

      def cucumber_config_file
        Dir.glob('{,.config/,config/}cucumber{.yml,.yaml}').first
      end

      def expand_profiles(cucumber_options)
        config = YAML.load(ERB.new(File.read(cucumber_config_file)).result)
        _expand_profiles(cucumber_options, config)
      end

      def _expand_profiles(options, config)
        expand_next = false
        options.split.map do |option|
          case
          when %w(-p --profile).include?(option)
            expand_next = true
            next
          when expand_next
            expand_next = false
            _expand_profiles(config[option], config)
          else
            option
          end
        end.compact.join(' ')
      end
    end # class
  end # Grouper
end # ParallelCucumber
