# frozen_string_literal: true

require 'concurrent'
require 'zlib'

require 'elastic_apm/transport/connection/http'

module ElasticAPM
  module Transport
    # @api private
    class Connection
      include Logging

      def initialize(config, metadata)
        @config = config
        @metadata = JSON.fast_generate(metadata)
        @url = config.server_url + '/intake/v2/events'
        @headers = build_headers
        @ssl_context = build_ssl_context

        @mutex = Mutex.new
      end

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def write(str)
        return false if @config.disable_send

        begin
          w = 0
          @mutex.synchronize do
            connect if http.nil? || http.closed?
            w = http.write(str)
          end
          flush(:api_request_size) if w >= @config.api_request_size
        rescue IOError => e
          error('Connection error: %s', e.inspect)
          flush(:ioerror)
        rescue Errno::EPIPE => e
          error('Connection error: %s', e.inspect)
          flush(:broken_pipe)
        end
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def flush(reason = :force)
        @mutex.synchronize do
          return if http.nil?
          http.close(reason)
        end
      end

      def inspect
        format(
          '@%s http connection closed? :%s>',
          super.split.first,
          http.closed?
        )
      end

      attr_reader :http

      private

      def connect
        schedule_closing if @config.api_request_time
        @http = Http.new(@config, @url, @metadata,
          headers: @headers,
          ssl_context: @ssl_context)
      end
      # rubocop:enable

      def schedule_closing
        @close_task&.cancel
        @close_task =
          Concurrent::ScheduledTask.execute(@config.api_request_time) do
            flush(:timeout)
          end
      end

      HEADERS = {
        'Content-Type' => 'application/x-ndjson',
        'Transfer-Encoding' => 'chunked'
      }.freeze
      GZIP_HEADERS = HEADERS.merge(
        'Content-Encoding' => 'gzip'
      ).freeze

      def build_headers
        (
          @config.http_compression? ? GZIP_HEADERS : HEADERS
        ).dup.tap do |headers|
          if (token = @config.secret_token)
            headers['Authorization'] = "Bearer #{token}"
          end
        end
      end

      def build_ssl_context
        return unless @config.use_ssl? && @config.server_ca_cert

        OpenSSL::SSL::SSLContext.new.tap do |context|
          context.ca_file = @config.server_ca_cert
        end
      end
    end
  end
end
