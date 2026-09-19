# Governance Test Scenarios

Assumes `44_Seed_Governance.sql` has run.

| # | Scenario | Expected |
|---|----------|----------|
| 1 | CUSTOMER classification | Confidential, Certified, owner=`gov.owner`, steward=`gov.steward` |
| 2 | Certification history | ≥2 rows (UnderReview → Certified) |
| 3 | Analyst Write policy | Allowed via approved grant |
| 4 | Outsider Read policy | Denied (cross-workspace) |
| 5 | Outsider submit request | `CrossWorkspaceDenied` |
| 6 | Viewer pending request | Appears in pending list |
| 7 | Duplicate pending | Second identical pending → `DuplicatePending` |
| 8 | Governance summary | TotalDatasets > 0, CertifiedDatasets ≥ 1 |
| 9 | By classification | Includes Confidential / Internal / Restricted |
| 10 | Audit events | ClassificationChanged / CertificationApproved / AccessRequested present |

SQL harness: `database/46_Tests_Governance.sql`
