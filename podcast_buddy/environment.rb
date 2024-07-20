require "bundler/inline"
require_relative "system_dependency"

module PodcastBuddy
  module Environment
    def root
      Dir.pwd
    end

    def logger
      @logger ||= Logger.new($stdout, level: Logger::DEBUG)
    end

    def whisper_model
      "small.en"
    end

    def setup
      logger.formatter = proc do |severity, datetime, progname, msg|
        if severity.to_s == "INFO"
          "#{msg}\n"
        else
          "[#{severity}] #{msg}\n"
        end
      end

      logger.info "Setting up dependencies..."

      gemfile do
        source "https://rubygems.org"
        gem "ruby-openai"
      end

      require "openai"
      logger.info "Gems installed and loaded!"
      SystemDependency.auto_install!(:git)
      SystemDependency.auto_install!(:sdl2)
      SystemDependency.auto_install!(:whisper)
      logger.info "Setup complete."
    end
  end
end
