# frozen_string_literal: true

require 'elastic_apm/transport/connection'

module ElasticAPM
  module Transport
    RSpec.describe Connection do
      let(:config) { Config.new(http_compression: false) }
      let(:metadata) { Serializers.new(config).serialize(Metadata.new(config)) }
      subject { described_class.new(config, metadata) }

      describe '#initialize' do
        it 'is has no active connection' do
          expect(subject.http).to be nil
        end
      end

      describe 'write' do
        it 'opens a connection and writes' do
          stub = build_stub(body: /{"msg": "hey!"}/)

          subject.write('{"msg": "hey!"}')
          sleep 0.2

          expect(subject.http.closed?).to be false

          subject.flush
          expect(subject.http.closed?).to be true

          expect(stub).to have_been_requested
        end

        context 'when disable_send' do
          let(:config) { Config.new disable_send: true }

          it 'does nothing' do
            stub = build_stub(body: /{"msg": "hey!"}/)

            subject.write('{"msg": "hey!"}')

            expect(subject.http).to be nil

            subject.flush

            expect(subject.http).to be nil
            expect(stub).to_not have_been_requested
          end
        end
      end

      it 'has a fitting user agent' do
        stub = build_stub(
          headers: {
            'User-Agent' => %r{
              \Aelastic-apm-ruby/(\d+\.)+\d+\s
              http.rb/(\d+\.)+\d+\s
              j?ruby/(\d+\.)+\d+\z
            }x
          }
        )
        subject.write('{}')
        subject.flush
        expect(stub).to have_been_requested
      end

      describe 'secret token' do
        let(:config) { Config.new(secret_token: 'asd') }

        it 'adds an Authorization header if secret token provided' do
          stub = build_stub(headers: { 'Authorization' => 'Bearer asd' })
          subject.write('{}')
          subject.flush
          expect(stub).to have_been_requested
        end
      end

      context 'max request time' do
        let(:config) { Config.new(api_request_time: '100ms') }

        it 'closes requests when reached' do
          stub = build_stub

          subject.write('{}')

          sleep 0.5

          expect(subject.http.closed?).to be true

          expect(stub).to have_been_requested
        end

        it "doesn't make a scene if already closed" do
          build_stub

          subject.write('{}')
          subject.flush

          expect(subject.http.closed?).to be true

          sleep 0.2
          expect(subject.http.closed?).to be true
        end
      end

      context 'max request size' do
        let(:config) { Config.new(api_request_size: '5b') }

        it 'closes requests when reached' do
          stub = build_stub do |req|
            metadata, payload = gunzip(req.body).split("\n")

            expect(metadata).to match('{"metadata":')
            expect(payload).to eq('{}')

            req
          end

          subject.write('{}')
          sleep 0.2

          expect(subject.http.closed?).to be true

          expect(stub).to have_been_requested
        end

        it "doesn't make a scene if already closed" do
          build_stub

          subject.write('{}')
          subject.flush

          expect(subject.http.closed?).to be true

          sleep 0.2
          expect(subject.http.closed?).to be true
        end

        context 'and gzip off' do
          let(:config) { Config.new(http_compression: false) }

          before do
            config.api_request_size = metadata.to_json.bytesize + 1
          end

          it 'closes requests when reached' do
            stub = build_stub

            subject.write('{}')

            sleep 0.2
            expect(subject.http.closed?).to be true
            expect(stub).to have_been_requested
          end
        end
      end

      context 'http compression' do
        let(:config) { Config.new }

        it 'compresses the payload' do
          stub = build_stub(
            headers: { 'Content-Encoding' => 'gzip' }
          ) do |req|
            metadata, payload = gunzip(req.body).split("\n")

            expect(metadata).to match('{"metadata":')
            expect(payload).to eq('{}')

            req
          end

          subject.write('{}')
          subject.flush

          expect(stub).to have_been_requested
        end
      end

      describe 'verify_server_cert' do
        let(:config) do
          Config.new(server_url: 'https://self-signed.badssl.com')
        end

        it 'is enabled by default' do
          expect(config.logger)
            .to receive(:error)
            .with(/OpenSSL::SSL::SSLError/)

          WebMock.disable!
          subject.write('')
          subject.flush
          WebMock.enable!
        end

        context 'when disabled' do
          let(:config) do
            Config.new(
              server_url: 'https://self-signed.badssl.com',
              verify_server_cert: false
            )
          end

          it "doesn't complain" do
            expect(config.logger)
              .to_not receive(:error)
              .with(/OpenSSL::SSL::SSLError/)

            WebMock.disable!
            subject.write('')
            subject.flush
            WebMock.enable!
          end
        end
      end

      # rubocop:disable Metrics/MethodLength
      def build_stub(body: nil, headers: {}, to_return: {}, status: 202, &block)
        opts = {
          headers: {
            'Transfer-Encoding' => 'chunked',
            'Content-Type' => 'application/x-ndjson'
          }.merge(headers)
        }

        opts[:body] = body if body

        WebMock
          .stub_request(:post, 'http://localhost:8200/intake/v2/events')
          .with(**opts, &block)
          .to_return(to_return.merge(status: status) { |_, old, _| old })
      end
      # rubocop:enable Metrics/MethodLength

      def gunzip(string)
        sio = StringIO.new(string)
        gz = Zlib::GzipReader.new(sio, encoding: Encoding::ASCII_8BIT)
        gz.read
      ensure
        gz&.close
      end
    end
  end
end
