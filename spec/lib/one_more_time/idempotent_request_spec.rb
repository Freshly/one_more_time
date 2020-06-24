# frozen_string_literal: true

RSpec.describe OneMoreTime::IdempotentRequest, type: :model do
  let(:idempotency_key) { SecureRandom.alphanumeric }
  let(:request_path) { SecureRandom.alphanumeric }
  let(:request_body) { SecureRandom.alphanumeric }
  let(:response_code) { nil }
  let(:response_body) { nil }
  let(:locked_at) { nil }
  let(:idempotent_request) do
    described_class.create!(
      idempotency_key: idempotency_key,
      request_path: request_path,
      request_body: request_body,
      response_code: response_code,
      response_body: response_body,
      locked_at: locked_at,
    )
  end

  let(:random_response_code) { rand(200..599).to_s }
  let(:random_response_body) { SecureRandom.alphanumeric }

  describe ".start!" do
    subject(:call) do
      described_class.start!(
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
        described_class.create!(
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
        let(:existing_response_code) { random_response_code }

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

      context "when the request paths mismatch" do
        let(:existing_request_path) { request_path + "_nope" }

        it "raises RequestMismatchError" do
          expect { call }.to raise_error(described_class::RequestMismatchError)
        end
      end

      context "when the request bodies mismatch" do
        let(:existing_request_body) { request_body + "_nope" }

        it "raises RequestMismatchError" do
          expect { call }.to raise_error(described_class::RequestMismatchError)
        end
      end

      context "when a serialization failure occurs" do
        before do
          allow(described_class).to receive(:find_by).and_raise(ActiveRecord::SerializationFailure)
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

      it { is_expected.to be_a(described_class) }

      it "creates a new record" do
        expect { call }.to change { described_class.count }.by(1)
        expect(described_class.last).to have_attributes(expected_attributes)
      end
    end
  end

  describe "#execute" do
    subject(:execute) do
      idempotent_request.execute { yielded_result }
    end

    let(:saved_response) { "#{response_code}-#{response_body}" }
    let(:yielded_result) { SecureRandom.alphanumeric }

    before do
      idempotent_request.saved_response { saved_response }
    end

    it "yields" do
      expect { |block| idempotent_request.execute(&block) }.to yield_control
    end

    it { is_expected.to eq(yielded_result) }

    context "when there is a saved response" do
      let(:response_code) { random_response_code }
      let(:response_body) { random_response_body }

      it "does not yield" do
        expect { |block| idempotent_request.execute(&block) }.not_to yield_control
      end

      it { is_expected.to eq(saved_response) }
    end

    context "when a PermanentError is raised" do
      subject(:execute) do
        idempotent_request.execute { raise exception }
      end

      let(:exception_message) { SecureRandom.alphanumeric }
      let(:exception) { described_class::PermanentError.new(exception_message) }

      before do
        idempotent_request.failure_attributes do |exception|
          {
            response_code: random_response_code,
            response_body: exception.message,
          }
        end
      end

      it { is_expected.to eq(saved_response) }

      it "saves the error response and unlocks" do
        execute
        expect(idempotent_request.reload).to have_attributes(
          locked_at: nil,
          response_code: random_response_code,
          response_body: exception_message,
        )
      end
    end

    context "when a StandardError is raised" do
      subject(:execute) do
        idempotent_request.execute { raise exception }
      end

      let(:exception) { StandardError.new }

      it "unlocks" do
        begin
          execute
        rescue StandardError
          nil
        end
        expect(idempotent_request.reload.locked_at).to be(nil)
      end

      it "re-raises" do
        expect { execute }.to raise_error(exception)
      end
    end
  end

  describe "#unlock" do
    subject(:call) { idempotent_request.unlock! }

    let(:locked_at) { Time.current }
    let(:response_code) { random_response_code }
    let(:response_body) { random_response_body }

    it "sets locked_at to nil" do
      call
      expect(idempotent_request.reload).to have_attributes(
        locked_at: nil,
        response_code: response_code,
        response_body: response_body,
      )
    end

    context "when attributes are present" do
      subject(:call) { idempotent_request.unlock!(response_code: "foo", response_body: "bar") }

      it "sets locked_at to nil" do
        call
        expect(idempotent_request.reload).to have_attributes(
          locked_at: nil,
          response_code: "foo",
          response_body: "bar",
        )
      end
    end
  end

  describe "#success!" do
    subject(:call) { idempotent_request.success! }

    let(:locked_at) { Time.current }

    it "unlocks the record" do
      expect { call }.to change { idempotent_request.locked_at }.from(locked_at).to(nil)
    end

    it "yields" do
      expect { |block| idempotent_request.success!(&block) }.to yield_control
    end

    context "when success_attributes have been specified" do
      let(:attributes_to_save) do
        {
          response_code: random_response_code,
          response_body: random_response_body,
        }
      end

      before do
        idempotent_request.success_attributes do
          attributes_to_save
        end

        allow(idempotent_request).to receive(:update!)
      end

      it "saves the attributes" do
        call
        expect(idempotent_request).to have_received(:update!).with(hash_including(attributes_to_save))
      end
    end

    context "when an error is raised" do
      let(:unrelated_record) { described_class.new(idempotency_key: idempotency_key + "_foo") }
      let(:call_with_rescue) do
        idempotent_request.success! do
          unrelated_record.save!
        end
      rescue StandardError
        nil
      end

      before do
        allow(idempotent_request).to receive(:update!).and_raise("something went wrong")
      end

      it "raises a PermanentError" do
        expect { call }.to raise_error(described_class::PermanentError)
      end

      it "does not unlock the record" do
        expect { call_with_rescue }.not_to change { idempotent_request.locked_at }
      end

      it "rolls back the transaction" do
        expect { call_with_rescue }.not_to change { unrelated_record.persisted? }
      end
    end
  end

  describe "#finished?" do
    subject { idempotent_request.finished? }

    it { is_expected.to be(false) }

    context "when the response_code is present" do
      let(:response_code) { rand(0..500) }

      it { is_expected.to be(true) }
    end
  end
end
