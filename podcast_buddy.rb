require "net/http"
require "uri"
require "json"
require "open3"
require "logger"

require "bundler/inline"
require_relative "podcast_buddy/system_dependency"

module PodcastBuddy
  def self.root
    Dir.pwd
  end

  def self.logger
    @logger ||= Logger.new($stdout, level: Logger::WARN)
  end

  def self.whisper_model
    "small.en"
  end

  def self.setup
    gemfile do
      source "https://rubygems.org"
      gem "ruby-openai"
    end

    require "openai"
    logger.info "Gems installed and loaded!"
    SystemDependency.auto_install!(:git)
    SystemDependency.auto_install!(:sdl2)
    SystemDependency.auto_install!(:whisper)
  end
end

PodcastBuddy.logger.formatter = proc do |severity, datetime, progname, msg|
  if severity.to_s == "INFO"
    "#{msg}\n"
  else
    "[#{severity}] #{msg}\n"
  end
end
PodcastBuddy.logger.info "Setting up dependencies..."
PodcastBuddy.setup
PodcastBuddy.logger.info "Setup complete."

# OpenAI API client setup
client = OpenAI::Client.new(access_token: ENV["OPENAI_ACCESS_TOKEN"], log_errors: true)

# Custom Signal class
class PodSignal
  def initialize
    @listeners = []
    @queue = Queue.new
    start_listener_thread
  end

  def subscribe(&block)
    @listeners << block
  end

  def trigger(data = nil)
    @queue << data
  end

  private

  def start_listener_thread
    Thread.new do
      loop do
        data = @queue.pop
        @listeners.each { |listener| listener.call(data) }
      end
    end
  end
end

# Signals for question detection
question_signal = PodSignal.new
end_signal = PodSignal.new

# Initialize variables
@latest_transcription = ""
@question_transcription = ""
@full_transcription = ""
@listening_for_question = false
@shutdown_flag = false
@threads = []
@transcription_queue = Queue.new

# Method to extract topics and summarize
def extract_topics_and_summarize(client, text)
  response = client.chat(parameters: {
    model: "gpt-4o",
    messages: [{ role: "user", content: "Extract topics and summarize: #{text}" }],
    max_tokens: 150
  })
  response["choices"][0]["text"].strip
end

# Method to convert text to speech
def text_to_speech(text)
  uri = URI.parse("https://api.elevenlabs.io/v1/synthesize")
  request = Net::HTTP::Post.new(uri)
  request.content_type = "application/json"
  request.body = JSON.dump({
    "text" => text,
    "voice" => "default"
  })
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    http.request(request)
  end
  File.write("response.wav", response.body)
end

# Method to handle audio stream processing
def process_audio_stream(client)
  Thread.new do
    #whisper_command = "./whisper.cpp/stream -m ./whisper.cpp/models/ggml-base.en.bin -f - -t 4 -c 1"
    whisper_command = "./whisper.cpp/stream -m ./whisper.cpp/models/ggml-#{PodcastBuddy.whisper_model}.bin -t 4 --step 500 --length 5000 --keep 500 --vad-thold 0.60 --audio-ctx 0 --keep-context -c 1"
    Open3.popen3(whisper_command) do |stdin, stdout, stderr, thread|
      stderr_thread = Thread.new do
        stderr.each { |line| PodcastBuddy.logger.error line }
      end
      stdout_thread = Thread.new do
        stdout.each { |line| PodcastBuddy.logger.debug line }
      end

      while transcription = stdout.gets
        break if @shutdown_flag

        PodcastBuddy.logger.debug "Received transcription at #{Time.now}"
        PodcastBuddy.logger.info transcription
        @full_transcription += transcription

        if @listening_for_question
          @question_transcription += transcription
        else
          @transcription_queue << transcription
        end
      end

      # Close streams and join stderr thread on shutdown
      stderr_thread.join
      stdout_thread.join
      stdin.close
      stdout.close
      stderr.close
    end
  end
end

# Method to generate show notes
def generate_show_notes(client, transcription)
  summary = extract_topics_and_summarize(client, transcription)
  File.open('show_notes.md', 'w') do |file|
    file.puts "# Show Notes"
    file.puts summary
  end
end

# Periodically summarize latest transcription
def periodic_summarization(client, interval = 15)
  Thread.new do
    loop do
      break if @shutdown_flag

      sleep interval
      latest_transcriptions = []
      latest_transcriptions << @transcription_queue.pop until @transcription_queue.empty?
      unless latest_transcriptions.empty?
        summary = extract_topics_and_summarize(client, latest_transcriptions.join)
        File.open('discussion_topics', 'a') { |file| file.puts summary }
      end
    rescue StandardError => e
      PodcastBuddy.logger.warn "[summarization] periodic summarization failed: #{e.message}"
    end
  end
end

# Handle Ctrl-C to generate show notes
Signal.trap("INT") do
  PodcastBuddy.logger.info "\nShutting down streams..."
  @shutdown_flag = true
  # Wait for all threads to finish
  @threads.compact.each(&:join)

  PodcastBuddy.logger.info "\nGenerating show notes..."
  # Will have to re-think this.  Can't syncronize from a trap (Faraday)
  #generate_show_notes(client, @full_transcription)
  exit
end

# Setup signal subscriptions
question_signal.subscribe do
  PodcastBuddy.logger.info "Question signal received"
  @listening_for_question = true
  @question_transcription.clear
end

end_signal.subscribe do
  PodcastBuddy.logger.info "End of question signal received"
  @listening_for_question = false
  response_text = "Based on the topics discussed, here is my response: #{extract_topics_and_summarize(client, @question_transcription)}"
  text_to_speech(response_text)
  system("afplay response.wav")
end

# Start audio stream processing
@threads << process_audio_stream(client)
# Start periodic summarization
@threads << periodic_summarization(client, 60)

# Main loop to wait for question and end signals
loop do
  PodcastBuddy.logger.info "Press Enter to signal a question start..."
  gets
  question_signal.trigger
  PodcastBuddy.logger.info "Press Enter to signal the end of the question..."
  gets
  end_signal.trigger
end
