# frozen_string_literal: true

module ElasticAPM
  # @api private
  module Spies
    # @api private
    class ResqueSpy

      ACTIVE_JOB_WRAPPER =
        'ActiveJob::QueueAdapters::ResqueAdapter::JobWrapper'.freeze

      def install
        install_fork_hook
        install_worker_hook
      end

      def self.set_meta(job)
        return unless (transaction = ElasticAPM.current_transaction)

        if job.payload_class_name == ACTIVE_JOB_WRAPPER
          args = job.payload['args'].first
          return unless args

          transaction.name = args['job_class']
          ElasticAPM.set_tag(:queue, args['queue_name'])
        else
          transaction.name = job.payload_class_name
          ElasticAPM.set_tag(:queue, job.queue)
        end
      end

      private

      def install_fork_hook
        ::Resque.before_first_fork do
          ElasticAPM.start(
            # logger: ::Resque.logger,
            logger: Logger.new($stdout),
            debug_transactions: true
          )
        end

      end

      # rubocop:disable Metrics/MethodLength
      def install_worker_hook
        # rubocop:disable Metrics/BlockLength
        ::Resque::Worker.class_eval do
          alias :perform_with_fork_without_elastic_apm :perform_with_fork
          alias :perform_without_elastic_apm :perform

          def perform_with_apm
            transaction = ElasticAPM.transaction nil, 'Resque'
            pp(ID: transaction.object_id)

            yield

            ts = ElasticAPM::Serializers::Transactions.new(nil).build(transaction)
            @writer.write(Marshal.dump(ts))
            @writer.write("hallo \n")

            true
          end

          def perform_with_pipe
            @reader, @writer = IO.pipe

            yield

            t = @reader.gets
            puts t.inspect

            begin
              #TODO: 
              #  (1) remove creating a new transaction and instead deserialize transaction
              #      by using ElasticAPM::Transaction.from_args(t)
              #      and then Marshal.load the transaction
              #      or
              #  (2) create an array of serialized transactions and
              #      directly send them to the server
              transaction = ElasticAPM.transaction nil, 'Resque'

              transaction.submit(:success) if transaction
            rescue Exception => e
              puts e
              ElasticAPM.report(e, handled: false)
              transaction.submit(:error) if transaction
            ensure
              transaction.release if transaction
            end
          end

          def perform_with_fork(job, &block)
            perform_with_pipe do 
              perform_with_fork_without_elastic_apm(job, &block)
            end
          end

          #def fork_per_job?
            #return true 
          #end

          def perform(job)
            if fork_per_job?
              perform_with_apm do
                ResqueSpy.set_meta(job)
                perform_without_elastic_apm(job)
              end
            else
              perform_with_pipe do 
                perform_with_apm do
                  ResqueSpy.set_meta(job)
                  perform_without_elastic_apm(job)
                end
              end
            end
          end

        end
        # rubocop:enable Metrics/BlockLength
      end
      # rubocop:enable Metrics/MethodLength
    end

    register 'Resque', 'resque', ResqueSpy.new
  end
end
