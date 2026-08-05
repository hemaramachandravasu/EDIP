# Quality Scoring Approach

## Inputs
Quality assessment consumes the latest successful `dq.ProfilingRun` (or an explicit run id) plus catalogued relationships from `meta.ObjectRelationship`.

## Dimension weights
| Dimension | Weight | Source signal |
|-----------|--------|---------------|
| Missing values | 25% | Average column null % |
| Duplicates | 20% | Duplicate surplus / total rows |
| Invalid types | 15% | Heuristic invalid value counts |
| Referential integrity | 20% | Presence of catalogued FKs (neutral 90 if none) |
| Empty tables | 10% | Share of non-empty tables |
| Freshness | 10% | Age of latest `modify_date` |

## Overall score
```
Overall = Σ (DimensionScore × Weight)
Grade: A≥90, B≥80, C≥70, D≥60, else F
```

Each dimension score is scaled 0–100 (higher is better).

## Checks persisted
Every assessment writes `dq.QualityCheckResult` rows for:
`MISSING_VALUES`, `DUPLICATE_RECORDS`, `INVALID_TYPES`, `REFERENTIAL_INTEGRITY`, `EMPTY_TABLES`, `DATA_FRESHNESS`.

## API
- `POST /api/quality/{dataSourceId}/assess?profilingRunId=`
- `GET /api/quality/assessments/{assessmentId}`
- `GET /api/quality/source/{dataSourceId}`

## Reports
- `data-quality`, `dataset-health`, `quality-trend` (+ `/export?format=csv|xlsx`)
