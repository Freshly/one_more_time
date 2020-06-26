# frozen_string_literal: true

class OneMoreTime
  class IdempotentRequest < ActiveRecord::Base
    def success_attributes(&block)
      @success_attributes_block = block
    end

    def failure_attributes(&block)
      @failure_attributes_block = block
    end

    def execute
      # No-op the request if we already have a saved response.
      return if finished?

      begin
        yield if block_given?
      rescue PermanentError
        # Something has called .failure!, so we assume there is now a saved response
        # and can just no-op
      rescue StandardError
        update_and_unlock
        raise
      end
      # TODO: raise unless finished?
    end

    def success
      ActiveRecord::Base.transaction do
        result = yield if block_given?
        attrs = @success_attributes_block&.call(result) || {}
        update_and_unlock(attrs)
      end
    rescue StandardError => exception
      failure!(exception: exception)
    end

    def failure!(exception: nil, response_code: nil, response_body: nil)
      attrs = (exception.present? && @failure_attributes_block&.call(exception)) || {}
      attrs.merge!({response_code: response_code, response_body: response_body}.compact)
      update_and_unlock(attrs)
      raise PermanentError
    end

    def finished?
      response_code.present? || response_body.present?
    end

    private

    class PermanentError < StandardError; end

    def update_and_unlock(attrs={})
      update!({ locked_at: nil }.merge(attrs.slice(:response_code, :response_body)))
    end
  end
end
