# Export samples

Use the API (with `X-Api-Key: edip-dev-api-key`) after profiling/assessing:

```http
GET /api/reports/data-quality/export?format=csv
GET /api/reports/dataset-health/export?format=xlsx
GET /api/reports/schema-changes/export?format=csv
GET /api/reports/metadata-sync/export?format=xlsx
GET /api/reports/quality-trend/export?format=csv
```

Suggested demo sequence against local catalog `AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA`:

1. `POST /api/metadata-sync/{id}`
2. `POST /api/profiling/{id}`
3. `POST /api/quality/{id}/assess`
4. Export the reports above
