# frozen_string_literal: true

RSpec.describe OneMoreTime do
  let(:idempotency_key) { SecureRandom.alphanumeric }
  let(:request_path) { SecureRandom.alphanumeric }
  let(:request_body) { SecureRandom.alphanumeric }

  describe ".start_request!" do
    subject(:call) do
      described_class.start_request!(
        idempotency_key: idempotency_key,
        request_path: request_path,
        request_body: request_body,
      )
    end

    before do
      Timecop.freeze(Time.current.round)
      allow(ActiveRecord::Base).to receive(:transaction).and_call_original
      # TODO: without the following we'll fail with "cannot set transaction isolation in a nested transaction".
      # Can we disable the wrapping transaction for just these tests instead?
      allow(ActiveRecord::Base).to receive(:transaction).with(isolation: :serializable).and_yield
    end

    context "when a matching record exists" do
      let(:existing_locked_at) { nil }
      let(:existing_request_path) { request_path }
      let(:existing_request_body) { request_body }
      let(:existing_response_code) { nil }
      let!(:existing_request) do
        described_class::IdempotentRequest.create!(
          idempotency_key: idempotency_key,
          request_path: existing_request_path,
          request_body: existing_request_body,
          response_code: existing_response_code,
          locked_at: existing_locked_at,
        )
      end

      it { is_expected.to eq(existing_request) }

      it "locks the record" do
        expect { call }.to change { existing_request.reload.locked_at }.from(nil).to(Time.current)
      end

      context "when the existing record has a stored response" do
        let(:existing_response_code) { 200 }

        it "does not lock the record" do
          expect { call }.not_to change { existing_request.reload.locked_at }
        end
      end

      context "when the existing record is already locked" do
        let(:existing_locked_at) { Time.current - 1.second }

        it "raises RequestInProgressError" do
          expect { call }.to raise_error(described_class::RequestInProgressError)
        end
      end

      context "when the stored request path has a different value" do
        let(:existing_request_path) { request_path + "_nope" }

        it "raises RequestMismatchError" do
          expect { call }.to raise_error(described_class::RequestMismatchError)
        end

        context "when the request_path is not specified" do
          let(:request_path) { "" }

          it "does not raise" do
            expect { call }.not_to raise_error
          end
        end
      end

      context "when the stored request body has a different value" do
        let(:existing_request_body) { request_body + "_nope" }

        it "raises RequestMismatchError" do
          expect { call }.to raise_error(described_class::RequestMismatchError)
        end

        context "when the request_body is not specified" do
          let(:request_body) { "" }

          it "does not raise" do
            expect { call }.not_to raise_error
          end
        end
      end

      context "when a serialization failure occurs" do
        before do
          allow(described_class::IdempotentRequest).to receive(:find_by).and_raise(ActiveRecord::SerializationFailure)
        end

        it "raises RequestInProgressError" do
          expect { call }.to raise_error(described_class::RequestInProgressError)
        end
      end
    end

    context "when no matching record exists" do
      let(:expected_attributes) do
        {
          idempotency_key: idempotency_key,
          locked_at: Time.current,
          request_path: request_path,
          request_body: request_body,
        }
      end

      it { is_expected.to be_a(described_class::IdempotentRequest) }

      it "creates a new record" do
        expect { call }.to change { described_class::IdempotentRequest.count }.by(1)
        expect(described_class::IdempotentRequest.last).to have_attributes(expected_attributes)
      end
    end
  end
end
