---
id: organizations-and-teams
title: Organizations and teams
status: supported
public: true
owners: [billing-domain]
graphql:
  - Viewer
  - Organization
  - Team
  - viewer
  - organizations
  - organization
  - team
  - teams
  - createOrganization
  - createTeam
tests:
  integration:
    - test/workflows/organization_lifecycle_test.exs
    - test/workflows/scope_resolution_test.exs
adrs:
  - SPEC.md §6.3, §9.1.1, §13.3, §13.4, Epic J
---

# Organizations and teams

## Purpose

Provide the tenancy model: global users hold explicit memberships in
organizations and teams. The team is the tenancy boundary for all business
data (INV-034); authorization always resolves an explicit scope before any
grant is evaluated (INV-024/025).

## User outcomes

- A founder creates an organization and immediately has a working team with
  owner and admin grants — atomically, never a partial organization
  (BC-US-140, INV-033).
- Admins add teams, staff them, rename them (stable UUID/slug identity),
  and archive teams that are no longer used.
- Organization-level commercial accounts project onto team-local billing
  customers without ever granting cross-team access (BC-US-142).

## Actors and permissions

- Organization roles: `organization_owner`, `organization_admin`,
  `organization_member`.
- Team roles: `team_admin`, `billing_admin`, `finance_operator`, `auditor`,
  `integration_client`.
- Team roles never derive from organization roles; `platform_admin` never
  bypasses membership checks.

## Domain terminology

- **Scope** (`BillingCore.Scope`) — the resolved authorization context
  (principal + organization + team + role grants) threaded through every
  context call. Built only by the auth pipeline, never from request params.
- **Account** — organization-scoped commercial identity, projected to
  team-local customers via `account_team_customers`.
- **Team settings version** — immutable settings snapshot with canonical
  SHA-256 hash; `teams.settings_version` points at the latest.

## Workflows

1. `Orgs.create_organization/2` — one transaction inserts the organization,
   its first team (default name "Default", a bootstrap convenience, never a
   semantic marker), settings version 1, and the creator's
   `organization_owner` + `team_admin` memberships, with audit entries.
2. Membership management — `add_organization_member`, `change_organization_roles`,
   `remove_organization_member`, `add_team_member`, `change_team_roles`,
   `remove_team_member`. Removed memberships keep their row (status `removed`).
3. Team lifecycle — `create_team` (active organizations only), `rename_team`,
   `archive_team`, `update_team_settings` (locked, version-bumping snapshot).
4. Accounts — `create_account` (external_id unique per organization),
   `update_account`, `archive_account` (idempotent),
   `project_account_to_team` (upsert on `(account_id, team_id)`; refuses
   cross-organization teams).
5. Scope resolution — `resolve_scope(user, organization_id, team_id \\ nil)`.

## State transitions

No formal state machine. Statuses: organizations/teams `active`/`disabled`
(`disabled` is called "archived" for teams), memberships `active`/`removed`,
accounts `active`/`archived`.

## Business rules / invariants

- INV-033: organization creation atomically creates the first team; the
  final active team of an active organization cannot be archived
  (`{:error, :last_active_team}`, race-safe via an organization row lock).
- The last active `organization_owner` can be neither removed nor demoted
  (`{:error, :last_owner}`).
- An organization membership cannot be removed while the user holds active
  team memberships in that organization (`{:error, :active_team_memberships}`).
- Team membership requires an active organization membership
  (`{:error, :not_organization_member}`) — INV-035.
- `resolve_scope/3` requires: active user, existing active organization,
  ACTIVE organization membership, and (when a team is requested) a team that
  belongs to that organization, is active, and holds an ACTIVE team
  membership. Any failure is a uniform `{:error, :unauthorized}` — no detail
  leak (INV-024/025).
- Possession of an ID never grants access; queries are constrained by
  `scope.team.id` / `scope.organization.id` (SPEC §13.4).

## GraphQL contract

Queries: `viewer` (own memberships and roles), `organizations`,
`organization`, `team`, `teams`, `organizationMemberships` /
`teamMemberships` (admin directories with member emails), and
`organizationInvitations` (BC-US-144). Mutations: `createOrganization`
(returns organization + first team), `createTeam`, `renameTeam`,
`archiveTeam` (organization scope — the owner need not be a member of the
archived team), `inviteOrganizationMember` / `revokeOrganizationInvitation`,
`addTeamMember` (requires an existing organization membership, INV-024),
`changeTeamRoles`, `removeTeamMember`, and `changeOrganizationRoles`
(last-owner protected). This is the full SPEC §14.5
organizations-and-membership row. See `schema/billing_core.graphql`.

## CLI surface

Not yet implemented. `revryn` (BC-US-157) is planned; domain commands
are reachable via GraphQL.

## MCP surface

Not yet implemented (BC-US-158 planned).

## UI behavior

First-run and dashboard workspace creation (`#create-workspace-form`,
per-organization `#new-team-form-…`), the team members page
(`/teams/:team_id/members`: role changes, removal, invitations with the
one-time accept link), and the browser accept flow (`/invitations/:token`).

## Accounting / ERP effects

None directly. Teams carry the invoicing legal identity (`legal_name`,
`base_currency`, `time_zone`, `locale`) used downstream by billing and ERP.

## Async / failure / recovery behavior

All mutations are single transactions; a failing step rolls back the whole
command (verified for organization creation). No durable operations.

## Observability

Audit events (`orgs.organization.created`, `orgs.team.*`,
`orgs.organization_membership.*`, `orgs.team_membership.*`,
`orgs.account.*`) are recorded in the same transaction as each change.

## Tests

- `test/workflows/organization_lifecycle_test.exs` — creation atomicity,
  last-team/last-owner protection, membership ordering, team lifecycle.
- `test/workflows/scope_resolution_test.exs` — INV-024/025 matrix: role
  locality, cross-organization substitution, platform_admin non-bypass,
  disabled/suspended targets.
- `test/graphql/memberships_test.exs` — SPEC §14.5 contract breadth:
  directories, role changes, INV-024 team grants, last-owner and
  last-team protections, typed authorization problems.
- `test/graphql/invitations_test.exs`, `test/workflows/invitation_test.exs`,
  `test/billing_core_web/live/members_live_test.exs` — BC-US-144 invitation
  lifecycle across API, mail, and browser.
- `e2e/features/multi_membership.spec.ts` — INV-032: one identity with
  conflicting roles across three teams in two organizations.

## Security / privacy

Scope resolution fails closed and uniformly (`:unauthorized`). Membership
history is retained (status `removed`), not deleted. Audit entries carry the
acting principal.

## Limitations

- Team settings and account administration remain context functions
  without GraphQL mutations (accounts surface via the projection flow).
- Organization suspension/closure workflows beyond the `status` field are
  not implemented; `removeOrganizationMember` is intentionally absent from
  the public contract (SPEC §14.5 table) and remains a context command.
