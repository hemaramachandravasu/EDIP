# Data Sharing & Export Test Scenarios

Assumes `44_Seed_Governance.sql` and `50_Seed_Sharing.sql` have run and the
API is running (`dotnet run --project src/Edip.Api` → http://localhost:5015).

Seed users: `gov.admin`, `gov.owner`, `gov.steward`, `gov.analyst`,
`gov.viewer` (all WS-SALES) and `gov.outsider` (WS-FINANCE only).
`CUSTOMER` is Confidential + Certified (min level Write); `gov.analyst` holds
an approved Write grant; `gov.viewer` holds an active Read share.

SQL harness (53 assertions): `sqlcmd -S localhost -E -C -I -b -d EDIP -i database/52_Tests_Sharing.sql`

## PowerShell setup

```powershell
$base = "http://localhost:5015/api/sharing"
$h    = @{ "X-Api-Key" = "edip-dev-api-key" }
function Post($url, $body) { Invoke-RestMethod -Method Post -Uri $url -Headers $h -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 6) }
function Put($url, $body)  { Invoke-RestMethod -Method Put  -Uri $url -Headers $h -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 6) }
function Get($url)         { Invoke-RestMethod -Uri $url -Headers $h }
```

Failures return `{ statusCode, error, id }` with HTTP 404 (NotFound),
403 (Unauthorized / AccessDenied / CrossWorkspaceDenied), 409
(DuplicateActive / DuplicateInFlight / ConcurrencyConflict) or 400 (all other
validation codes). Use `try { … } catch { $_.ErrorDetails.Message }` to see the body.

## 1. Export authorization

| # | Call | Expected |
|---|------|----------|
| 1.1 | `Get "$base/access/evaluate?datasetCode=CUSTOMER&userName=gov.admin"` | `isAllowed=true`, `accessSource=PlatformAdmin` |
| 1.2 | `…userName=gov.owner` | Allowed, `DatasetOwner` |
| 1.3 | `…userName=gov.analyst` | Allowed, `AccessGrant`, effective level Write |
| 1.4 | `…userName=gov.viewer` | Denied, `InsufficientAccess` (Read share < Write required), `shareStatus=Active` |
| 1.5 | `…userName=gov.outsider` | Denied, `CrossWorkspaceDenied` |
| 1.6 | `Get "$base/datasets/CUSTOMER/columns"` | Exportable columns, `CustomerId` has `isKey=true` |

## 2. Share lifecycle

```powershell
# create (ORDER is Internal; owner shares with analyst for 7 days)
$s = Post "$base/shares" @{ datasetCode="ORDER"; recipientUserName="gov.analyst"; accessLevelCode="Read";
                            sharedByUserName="gov.owner"; expiresUtc=(Get-Date).ToUniversalTime().AddDays(7) }
$id = $s.shareId
Put  "$base/shares/$id" @{ actorUserName="gov.owner"; accessLevelCode="Write"; comments="needs write" }
Get  "$base/shares/history?shareId=$id"
Post "$base/shares/$id/revoke" @{ actorUserName="gov.owner"; revokeReason="project ended" }
```

| # | Scenario | Expected |
|---|----------|----------|
| 2.1 | Create as above | 200, `statusCode=Created`, `share.effectiveStatus=Active` |
| 2.2 | Same create again while active | 409 `DuplicateActive`, `id` = existing ShareId |
| 2.3 | Update level to Write | 200 `Updated`; same values again → `NoChange` |
| 2.4 | Share history | `Created`, `Updated` rows (then `Revoked`) |
| 2.5 | Revoke | 200 `Revoked`; revoke again → 400 `AlreadyRevoked`; update → 400 `ShareRevoked` |
| 2.6 | Create with `sharedByUserName=gov.viewer` | 403 `Unauthorized` (viewer can't manage shares) |
| 2.7 | Recipient `gov.outsider` | 403 `CrossWorkspaceDenied` |
| 2.8 | Recipient = sharer | 400 `SelfShare` |
| 2.9 | `expiresUtc` in the past | 400 `InvalidExpiry` |
| 2.10 | `accessLevelCode="Owner"` | 400 `InvalidAccessLevel` |
| 2.11 | `Get "$base/shares/active?datasetCode=CUSTOMER"` | viewer's Read share |
| 2.12 | `Get "$base/shares/expired?onlyUnmarked=true"` | seeded ORDER → viewer share (`isMarked=false`) — empty if the expiry job already ran; drop `onlyUnmarked` to see it with `isMarked=true` |
| 2.13 | `Post "$base/maintenance/expire-shares" @{}` then 2.12 again | `expiredCount ≥ 1`, then empty; history shows `Expired` |
| 2.14 | `Get "$base/shares?status=Revoked&pageSize=10"` | paged list with `totalCount` |

## 3. Export request lifecycle

```powershell
$e = Post "$base/exports" @{
    datasetCode = "CUSTOMER"; userName = "gov.analyst"; formatCode = "Csv"
    selectedColumns = @("CustomerId","CustomerName","CountryCode")
    filters = @(@{ column="CountryCode"; op="in"; value=@("US","UK") })
}
$x = $e.exportRequestId
Post "$base/exports/$x/transition" @{ newStatus="Processing" }
Get  "$base/exports/$x/data?pageSize=4&includeTotalCount=true"
Get  "$base/exports/$x/data?pageSize=4&afterKey=4"
Post "$base/exports/$x/transition" @{ newStatus="Completed"; recordCount=11; fileSizeBytes=2048; fileReference="exports/$x.csv" }
Post "$base/exports/$x/download" @{ userName="gov.analyst"; clientInfo="PowerShell" }
Get  "$base/exports/$x"
```

| # | Scenario | Expected |
|---|----------|----------|
| 3.1 | Submit as above | 200 `Created`, status `Pending`, `accessSource=AccessGrant` |
| 3.2 | Submit identical spec again | 409 `DuplicateInFlight` |
| 3.3 | Submit as `gov.viewer` | 403 `AccessDenied` (audited as `ExportDenied`) |
| 3.4 | Column `"Password"` / `"CustomerId; DROP TABLE x"` | 400 `InvalidColumn` |
| 3.5 | Filter `op="contains"` | 400 `InvalidOperator` |
| 3.6 | Filter `{column="CustomerId"; op="eq"; value="abc"}` | 400 `InvalidFilterValue` |
| 3.7 | `formatCode="Pdf"` | 400 `InvalidFormat` |
| 3.8 | Pending → Completed directly | 400 `InvalidTransition` |
| 3.9 | Pending → Processing | 200, `startedUtc` set |
| 3.10 | Data page 1 | `pagingMode=Keyset`, `keyColumn=CustomerId`, 4 rows, `hasMore=true`, `nextAfterKey=4`, `totalCount=11` |
| 3.11 | Data with `afterKey=4` | next 4 rows, keys > 4 |
| 3.12 | Completed without `recordCount` | 400 `RecordCountRequired` |
| 3.13 | Completed with record count | 200, `completedUtc` set |
| 3.14 | Download as analyst | 200 `Downloaded`, `mimeType=text/csv`, `fileReference` |
| 3.15 | Download as `gov.outsider` | 403 |
| 3.16 | Detail | spec JSON, 3 status history rows (Pending, Processing, Completed), 1 download |
| 3.17 | Completed → Cancelled | 400 `InvalidTransition` (terminal) |

Failure / retry path: submit → Processing → `@{ newStatus="Failed" }` (400
`FailureReasonRequired`) → `@{ newStatus="Failed"; failureReason="disk full" }`
→ `@{ newStatus="Pending" }` (retry, `attemptCount` increments; after 3
attempts → `RetryLimitReached`).

Custom sort switches to offset paging:
`sort = @(@{ column="CustomerName"; dir="desc" })` → `pagingMode=Offset`, use `pageNumber`.

Worker queue: `Post "$base/exports/claim" @{}` → oldest Pending request moved
to Processing, or `statusCode=QueueEmpty`.

## 4. History, reports & maintenance

| # | Call | Expected |
|---|------|----------|
| 4.1 | `Get "$base/exports?userName=gov.analyst&pageSize=10"` | analyst's exports, newest first, `totalCount` |
| 4.2 | `Get "$base/exports?status=Failed"` | seeded owner Json export with `failureReason` |
| 4.3 | `Get "$base/reports/summary"` | totals by status, records exported, downloads, active/expired/revoked shares |
| 4.4 | `Get "$base/reports/by-format"` / `by-dataset` / `by-user` | per-key counts (Csv, Json, Parquet, Xlsx …) |
| 4.5 | `Get "$base/reports/activity?days=7"` | 7 rows (gap-filled per day) |
| 4.6 | `Get "$base/reports/share-status"` | per-dataset active / expired / revoked / expiring-soon counts |
| 4.7 | `Post "$base/maintenance/cleanup-exports?processingTimeoutMinutes=1&pendingTimeoutHours=1" @{}` | `timedOutCount`, `abandonedCount` |
| 4.8 | `Get "http://localhost:5015/api/governance/audit?eventType=ExportCompleted"` | audit events with `ExportRequestId` in details |

## 5. SQL spot checks

```sql
SELECT * FROM share.vw_DatasetShareDetail ORDER BY SharedUtc DESC;
SELECT * FROM rpt.vw_UserDatasetExportAccess WHERE DatasetCode = N'CUSTOMER';
SELECT * FROM rpt.vw_PendingExportQueue;
SELECT * FROM rpt.vw_FailedExports;
SELECT EventType, COUNT(*) FROM gov.GovernanceAuditEvent
WHERE EventType LIKE N'Share%' OR EventType LIKE N'Export%' GROUP BY EventType;
```
