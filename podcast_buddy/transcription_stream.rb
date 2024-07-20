require "observer"
require "thread"
require "open3"

module PodcastBuddy
  class TranscriptionStream
    include Observable

    def initialize(model_path:, device_id: 1, threads: 4, step: 2000, length: 5000, keep: 500, vad_thold: 0.60, audio_ctx: 0, keep_context: true)
      @model_path = model_path
      @device_id = device_id
      @threads = threads
      @step = step
      @length = length
      @keep = keep
      @vad_thold = vad_thold
      @audio_ctx = audio_ctx
      @keep_context = keep_context
      @shutdown_flag = false
      @mutex = Mutex.new
      @threads = []
    end

    def start
      @threads << Thread.new { run }
    end

    def stop
      @shutdown_flag = true
      @threads.each(&:join)
    end

    def run
      whisper_stream_command = "#{PodcastBuddy.root}/whisper.cpp/build/bin/stream -m #{@model_path} -t #{@threads} --step #{@step} --length #{@length} --keep #{@keep} --vad-thold #{@vad_thold} --audio-ctx #{@audio_ctx} #{@keep_context ? "--keep-context" : ""} -c #{@device_id}"
      Open3.popen3(whisper_stream_command) do |stdin, stdout, stderr, thread|
        @threads << Thread.new do
          stderr.each { |line| PodcastBuddy.logger.error "ERROR: #{line}" }
        end
        @threads << Thread.new do
          stdout.each { |line| PodcastBuddy.logger.debug line }
        end

        while transcription = stdout.gets
          break if @shutdown_flag

          @mutex.synchronize do
            puts "DEBUG: Received transcription at #{Time.now}"
            puts transcription

            changed
            notify_observers(transcription)
          end
        end

        stdin.close
        stdout.close
        stderr.close
      end
    end
  end
end
