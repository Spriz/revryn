require "net/http"
require "json"
require "securerandom"

# Minimal Billing Core GraphQL client (public contract only, INV-030).
# Standard-library HTTP; failures are classified so operators can
# distinguish showcase defects, GraphQL incompatibility, authentication
# failures, and billing-domain rejections (BC-US-153).
module BillingCore
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class AuthenticationError < Error; end
  class ContractError < Error; end

  class DomainRejection < Error
    attr_reader :code

    def initialize(code, message)
      @code = code
      super("#{code}: #{message}")
    end
  end

  class Client
    attr_reader :team_id

    def initialize(url: nil, token: nil, team_id: nil)
      config = Integration.config
      @uri = URI.parse("#{(url || config[:url]).chomp("/")}/graphql")
      @token = token || config[:token]
      @team_id = team_id || config[:team_id]
      if @token.empty? || @team_id.empty?
        raise ConfigurationError, "BILLING_CORE_TOKEN and BILLING_CORE_TEAM_ID are required"
      end
    end

    def execute(document, variables = {})
      request = Net::HTTP::Post.new(@uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer #{@token}"
      request["X-Correlation-Id"] = SecureRandom.uuid
      request.body = JSON.generate(query: document, variables: variables)

      response =
        begin
          Net::HTTP.start(@uri.host, @uri.port, read_timeout: 15) { |http| http.request(request) }
        rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout => error
          raise ContractError, "Billing Core unreachable: #{error.message}"
        end

      raise AuthenticationError, "HTTP #{response.code}" if %w[401 403].include?(response.code)
      raise ContractError, "HTTP #{response.code}" unless response.code == "200"

      body = JSON.parse(response.body)
      if (errors = body["errors"]) && !errors.empty?
        first = errors.first
        code = first.dig("extensions", "code") || first["code"]
        raise AuthenticationError, first["message"].to_s if %w[UNAUTHENTICATED UNAUTHORIZED].include?(code)
        raise ContractError, first["message"].to_s
      end
      body.fetch("data")
    end

    # Typed-union mutation: problem members raise DomainRejection.
    def mutate(field, document, variables)
      payload = execute(document, variables).fetch(field)
      typename = payload["__typename"].to_s
      if typename.end_with?("Problem") ||
         %w[VersionConflict IdempotencyConflict UsageEventConflict].include?(typename)
        raise DomainRejection.new(payload["code"] || typename, payload["message"].to_s)
      end
      payload
    end
  end
end
