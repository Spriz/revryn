# revryn

This directory is the isolated Go companion module for Revryn. It contains the
cross-platform `revryn` CLI and its semantic MCP server; both are clients of
the public GraphQL API and never link to Phoenix internals or access PostgreSQL.

```sh
go vet ./...
go build ./...
go test ./...
make build        # writes bin/revryn
```

- `cmd/revryn/` — binary entry point
- `internal/client/` — authenticated GraphQL client and retry semantics
- `internal/commands/` — Cobra command tree and stable output DTOs
- `internal/mcp/` — semantic MCP tools and transports
- `contracts/cli/` — CLI schemas, golden output, and exit-code registry
- `contracts/mcp/` — reviewed MCP tool metadata

See the repository-level `AGENTS.md`, `TODO.md`, and SPEC §12.2.3 before
changing cross-interface behavior.
