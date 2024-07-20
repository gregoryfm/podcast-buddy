require "openai"
require_relative "podcast_buddy"

# OpenAI API client setup
client = OpenAI::Client.new(api_key: "your_openai_api_key")

# Initialize the TranscriptionStream class
transcription_stream = PodcastBuddy::TranscriptionStream.new(
  model_path: "#{PodcastBuddy.root}/whisper.cpp/models/ggml-small.en.bin",
  device_id: 1,
  threads: 4,
  step: 2000,
  length: 5000,
  keep: 500,
  vad_thold: 0.60,
  audio_ctx: 0,
  keep_context: true
)

# Initialize the PodcastBuddy class
buddy = PodcastBuddy::Buddy.new(client, transcription_stream)

buddy.start_listening

# Handle Ctrl-C to shutdown
Signal.trap("INT") do
  puts "\nShutting down..."
  buddy.stop_listening
  puts "Generating show notes..."
  File.write("show_notes.md", buddy.notes)
  exit
end

# Main loop to wait for question and end signals
loop do
  puts "Press Enter to signal a question start..."
  gets
  buddy.ask_question
  puts "Press Enter to signal the end of the question..."
  gets
  buddy.stop_question
end

