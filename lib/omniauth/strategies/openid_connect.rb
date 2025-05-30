# frozen_string_literal: true

require 'base64'
require 'timeout'
require 'net/http'
require 'open-uri'
require 'omniauth'
require 'openid_connect'
require 'forwardable'

module OmniAuth
  module Strategies
    class OpenIDConnect # rubocop:disable Metrics/ClassLength
      include OmniAuth::Strategy
      extend Forwardable

      RESPONSE_TYPE_EXCEPTIONS = {
        'id_token' => { exception_class: OmniAuth::OpenIDConnect::MissingIdTokenError, key: :missing_id_token }.freeze,
        'code' => { exception_class: OmniAuth::OpenIDConnect::MissingCodeError, key: :missing_code }.freeze,
      }.freeze

      def_delegator :request, :params

      option :name, 'openid_connect'
      option(:client_options, identifier: nil,
                              secret: nil,
                              redirect_uri: nil,
                              scheme: 'https',
                              host: nil,
                              port: 443,
                              audience: nil,
                              authorization_endpoint: '/authorize',
                              token_endpoint: '/token',
                              userinfo_endpoint: '/userinfo',
                              jwks_uri: '/jwk',
                              end_session_endpoint: nil)

      option :issuer
      option :discovery, false
      option :client_signing_alg
      option :jwt_secret_base64
      option :client_jwk_signing_key
      option :client_x509_signing_key
      option :scope, [:openid]
      option :response_type, 'code' # ['code', 'id_token']
      option :send_state, true
      option :require_state, true
      option :state
      option :response_mode # [:query, :fragment, :form_post, :web_message]
      option :display, nil # [:page, :popup, :touch, :wap]
      option :prompt, nil # [:none, :login, :consent, :select_account]
      option :hd, nil
      option :max_age
      option :ui_locales
      option :id_token_hint
      option :acr_values
      option :send_nonce, true
      option :send_scope_to_token_endpoint, true
      option :client_auth_method
      option :post_logout_redirect_uri
      option :extra_authorize_params, {}
      option :allow_authorize_params, []
      option :uid_field, 'sub'
      option :pkce, false
      option :pkce_verifier, nil
      option :pkce_options, {
        code_challenge: proc { |verifier|
          Base64.urlsafe_encode64(Digest::SHA2.digest(verifier), padding: false)
        },
        code_challenge_method: 'S256',
      }

      option :logout_path, '/logout'

      def uid
        user_info.raw_attributes[options.uid_field.to_sym] || user_info.sub
      end

      info do
        {
          name: user_info.name,
          email: user_info.email,
          email_verified: user_info.email_verified,
          nickname: user_info.preferred_username,
          first_name: user_info.given_name,
          last_name: user_info.family_name,
          gender: user_info.gender,
          image: user_info.picture,
          phone: user_info.phone_number,
          urls: { website: user_info.website },
        }
      end

      extra do
        { raw_info: user_info.raw_attributes }
      end

      credentials do
        {
          id_token: access_token.id_token,
          token: access_token.access_token,
          refresh_token: access_token.refresh_token,
          expires_in: access_token.expires_in,
          scope: access_token.scope,
        }
      end

      def client
        @client ||= ::OpenIDConnect::Client.new(client_options)
      end

      def config
        @config ||= ::OpenIDConnect::Discovery::Provider::Config.discover!(options.issuer)
      end

      def request_phase
        options.issuer = issuer if options.issuer.to_s.empty?
        discover!
        redirect authorize_uri
      end

      def callback_phase
        error = params['error_reason'] || params['error']
        error_description = params['error_description'] || params['error_reason']
        invalid_state =
          if options.send_state
            (options.require_state && params['state'].to_s.empty?) || params['state'] != stored_state
          else
            false
          end

        raise CallbackError, error: params['error'], reason: error_description, uri: params['error_uri'] if error
        raise CallbackError, error: :csrf_detected, reason: "Invalid 'state' parameter" if invalid_state

        return unless valid_response_type?

        options.issuer = issuer if options.issuer.nil? || options.issuer.empty?

        verify_id_token!(params['id_token']) if configured_response_type == 'id_token'
        discover!
        client.redirect_uri = redirect_uri

        return id_token_callback_phase if configured_response_type == 'id_token'

        client.authorization_code = authorization_code
        access_token
        super
      rescue CallbackError => e
        fail!(e.error, e)
      rescue ::Rack::OAuth2::Client::Error => e
        fail!(e.response[:error], e)
      rescue ::Timeout::Error, ::Errno::ETIMEDOUT => e
        fail!(:timeout, e)
      rescue ::SocketError => e
        fail!(:failed_to_connect, e)
      end

      def other_phase
        if logout_path_pattern.match?(current_path)
          options.issuer = issuer if options.issuer.to_s.empty?
          discover!
          return redirect(end_session_uri) if end_session_uri
        end
        call_app!
      end

      def authorization_code
        params['code']
      end

      def end_session_uri
        return unless end_session_endpoint_is_valid?

        end_session_uri = URI(client_options.end_session_endpoint)
        end_session_uri.query = encoded_post_logout_redirect_uri
        end_session_uri.to_s
      end

      def authorize_uri # rubocop:disable Metrics/AbcSize
        client.redirect_uri = redirect_uri
        opts = {
          response_type: options.response_type,
          response_mode: options.response_mode,
          scope: options.scope,
          login_hint: params['login_hint'],
          ui_locales: params['ui_locales'],
          claims_locales: params['claims_locales'],
          prompt: options.prompt,
          nonce: (new_nonce if options.send_nonce),
          hd: options.hd,
          acr_values: options.acr_values,
        }

        opts[:state] = new_state if options.send_state
        opts.merge!(options.extra_authorize_params) unless options.extra_authorize_params.empty?

        options.allow_authorize_params.each do |key|
          opts[key] = request.params[key.to_s] unless opts.key?(key)
        end

        if options.pkce
          verifier = options.pkce_verifier ? options.pkce_verifier.call : SecureRandom.hex(64)

          opts.merge!(pkce_authorize_params(verifier))
          session['omniauth.pkce.verifier'] = verifier
        end

        client.authorization_uri(opts.reject { |_k, v| v.nil? })
      end

      def public_key
        @public_key ||= if options.discovery
                          config.jwks
                        elsif configured_public_key
                          configured_public_key
                        elsif client_options.jwks_uri
                          fetch_key
                        end
      end

      # Some OpenID providers use the OAuth2 client secret as the shared secret, but
      # Keycloak uses a separate key that's stored inside the database.
      def secret
        base64_decoded_jwt_secret || client_options.secret
      end

      def pkce_authorize_params(verifier)
        # NOTE: see https://tools.ietf.org/html/rfc7636#appendix-A
        {
          code_challenge: options.pkce_options[:code_challenge].call(verifier),
          code_challenge_method: options.pkce_options[:code_challenge_method],
        }
      end

      private

      def fetch_key
        @fetch_key ||= parse_jwk_key(::OpenIDConnect.http_client.get(client_options.jwks_uri).body)
      end

      def base64_decoded_jwt_secret
        return unless options.jwt_secret_base64

        Base64.decode64(options.jwt_secret_base64)
      end

      def issuer
        resource = "#{ client_options.scheme }://#{ client_options.host }"
        resource = "#{ resource }:#{ client_options.port }" if client_options.port
        ::OpenIDConnect::Discovery::Provider.discover!(resource).issuer
      end

      def discover!
        return unless options.discovery

        client_options.authorization_endpoint = config.authorization_endpoint
        client_options.token_endpoint = config.token_endpoint
        client_options.userinfo_endpoint = config.userinfo_endpoint
        client_options.jwks_uri = config.jwks_uri
        client_options.end_session_endpoint = config.end_session_endpoint if config.respond_to?(:end_session_endpoint)
      end

      def user_info
        return @user_info if @user_info

        if access_token.id_token
          decoded = decode_id_token(access_token.id_token).raw_attributes

          @user_info = ::OpenIDConnect::ResponseObject::UserInfo.new access_token.userinfo!.raw_attributes.merge(decoded)
        else
          @user_info = access_token.userinfo!
        end
      end

      def access_token
        return @access_token if @access_token

        token_request_params = {
          scope: (options.scope if options.send_scope_to_token_endpoint),
          client_auth_method: options.client_auth_method,
        }

        token_request_params[:code_verifier] = params['code_verifier'] || session.delete('omniauth.pkce.verifier') if options.pkce

        @access_token = client.access_token!(token_request_params)
        verify_id_token!(@access_token.id_token) if configured_response_type == 'code'

        @access_token
      end

      # Unlike ::OpenIDConnect::ResponseObject::IdToken.decode, this
      # method splits the decoding and verification of JWT into two
      # steps. First, we decode the JWT without verifying it to
      # determine the algorithm used to sign. Then, we verify it using
      # the appropriate public key (e.g. if algorithm is RS256) or
      # shared secret (e.g. if algorithm is HS256).  This works around a
      # limitation in the openid_connect gem:
      # https://github.com/nov/openid_connect/issues/61
      def decode_id_token(id_token)
        decoded = JSON::JWT.decode(id_token, :skip_verification)
        algorithm = decoded.algorithm.to_sym

        validate_client_algorithm!(algorithm)

        keyset =
          case algorithm
          when :HS256, :HS384, :HS512
            secret
          else
            public_key
          end

        decoded.verify!(keyset)
        ::OpenIDConnect::ResponseObject::IdToken.new(decoded)
      rescue JSON::JWK::Set::KidNotFound
        # If the JWT has a key ID (kid), then we know that the set of
        # keys supplied doesn't contain the one we want, and we're
        # done. However, if there is no kid, then we try each key
        # individually to see if one works:
        # https://github.com/nov/json-jwt/pull/92#issuecomment-824654949
        raise if decoded&.header&.key?('kid')

        decoded = decode_with_each_key!(id_token, keyset)

        raise unless decoded

        decoded
      end

      # If client_signing_alg is specified, we check that the returned JWT
      # matches the expected algorithm. If not, we reject it.
      def validate_client_algorithm!(algorithm)
        client_signing_alg = options.client_signing_alg&.to_sym

        return unless client_signing_alg
        return if algorithm == client_signing_alg

        reason = "Received JWT is signed with #{algorithm}, but client_singing_alg is configured for #{client_signing_alg}"
        raise CallbackError, error: :invalid_jwt_algorithm, reason: reason, uri: params['error_uri']
      end

      def decode!(id_token, key)
        ::OpenIDConnect::ResponseObject::IdToken.decode(id_token, key)
      end

      def decode_with_each_key!(id_token, keyset)
        return unless keyset.is_a?(JSON::JWK::Set)

        keyset.each do |key|
          begin
            decoded = decode!(id_token, key)
          rescue JSON::JWS::VerificationFailed, JSON::JWS::UnexpectedAlgorithm, JSON::JWK::UnknownAlgorithm
            next
          end

          return decoded if decoded
        end

        nil
      end

      def client_options
        options.client_options
      end

      def new_state
        state = if options.state.respond_to?(:call)
                  if options.state.arity == 1
                    options.state.call(env)
                  else
                    options.state.call
                  end
                end
        session['omniauth.state'] = state || SecureRandom.hex(16)
      end

      def stored_state
        session.delete('omniauth.state')
      end

      def new_nonce
        session['omniauth.nonce'] = SecureRandom.hex(16)
      end

      def stored_nonce
        session.delete('omniauth.nonce')
      end

      def script_name
        return '' if @env.nil?

        super
      end

      def session
        return {} if @env.nil?

        super
      end

      def configured_public_key
        @configured_public_key ||= if options.client_jwk_signing_key
                                     parse_jwk_key(options.client_jwk_signing_key)
                                   elsif options.client_x509_signing_key
                                     parse_x509_key(options.client_x509_signing_key)
                                   end
      end

      def parse_x509_key(key)
        OpenSSL::X509::Certificate.new(key).public_key
      end

      def parse_jwk_key(key)
        json = key.is_a?(String) ? JSON.parse(key) : key
        return JSON::JWK::Set.new(json['keys']) if json.key?('keys')

        JSON::JWK.new(json)
      end

      def decode(str)
        UrlSafeBase64.decode64(str).unpack1('B*').to_i(2).to_s
      end

      def redirect_uri
        return client_options.redirect_uri unless params['redirect_uri']

        "#{ client_options.redirect_uri }?redirect_uri=#{ CGI.escape(params['redirect_uri']) }"
      end

      def encoded_post_logout_redirect_uri
        return unless options.post_logout_redirect_uri

        URI.encode_www_form(
          post_logout_redirect_uri: options.post_logout_redirect_uri
        )
      end

      def end_session_endpoint_is_valid?
        client_options.end_session_endpoint &&
          client_options.end_session_endpoint =~ URI::DEFAULT_PARSER.make_regexp
      end

      def logout_path_pattern
        @logout_path_pattern ||= /\A#{Regexp.quote(request_path)}#{options.logout_path}/
      end

      def id_token_callback_phase
        user_data = decode_id_token(params['id_token']).raw_attributes
        env['omniauth.auth'] = AuthHash.new(
          provider: name,
          uid: user_data['sub'],
          info: { name: user_data['name'], email: user_data['email'] },
          extra: { raw_info: user_data }
        )
        call_app!
      end

      def valid_response_type?
        # If response_type is an array, check if ANY of the types are in params
        if configured_response_type.is_a?(Array)
          return true if configured_response_type.any? { |type| params.key?(type.to_s) }
          
          # If no match found, use the first one for the error message
          error_type = configured_response_type.first.to_s
          error_attrs = RESPONSE_TYPE_EXCEPTIONS[error_type]
        else
          # Original single type flow
          return true if params.key?(configured_response_type)
          
          error_attrs = RESPONSE_TYPE_EXCEPTIONS[configured_response_type]
        end
        
        # Handle error case - make sure error_attrs isn't nil
        if error_attrs
          fail!(error_attrs[:key], error_attrs[:exception_class].new(params['error']))
        else
          # Default error if we don't have a specific error for this response type
          fail!(:invalid_response, StandardError.new("Invalid response_type: #{configured_response_type}"))
        end
      
        false
      end

      def configured_response_type
        @configured_response_type ||= begin
          response_type = options.response_type
          if response_type.is_a?(Array)
            # If array contains multiple response types, use them all
            response_type
          else
            # Otherwise, convert to string as before
            response_type.to_s
          end
        end
      end

      def verify_id_token!(id_token)
        return unless id_token

        verify_kwargs = {
          issuer: options.issuer,
          client_id: client_options.identifier,
          nonce: params['nonce'].presence || stored_nonce,
        }
        verify_kwargs.merge!(audience: client_options.audience) if client_options.audience

        decode_id_token(id_token).verify!(**verify_kwargs)
      end

      class CallbackError < StandardError
        attr_accessor :error, :error_reason, :error_uri

        def initialize(data)
          super
          self.error = data[:error]
          self.error_reason = data[:reason]
          self.error_uri = data[:uri]
        end

        def message
          [error, error_reason, error_uri].compact.join(' | ')
        end
      end
    end
  end
end

OmniAuth.config.add_camelization 'openid_connect', 'OpenIDConnect'
