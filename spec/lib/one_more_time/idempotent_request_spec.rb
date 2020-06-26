# frozen_string_literal: true

RSpec.describe OneMoreTime::IdempotentRequest, type: :model do
  let(:idempotency_key) { SecureRandom.alphanumeric }
  let(:response_code) { nil }
  let(:response_body) { nil }
  let(:locked_at) { nil }
  let(:idempotent_request) do
    described_class.create!(
      idempotency_key: idempotency_key,
      response_code: response_code,
      response_body: response_body,
      locked_at: locked_at,
    )
  end

  let(:random_response_code) { rand(200..599).to_s }
  let(:random_response_body) { SecureRandom.alphanumeric }

  describe "#execute" do
    subject(:execute) do
      idempotent_request.execute { yielded_result }
    end

    let(:yielded_result) { SecureRandom.alphanumeric }

    it "yields" do
      expect { |block| idempotent_request.execute(&block) }.to yield_control
    end

    it { is_expected.to eq(yielded_result) }

    context "when the request is already finished" do
      before { allow(idempotent_request).to receive(:finished?).and_return(true) }

      it "does not yield" do
        expect { |block| idempotent_request.execute(&block) }.not_to yield_control
      end
    end

    context "when an error is raised" do
      subject(:execute) do
        idempotent_request.execute { raise exception }
      end

      context "when a PermanentError is raised" do
        let(:exception) { described_class::const_get(:PermanentError) }

        it "rescues the exception" do
          expect { execute }.not_to raise_error
        end
      end

      context "when a StandardError is raised" do
        let(:exception) { StandardError }

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
  end

  describe "#success" do
    subject(:call) do
      idempotent_request.success { result }
    end

    let(:result) do
      {
        attributes_to_save: {
          response_code: random_response_code,
          response_body: random_response_body,
        }
      }
    end
    let(:locked_at) { Time.current }

    it "unlocks the record" do
      expect { call }.to change { idempotent_request.locked_at }.from(locked_at).to(nil)
    end

    it "yields" do
      expect { |block| idempotent_request.success(&block) }.to yield_control
    end

    context "when success_attributes have been specified" do
      before do
        idempotent_request.success_attributes { |result| result[:attributes_to_save] }
      end

      it "saves the attributes" do
        call
        expect(idempotent_request.reload).to have_attributes(result[:attributes_to_save])
      end
    end

    context "when an error is raised" do
      let(:exception) { StandardError.new }
      let(:unrelated_record) { described_class.new(idempotency_key: idempotency_key + "_foo") }
      let(:call_with_rescue) do
        idempotent_request.success do
          unrelated_record.save!
          raise exception
        end
      rescue StandardError
        nil
      end

      it "rolls back any changes" do
        expect { call_with_rescue }.not_to change { unrelated_record.persisted? }
      end

      it "calls failure!" do
        allow(idempotent_request).to receive(:failure!)
        call_with_rescue
        expect(idempotent_request).to have_received(:failure!).with(exception: exception)
      end
    end
  end

  describe "#failure!" do
    subject(:call_with_rescue) do
      call
    rescue StandardError
      nil
    end

    let(:call) { idempotent_request.failure!(params) }
    let(:params) { {} }
    let(:locked_at) { Time.current }

    shared_examples_for "it fails the request" do
      it "saves the given attributes" do
        call_with_rescue
        expect(idempotent_request.reload).to have_attributes(params.except(:exception))
      end

      it "unlocks the record" do
        expect { call_with_rescue }.to change { idempotent_request.locked_at }.from(locked_at).to(nil)
      end

      it "raises a PermanentError" do
        expect { call }.to raise_error(described_class::const_get(:PermanentError))
      end
    end

    it_behaves_like "it fails the request"

    context "when the exception is specified" do
      let(:exception_message) { "foo bar" }
      let(:params) { { exception: StandardError.new(exception_message) } }

      it_behaves_like "it fails the request"

      context "when failure_attributes have been specified" do
        before do
          idempotent_request.failure_attributes do |exception|
            {
              response_code: random_response_code,
              response_body: exception.message,
            }
          end
        end

        it_behaves_like "it fails the request"
      end
    end

    context "when the response is specified" do
      let(:params) { { response_code: random_response_code, response_body: random_response_body } }

      it_behaves_like "it fails the request"
    end
  end

  describe "#finished?" do
    subject { idempotent_request.finished? }

    it { is_expected.to be(false) }

    context "when the response_code is present" do
      let(:response_code) { random_response_code }

      it { is_expected.to be(true) }
    end

    context "when the response_body is present" do
      let(:response_body) { random_response_body }

      it { is_expected.to be(true) }
    end
  end
end
