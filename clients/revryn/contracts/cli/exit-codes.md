# revryn exit-code registry

Exit codes are a stable compatibility surface (SPEC §14.14, INV-043). They are
registered centrally here, mirrored by the constants in
`internal/commands/exit.go`, and **never reused or renumbered**. Retiring a
code retires its number forever; new failure classes get new numbers.

| Code | Name | Meaning |
|------|------|---------|
| 0 | `ok` | Command succeeded. |
| 1 | `generic` | Unclassified failure, including top-level GraphQL errors that are not authentication-related and unexpected client-side faults. |
| 2 | `usage` | Command-line usage error: unknown command/flag, missing required flag or argument, malformed flag value (e.g. a non-ISO date), or missing team scope (`--team`/`BILLING_TEAM`). No request reached the server. |
| 3 | `auth` | Authentication or explicit authorization failure: HTTP 401/403, an `unauthenticated`/`unauthorized` top-level GraphQL error, or a typed `AuthorizationProblem` result. |
| 4 | `not-found` | A nullable query lookup returned null. Billing Core deliberately does not distinguish "does not exist" from "not authorized to see it" for team-scoped reads, so neither does this exit code. |
| 5 | `validation` | Typed domain problem: `ValidationProblem` or `MappingProblem` (unmet ERP-mapping/preconditions). Field-level details are printed on stderr and included in the JSON error envelope. |
| 6 | `conflict` | Typed concurrency problem: `VersionConflict` (optimistic concurrency) or `IdempotencyConflict` (idempotency key reused with materially different input). |
| 7 | `transport` | Server/transport failure: network errors or 5xx responses that persisted after retries with exponential backoff and jitter. |

## Error output contract

Failures always print the correlation ID (SPEC §22.10):

- Human mode (stderr):

  ```
  revryn: error: <message>
    field <path>: <message> (<code>)      # for validation/mapping problems
  correlation-id: <uuid>
  ```

- `--json` mode (stderr), schema `revryn.v1`:

  ```json
  {
    "error": {
      "kind": "validation | mapping | auth | not_found | conflict-kind | transport | usage | graphql | generic",
      "code": "server-provided problem code, when present",
      "message": "human-readable message",
      "fields": [{"path": ["input", "quantity"], "code": "...", "message": "..."}],
      "exitCode": 5
    },
    "correlationId": "uuid",
    "schema": "revryn.v1"
  }
  ```

  For `VersionConflict`/`IdempotencyConflict` the `kind` is
  `version_conflict`/`idempotency_conflict` respectively.

Note: usage errors that occur before global flags are parsed (for example an
unknown flag) are reported in human form even under `--json`, because the
output mode itself was not yet resolved.
