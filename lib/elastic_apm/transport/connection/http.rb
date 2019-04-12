# frozen_string_literal: true

require 'http'
require 'concurrent'
require 'zlib'

require 'elastic_apm/transport/connection/proxy_pipe'

module ElasticAPM
  module Transport
    class Connection
      # @api private
      class Http
        include Logging

        def initialize(config, url, metadata, headers: {}, ssl_context: nil)
          @config = config
          @mutex = Mutex.new
          @closed = Mutex.new

          @rd, @wr = ProxyPipe.pipe(
            compress: @config.http_compression?
          )
          @request = init_request(url, headers, ssl_context)
          append(metadata)
        end

        def write(str)
          append(str)
          @wr.bytes_sent
        end

        # rubocop:disable Metrics/LineLength
        def close(reason)
          return if closed?

          debug "Closing request from #{Thread.current.object_id} with reason #{reason}"
          return unless @closed.try_lock
          @mutex.synchronize do
            @wr&.close(reason)
          end
          # TODO: SIMI: make read timeout configurable or work with thread pools here
          return if @request&.join(5)

          error 'Request could not finish in time, terminating request'
          @request.kill
        end
        # rubocop:enable Metrics/LineLength

        def inspect
          format(
            '%s closed: %s>',
            super.split.first,
            closed?
          )
        end

        def closed?
          @closed.locked?
        end

        private

        def append(str)
          @mutex.synchronize do
            @wr.write(str)
          end
        end

        # rubocop:disable Metrics/LineLength
        def init_request(url, headers, ssl_context)
          client = build_client(headers)
          debug format('Opening new request from %s', Thread.current.object_id)
          Thread.new do
            begin
              post(client, url, ssl_context)
            rescue Exception => e
              error "Couldn't establish connection to APM Server:\n%p", e.inspect
            end
          end
        end
        # rubocop:enable Metrics/LineLength

        def build_client(headers)
          HTTP.headers(headers).tap do |client|
            return client unless @config.proxy_address && @config.proxy_port

            client.via(
              @config.proxy_address,
              @config.proxy_port,
              @config.proxy_username,
              @config.proxy_password,
              @config.proxy_headers
            )
          end
        end

        def post(client, url, ssl_context)
          resp = client.post(
            url,
            body: @rd,
            ssl_context: ssl_context
          ).flush

          if resp&.status == 202
            debug 'APM Server responded with status 202'
          elsif resp
            error "APM Server responded with an error:\n%p", resp.body.to_s
          end
        end
      end
    end
  end
end
