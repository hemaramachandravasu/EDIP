# Future Enhancement Recommendations (Quality Module)

1. **Multi-engine profiling** — extend `IDataProfiler` for MySQL, PostgreSQL, and file samples.  
2. **Rule engine** — configurable thresholds per dataset (null %, freshness SLA, mandatory columns).  
3. **True RI validation** — execute orphan-key probes against live FKs, not catalog presence alone.  
4. **Anomaly detection** — compare profiling runs over time for sudden null/volume spikes.  
5. **Partition-aware profiling** — sample large fact tables instead of full scans.  
6. **Alerting** — webhook/email when grade drops below threshold.  
7. **Data classification** — PII tags feeding quality & governance dashboards.  
8. **Parallel workers** — queue-based profiling for multi-tenant scale.
