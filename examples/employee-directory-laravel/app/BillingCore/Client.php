<?php

namespace App\BillingCore;

use Illuminate\Support\Str;

/**
 * Minimal Billing Core GraphQL client (public contract only, INV-030),
 * PHP streams — no added dependency.
 */
final class Client
{
    public readonly string $teamId;
    private readonly string $endpoint;
    private readonly string $token;

    public function __construct(?string $url = null, ?string $token = null, ?string $teamId = null)
    {
        $config = Integration::config();
        $this->endpoint = rtrim($url ?? $config['url'], '/').'/graphql';
        $this->token = $token ?? $config['token'];
        $this->teamId = $teamId ?? $config['team_id'];
        if ($this->token === '' || $this->teamId === '') {
            throw new ConfigurationError('BILLING_CORE_TOKEN and BILLING_CORE_TEAM_ID are required');
        }
    }

    public function execute(string $document, array $variables = []): array
    {
        $context = stream_context_create(['http' => [
            'method' => 'POST',
            'header' => implode("\r\n", [
                'Content-Type: application/json',
                "Authorization: Bearer {$this->token}",
                'X-Correlation-Id: '.Str::uuid(),
            ]),
            'content' => json_encode(['query' => $document, 'variables' => (object) $variables]),
            'timeout' => 15,
            'ignore_errors' => true,
        ]]);

        $raw = @file_get_contents($this->endpoint, false, $context);
        if ($raw === false) {
            throw new ContractError('Billing Core unreachable');
        }
        $status = 0;
        foreach ($http_response_header ?? [] as $header) {
            if (preg_match('#^HTTP/\S+\s+(\d+)#', $header, $match)) {
                $status = (int) $match[1];
            }
        }
        if (in_array($status, [401, 403], true)) {
            throw new AuthenticationError("HTTP {$status}");
        }
        if ($status !== 200) {
            throw new ContractError("HTTP {$status}");
        }

        $body = json_decode($raw, true);
        if (! empty($body['errors'])) {
            $first = $body['errors'][0];
            $code = $first['extensions']['code'] ?? $first['code'] ?? '';
            if (in_array($code, ['UNAUTHENTICATED', 'UNAUTHORIZED'], true)) {
                throw new AuthenticationError($first['message'] ?? $code);
            }
            throw new ContractError($first['message'] ?? 'GraphQL error');
        }

        return $body['data'];
    }

    /** Typed-union mutation: problem members raise DomainRejection. */
    public function mutate(string $field, string $document, array $variables): array
    {
        $payload = $this->execute($document, $variables)[$field];
        $typename = $payload['__typename'] ?? '';
        if (str_ends_with($typename, 'Problem')
            || in_array($typename, ['VersionConflict', 'IdempotencyConflict', 'UsageEventConflict'], true)) {
            throw new DomainRejection($payload['code'] ?? $typename, $payload['message'] ?? '');
        }

        return $payload;
    }
}
