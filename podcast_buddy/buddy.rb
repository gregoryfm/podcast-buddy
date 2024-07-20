# frozen_string_literal: true

require "observer"
require "thread"
require "net/http"
require "json"

module PodcastBuddy
  class Buddy
    include Observable

    def initialize(client, transcription_stream, summarization_interval = 60)
      @client = client
      @transcription_stream = transcription_stream
      @transcription_context = ""
      @notes = ""
      @question_context = ""
      @answering_question = false
      @summarization_interval = summarization_interval
      @mutex = Mutex.new
      @observers = []
      setup_transcription_listener
      start_periodic_summarization
    end

    def ask_question
      @mutex.synchronize do
        @answering_question = true
        @question_context = ""
      end
    end

    def stop_question
      @mutex.synchronize do
        @answering_question = false
        answer_question
      end
    end

    def interrupt_answer
      @mutex.synchronize do
        @answering_question = false
        start_listening
      end
    end

    def start_listening
      @transcription_stream.start
    end

    def stop_listening
      @transcription_stream.stop
    end

    def update(transcription)
      @mutex.synchronize do
        if @answering_question
          @question_context += transcription
        else
          @transcription_context += transcription
        end
      end
    end

    def add_observer(&block)
      @observers << block
    end

    private

    def setup_transcription_listener
      @transcription_stream.add_observer(self)
    end

    def start_periodic_summarization
      Thread.new do
        loop do
          sleep @summarization_interval
          summarize_and_store_notes unless @answering_question
        end
      end
    end

    def summarize_and_store_notes
      summary = extract_topics_and_summarize(@transcription_context)
      @notes += summary
      @transcription_context = ""
      emit_event(@notes)
    end

    def answer_question
      stop_listening
      response_text = generate_answer(@question_context)
      text_to_speech(response_text)
      #system("afplay response.wav")
      start_listening
    end

    def emit_event(event)
      @observers.each { |observer| observer.call(event) }
    end

    def extract_topics_and_summarize(text)
      response = @client.chat(parameters: {
        model: "gpt-4o",
        prompt: "Extract topics and summarize: #{text}",
        max_tokens: 150
      })
      response["choices"][0]["text"].strip
    rescue StandardError => e
      PodcastBuddy.logger.error "[answer] Unable to extract and summarize topics #{e.message}"
    end

    def generate_answer(question_context)
      response = @client.chat(parameters: {
        model: "gpt-4o",
        prompt: "Answer the following question based on the context: #{question_context}",
        max_tokens: 150
      })
      response["choices"][0]["text"].strip
    rescue StandardError => e
      PodcastBuddy.logger.error "[answer] Unable to answer question: #{e.message}"
      "I'm sorry, but I'm not able to answer any questions at this time."
    end

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

    attr_reader :notes
  end
end
