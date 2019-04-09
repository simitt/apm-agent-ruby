# frozen_string_literal: true

require 'http'
require 'concurrent'
require 'zlib'

require 'elastic_apm/transport/connection/proxy_pipe'
require 'elastic_apm/transport/connection/state'

module ElasticAPM
  module Transport
    # rubocop:disable Metrics/ClassLength
    # @api private
    class Connection
      include Logging

      HEADERS = {
        'Content-Type' => 'application/x-ndjson',
        'Transfer-Encoding' => 'chunked'
      }.freeze
      GZIP_HEADERS = HEADERS.merge(
        'Content-Encoding' => 'gzip'
      ).freeze

      def initialize(config, metadata)
        @config = config
        @metadata = JSON.fast_generate(metadata)

        @url = config.server_url + '/intake/v2/events'
        @headers = build_headers
        @client = build_client
        @ssl_context = build_ssl_context

        @mutex = Mutex.new
        @state = State.new
      end

      attr_reader :state

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def write(str)
        return if @config.disable_send

        connect
        append(str)

        return true unless @wr.bytes_sent >= @config.api_request_size

        flush(:api_request_size)

        true
      rescue IOError => e
        error('Connection error: %s', e.inspect)
        flush(:ioerror)
        nil
      rescue Errno::EPIPE => e
        error('Connection error: %s', e.inspect)
        flush(:broken_pipe)
        nil
      rescue Exception => e
        error('Connection error: %s', e.inspect)
        flush(:exception)
        nil
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def connected?
        state.connected?
      end

      def flush(reason = :force)
        state.hold do |state|
          return state.value if state.disconnected?

          debug "Closing request from #{Thread.current.object_id}"
          @wr&.close(reason)
        end

        @request_thread&.join(2)
      end

      private

      def build_headers
        (
          @config.http_compression? ? GZIP_HEADERS : HEADERS
        ).dup.tap do |headers|
          if (token = @config.secret_token)
            headers['Authorization'] = "Bearer #{token}"
          end
        end
      end

      def build_client
        HTTP.headers(@headers).tap do |client|
          configure_proxy(client)
        end
      end

      def configure_proxy(client)
        return client unless @config.proxy_address && @config.proxy_port

        client.via(
          @config.proxy_address,
          @config.proxy_port,
          @config.proxy_username,
          @config.proxy_password,
          @config.proxy_headers
        )
      end

      def build_ssl_context
        return unless @config.use_ssl? && @config.server_ca_cert

        OpenSSL::SSL::SSLContext.new.tap do |context|
          context.ca_file = @config.server_ca_cert
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def connect
        state.hold do |state|
          return state.value unless state.disconnected?

          debug format('Opening new request from %s', Thread.current.object_id)
          @rd, @wr = ProxyPipe.pipe(
            on_first_read: state.method(:connected!),
            compress: @config.http_compression?
          )

          open_post_request_in_thread

          schedule_closing if @config.api_request_time

          append(@metadata)
        end
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      def open_post_request_in_thread
        @request_thread = Thread.new do
          state.connecting!

          begin
            resp = @client.post(
              @url,
              body: @rd,
              ssl_context: @ssl_context
            ).flush

            if resp&.status == 202
              debug 'APM Server responded with status 202'
            elsif resp
              error "APM Server responded with an error:\n%p", resp.body.to_s
            end
          rescue Exception => e
            error "Couldn't establish connection to APM Server:\n%p", e.inspect
          ensure
            if @wr
              @wr.close(:request) unless @wr&.closed?
            end

            @close_task&.cancel
            state.disconnected!
          end
        end
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize

      def schedule_closing
        @close_task =
          Concurrent::ScheduledTask.execute(@config.api_request_time) do
            @close_task = nil # inception
            flush(:api_request_time)
          end
      end

      def append(str)
        @wr.write(str)
        str
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
