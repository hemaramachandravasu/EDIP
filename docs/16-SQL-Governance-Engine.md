# SQL Data Governance, Classification & Access Policy Engine

## Purpose
SQL Server governance layer for dataset classification, lifecycle/certification, access requests, policy evaluation, and dashboard reporting. Complements existing `ingest.Dataset`, `analytics.Workspace`, quality, and lineage modules.

## Note on Users / RBAC
The platform previously had **no** application user tables. This module introduces a minimal `gov.AppUser` / `gov.Role` / `gov.WorkspaceMember` foundation used only for governance and access policy. It does not replace API-key authentication.

## Schema (`gov`)

| Object | Role |
|--------|------|
| `Classification` | Public / Internal / Confidential / Restricted |
| `GovernanceStatus` | Draft / UnderReview / Certified / Expired / Archived |
| `CertificationStatus` | NotCertified / Certified / Expired / Revoked |
| `AccessLevel` | Read / Write / Admin |
| `AppUser`, `Role`, `UserRole` | Platform users & roles |
| `WorkspaceMember` | User ↔ workspace membership |
| `DatasetGovernance` | 1:1 governance attributes on `ingest.Dataset` |
| `CertificationHistory` | Append-only certification/review history |
| `AccessRequest` | Access request lifecycle |
| `DatasetAccessGrant` | Materialized approved grants |
| `GovernanceAuditEvent` | Classification/ownership/access audit |

## Access policy (`usp_EvaluateDatasetAccess`)
Allow when any of:
1. Platform admin
2. Dataset owner or steward
3. Active grant at required level (or higher)
4. Workspace membership for Public/Internal (role-dependent)

Restricted datasets require ownership/stewardship/platform admin **or** an explicit Admin grant.

Cross-workspace access requests from non-members are rejected at submit time.

## Key procedures
| Proc | Purpose |
|------|---------|
| `usp_UpsertDatasetGovernance` | Classification / ownership / status |
| `usp_SubmitForReview` / `usp_CertifyDataset` | Lifecycle + history |
| `usp_SubmitAccessRequest` / Approve / Reject / Revoke | Access workflow |
| `usp_EvaluateDatasetAccess` | Policy decision |
| `usp_ExpireDatasetCertifications` | Scheduled expiry |
| `rpt.usp_GovernanceSummary` (+ related) | Dashboard feeds |

## ADO.NET / API
Route: `/api/governance/*`  
Repository: `GovernanceRepository` — parameterized procs, async, `CommandTimeout = 120`, `await using` disposal.

Status codes from access procs: `Created`, `Approved`, `Rejected`, `Revoked`, `InvalidDataset`, `InvalidUser`, `CrossWorkspaceDenied`, `DuplicatePending`, `AlreadyGranted`, `InvalidTransition`, `Unauthorized`, `NotFound`.

## Deploy
Scripts `41`–`44` in `00_DeployAll.sql` / `Deploy-Edip.ps1`. Optional Agent: `45_SqlAgentJobs_Governance.sql`. Tests: `46_Tests_Governance.sql`.

## Indexing
- Pending request unique filtered index `(DatasetId, RequestingUserId, AccessLevelCode)`
- Active grant unique filtered index
- Composite workspace + classification / status / expiry indexes on `DatasetGovernance`
- Access request status + requested date covering indexes

## Known limitations
- Users are governance-scoped seed identities, not SSO/IdP accounts.
- API still authenticates via shared `X-Api-Key`; pass `UserName` explicitly for policy/actions.
- Column-level classification is out of scope (dataset-level only).
