require "net/http"
require "uri"
require "json"
require "open3"
require "logger"

require "bundler/inline"
require_relative "podcast_buddy/buddy"
require_relative "podcast_buddy/environment"
require_relative "podcast_buddy/system_dependency"
require_relative "podcast_buddy/transcription_stream"

module PodcastBuddy
  extend Environment
end

PodcastBuddy.setup
