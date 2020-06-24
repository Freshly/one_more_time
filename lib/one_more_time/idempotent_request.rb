# frozen_string_literal: true

module OneMoreTime
  class IdempotentRequest < ActiveRecord::Base
    class Error < StandardError; end
    class PermanentError < Error; end
    class RequestInProgressError < Error; end
    class RequestMismatchError < Error; end

    def success_attributes(&block)
      @success_attributes_block = block
    end

    def failure_attributes(&block)
      @failure_attributes_block = block
    end

    def saved_response(&block)
      @saved_response_block = block
    end

    def execute
      # No-op the request if we already have a saved response.
      return call_saved_response if finished?

      begin
        yield if block_given?
      rescue IdempotentRequest::PermanentError => exception
        failure_attributes = @failure_attributes_block&.call(exception) || {}
        unlock!(response_code: failure_attributes[:response_code], response_body: failure_attributes[:response_body])
        call_saved_response
      rescue StandardError
        unlock!
        raise
      end
    end

    def unlock!(response_code: nil, response_body: nil)
      attrs = { locked_at: nil }
      attrs[:response_code] = response_code if response_code.present?
      attrs[:response_body] = response_body if response_body.present?
      update!(attrs)
    end

    def success!
      ActiveRecord::Base.transaction do
        result = yield if block_given?
        success_attributes = @success_attributes_block&.call(result) || {}
        unlock!(response_code: success_attributes[:response_code], response_body: success_attributes[:response_body])
      end
    rescue StandardError
      raise PermanentError
    end

    def failure!
      raise PermanentError
    end

    def finished?
      response_code.present?
    end

    private

    def call_saved_response
      @saved_response_block.call(self) if @saved_response_block.present?
    end

    class << self
      def start!(idempotency_key:, request_path: nil, request_body: nil)
        create!(
          idempotency_key: idempotency_key,
          locked_at: Time.current,
          request_path: request_path,
          request_body: request_body,
        )
      rescue ActiveRecord::RecordNotUnique
        # Our UNIQUE constraint was violated, so a request with the given idempotency
        # key already exists. Use the highest transaction isolation level to atomically
        # load that request record and mark it as "locked".
        # Similar to Rails create_or_find_by, the race condition here is if another
        # client deleted the request record exactly at this point. For this specific
        # model there is basically no risk of that happening.
        serializable_transaction do
          existing_request = find_by(idempotency_key: idempotency_key, locked_at: nil)
          validate_incoming_request!(existing_request, request_path, request_body)
          existing_request.update!(locked_at: Time.current) unless existing_request.finished?
          existing_request
        end
      end

      private

      def validate_incoming_request!(existing_request, request_path, request_body)
        raise RequestInProgressError if existing_request.blank?
        raise RequestMismatchError if existing_request.request_path.present? && existing_request.request_path != request_path
        raise RequestMismatchError if existing_request.request_body.present? && existing_request.request_body != request_body
      end

      def serializable_transaction
        ActiveRecord::Base.transaction(isolation: :serializable) do
          yield
        end
      rescue ActiveRecord::SerializationFailure
        raise RequestInProgressError
      end
    end
  end
end
