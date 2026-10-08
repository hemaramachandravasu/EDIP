# Data Catalog & Discovery Test Scenarios

Assumes `44_Seed_Governance.sql`, `50_Seed_Sharing.sql` and `56_Seed_Catalog.sql`
have run and the API is running (`dotnet run --project src/Edip.Api` → http://localhost:5015).

Seed users:

| User | Access |
|------|--------|
| `gov.admin` | Platform admin |
| `gov.owner` | WS-SALES DataOwner, owner of CUSTOMER / ORDER / COUNTRY |
| `gov.steward` | WS-SALES DataSteward |
| `gov.analyst` | WS-SALES Analyst, Write grant on CUSTOMER |
| `gov.viewer` | WS-SALES Viewer, Read share on CUSTOMER |
| `gov.outsider` | WS-FINANCE Analyst only |

Demo datasets:

| Code | Workspace | Classification | Governance | Quality | Tags |
|------|-----------|----------------|------------|--------:|------|
| CUSTOMER | WS-SALES | Confidential | Certified | 88 | customer, pii, master-data, gold, sales |
| ORDER | WS-SALES | Internal | Draft | — | sales, orders, transactional, daily |
| COUNTRY | WS-SALES | Public | Certified | 96.5 | reference, master-data, gold, geography |
| LEGACY_LEADS | WS-SALES | Internal | Archived | 41 | marketing, legacy |
| INVOICE | WS-FINANCE | Internal | Draft | — | finance, billing, transactional |
| GL_JOURNAL | WS-FINANCE | Confidential | UnderReview | 62 | finance, ledger, sox |
| PRODUCT | WS-OPS | Restricted | Draft | — | product, master-data, operations |

SQL harness (99 assertions): `sqlcmd -S localhost -E -C -I -b -i database/57_Tests_Catalog.sql`  
Large-catalog benchmark (rolled back): `sqlcmd -S localhost -E -C -I -i database/58_Perf_Catalog.sql`

## PowerShell setup

```powershell
$base = "http://localhost:5015/api/catalog"
$h    = @{ "X-Api-Key" = "edip-dev-api-key" }
function Get($url)         { Invoke-RestMethod -Uri $url -Headers $h }
function Post($url, $body) { Invoke-RestMethod -Method Post -Uri $url -Headers $h -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 4) }
```

Failures return `{ statusCode, error }`:
- HTTP 404 for NotFound and InvalidDataset.
- HTTP 403 for Unauthorized.
- HTTP 400 for every other code.

Use `try { … } catch { $_.ErrorDetails.Message }` to see the body.

## 1. Access-aware discovery

| # | Call | Expected |
|---|------|----------|
| 1.1 | `Get "$base/datasets?userName=gov.admin"` | 6 current datasets (LEGACY_LEADS is archived, so hidden), `accessSource=PlatformAdmin` |
| 1.2 | `Get "$base/datasets?userName=gov.outsider"` | INVOICE (WorkspaceRole, `canReadData=true`) and GL_JOURNAL (WorkspaceRole, `canReadData=false`, `canRequestAccess=true`). **No WS-SALES datasets.** |
| 1.3 | `Get "$base/datasets?userName=gov.viewer"` | COUNTRY (Public, readable), CUSTOMER (`accessSource=DatasetShare`, Read), ORDER (metadata-only) |
| 1.4 | `Get "$base/datasets?userName=gov.analyst&searchText=customer"` | CUSTOMER with `accessSource=AccessGrant`, `effectiveAccessLevel=Write` |
| 1.5 | `Get "$base/datasets?userName=gov.owner&datasetStatus=Archived"` | LEGACY_LEADS (an archived filter implies includeInactive; owner is privileged) |
| 1.6 | `Get "$base/datasets?userName=gov.viewer&datasetStatus=Archived"` | Empty list |

## 2. Search & relevance

| # | Call | Expected |
|---|------|----------|
| 2.1 | `Get "$base/datasets?userName=gov.admin&searchText=customer"` | CUSTOMER 904 (name prefix plus other fields), INVOICE 900 ("Customer Invoices"), COUNTRY 301 (description), ORDER 150 (owner/steward) |
| 2.2 | `…&searchText=CUSTOMER MASTER` | CUSTOMER first, score ≥ 1000 (case-insensitive exact name) |
| 2.3 | `…&searchText=ledg` | GL_JOURNAL (partial match) |
| 2.4 | `…&searchText=pii` | CUSTOMER via tag tier (≥ 500) |
| 2.5 | `…&searchText=csv` | CUSTOMER (source type) |
| 2.6 | `…&searchText=%25` (a literal `%`) | Empty list. Wildcards are escaped. |
| 2.7 | `Get "$base/datasets?userName=gov.outsider&searchText=customer"` | INVOICE only |

## 3. Filters (composable)

| # | Call | Expected |
|---|------|----------|
| 3.1 | `…?userName=gov.admin&classificationCode=Confidential` | CUSTOMER, GL_JOURNAL |
| 3.2 | `…&classificationCode=Confidential&minQualityScore=60` | CUSTOMER 88, GL_JOURNAL 62 |
| 3.3 | `…&workspaceCode=WS-FINANCE&classificationCode=Internal` | INVOICE |
| 3.4 | `…&certificationStatusCode=Certified` | COUNTRY, CUSTOMER |
| 3.5 | `…&ownerUserName=gov.owner` | COUNTRY, CUSTOMER, ORDER |
| 3.6 | `…&ownerUserName=finance.steward@stratapps.com` | INVOICE (legacy text owner) |
| 3.7 | `…&sourceTypeCode=Csv` | CUSTOMER |
| 3.8 | `…&governanceStatusCode=UnderReview` | GL_JOURNAL |
| 3.9 | `…&updatedFrom=2026-10-01` | Datasets modified since 1 Oct |
| 3.10 | `…&classificationCode=Secret` | 400 `InvalidFilter` |
| 3.11 | `…&minQualityScore=90&maxQualityScore=10` | 400 `InvalidFilter` |

## 4. Tags

| # | Call | Expected |
|---|------|----------|
| 4.1 | `Get "$base/datasets?userName=gov.admin&tags=gold"` | COUNTRY, CUSTOMER |
| 4.2 | `…&tags=master-data,gold&tagMatch=All` | COUNTRY, CUSTOMER |
| 4.3 | `…&tags=pii,SOX&tagMatch=Any` | CUSTOMER, GL_JOURNAL (case-insensitive) |
| 4.4 | `Get "$base/tags?userName=gov.viewer"` | gold=2, master-data=2, sales=2, … (counts only discoverable datasets) |
| 4.5 | `Post "$base/datasets/ORDER/tags" @{ userName="gov.owner"; tags=@("smoke-test","Sales") }` | `Tagged`, tags include `smoke-test` and `sales` (normalized) |
| 4.6 | Same again | `NoChange` |
| 4.7 | `Post "$base/datasets/ORDER/tags/remove" @{ userName="gov.owner"; tags=@("smoke-test") }` | `Untagged` |
| 4.8 | `Post "$base/datasets/ORDER/tags" @{ userName="gov.viewer"; tags=@("x") }` | 403 `Unauthorized` |
| 4.9 | `…tags=@("bad tag!")` | 400 `InvalidTag` |
| 4.10 | `…tags=@("a,b")` | 400 `InvalidTag` (commas rejected by the service) |

Check the audit trail with `Get "http://localhost:5015/api/governance/audit?eventType=DatasetTagged"`.

## 5. Sorting & paging

| # | Call | Expected |
|---|------|----------|
| 5.1 | `…?userName=gov.admin&pageSize=3` | 3 items, `totalCount=6`, `hasMore=true`, `nextAfterValue="Customer Master"`, `sortBy=Name`, `sortDirection=ASC` |
| 5.2 | `…&pageSize=3&sortBy=Name&afterValue=Customer%20Master&afterDatasetId={nextAfterDatasetId}` | The next 3 rows (keyset), with `pageNumber=null` |
| 5.3 | `…&pageSize=3&pageNumber=2` | The same rows as 5.2 (offset) |
| 5.4 | `Get "$base/datasets?userName=gov.viewer&sortBy=QualityScore&sortDirection=DESC"` | COUNTRY 96.5, CUSTOMER 88, ORDER (null last) |
| 5.5 | `…&sortBy=LastImportDate` | Most recent import first |
| 5.6 | `…&sortBy=Bogus` | 400 `InvalidSort` |
| 5.7 | `…&sortBy=QualityScore&afterValue=50&afterDatasetId={guid}` | 400 `InvalidPaging` (keyset only for Name/Code/CreatedDate/UpdatedDate) |
| 5.8 | `…&includeTotalCount=false` | `totalCount=null` (cheaper, for infinite scroll) |

## 6. Dataset detail

| # | Call | Expected |
|---|------|----------|
| 6.1 | `Get "$base/datasets/CUSTOMER?userName=gov.viewer&includeHistory=true&historyCount=3"` | Summary `accessSource=DatasetShare/Read`, `currentVersion=26`, 5 tags, 5 recent imports, lineage 1 upstream / 2 downstream, 3 versions. `activeGrantCount=null` (not privileged). |
| 6.2 | `Get "$base/datasets/CUSTOMER?userName=gov.admin"` | `activeGrantCount=1`, `activeShareCount=1`, `qualityScore=88`, `qualityGrade=B`. History lists are empty (opt-in). |
| 6.3 | `Get "$base/datasets/PRODUCT?userName=gov.outsider"` | 404 `NotFound`. This is the same response as for a missing dataset. |
| 6.4 | `Get "$base/datasets/NOPE?userName=gov.admin"` | 404 `NotFound` |

## 7. Reports

| # | Call | Expected |
|---|------|----------|
| 7.1 | `Get "$base/reports/summary?userName=gov.viewer"` | total 3, readable 2, certified 2, tagged 3, avg quality 92.25 |
| 7.2 | `Get "$base/reports/summary?userName=gov.admin&workspaceCode=WS-FINANCE"` | total 2 |
| 7.3 | `Get "$base/reports/by-classification?userName=gov.admin"` | 4 rows (Public … Restricted, zeros included) |
| 7.4 | `Get "$base/reports/by-governance-status?userName=gov.admin"` | 5 rows |
| 7.5 | `Get "$base/reports/by-category?userName=gov.admin"` | Count, certified count and average quality per category |
| 7.6 | `Get "$base/reports/certification?userName=gov.admin"` | Certified group plus uncertified statuses, with % |
| 7.7 | `Get "$base/reports/quality-distribution?userName=gov.admin"` | Excellent / Good / Fair / Poor / NotProfiled |
| 7.8 | `Get "$base/reports/recently-updated?userName=gov.admin&days=30"` | Datasets updated in the window |
| 7.9 | `Get "$base/reports/recently-imported?userName=gov.admin&days=3650&top=3"` | CUSTOMER, ORDER, INVOICE (the demo imports are older than 30 days) |
| 7.10 | `Get "$base/reports/summary?userName=nobody"` | All zeros |
