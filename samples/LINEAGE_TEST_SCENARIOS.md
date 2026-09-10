# Lineage Test Scenarios

Expected results assume seed script `38_Seed_Lineage.sql` has run (demo graph + platform sync).

## 1. Simple / multi-level lineage
**Setup:** `DEMO_SOURCE_A → DEMO_DATASET_A → DEMO_DATASET_B → DEMO_DATASET_C → DEMO_REPORT_X`

| Query | Expected |
|-------|----------|
| Upstream of `DEMO_DATASET_C` | B (depth 1), A (depth 2), Source A (depth 3) |
| Downstream of `DEMO_DATASET_A` | B, C, Report X |
| Impact on `DEMO_DATASET_A` | Same as downstream (B, C, Report X) |

## 2. Multiple upstream / downstream
Platform sync creates Source → Import → Dataset (+ versions) for CUSTOMER batches. Upstream of CUSTOMER should include Import and optionally DataSource nodes.

## 3. Version-specific lineage
`GET /api/lineage/versions/CUSTOMER` returns version rows with ImportBatchId / EtlRunId / ProfileRunId when those runs were synced.

## 4. Circular dependency detection
Inserting `DEMO_DATASET_C → DEMO_DATASET_A` returns `CycleRejected`.  
`GET /api/lineage/circular` should not list the rejected edge (it was never stored).

## 5. Empty lineage
Upstream of `__NONE__` returns empty array.

## 6. Workspace filtering
With `@WorkspaceId = WS-SALES`, other-workspace `OTHER_WS_*` entities must not appear in filtered downstream of demo A.

## 7. Large graph / performance
`POST /api/lineage/sync?maxBatches=200` completes without timeout (API command timeout 120s). Recursive queries with `maxDepth=20` return in interactive time on seed data.

## 8. Analytics feeds
- `most-connected` ranks demo C / A highly
- `dataset-to-report` includes DEMO_REPORT_X and seeded CUSTOMER report assets
- `relationship-counts` > 0 after seed

## SQL harness
Run `database/40_Tests_Lineage.sql` after deploy.
