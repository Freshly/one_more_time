# frozen_string_literal: true

require "active_record"
require "one_more_time/idempotent_request"

module OneMoreTime
  class Error < StandardError; end
  class RequestInProgressError < Error; end
  class RequestMismatchError < Error; end

  class << self
    def start_request!(idempotency_key:, request_path: nil, request_body: nil)
      IdempotentRequest.create!(
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
        existing_request = IdempotentRequest.find_by(idempotency_key: idempotency_key, locked_at: nil)
        validate_incoming_request!(existing_request, request_path, request_body)
        existing_request.update!(locked_at: Time.current) unless existing_request.finished?
        existing_request
      end
    end

    private

    def validate_incoming_request!(existing_request, request_path, request_body)
      raise RequestInProgressError if existing_request.blank?
      raise RequestMismatchError if request_path.present? && request_path != existing_request.request_path
      raise RequestMismatchError if request_body.present? && request_body != existing_request.request_body
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
