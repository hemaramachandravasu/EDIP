using Edip.Core.Enums;
using Edip.Core.Models;

namespace Edip.Core.Interfaces;

public interface ISecretProtector
{
    string Protect(string plaintext);
    string Unprotect(string protectedPayload);
}

public interface IDataSourceRepository
{
    Task<IReadOnlyList<DataSource>> GetAllAsync(CancellationToken ct = default);
    Task<DataSource?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<Guid> CreateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default);
    Task UpdateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default);
    Task SoftDeleteAsync(Guid id, CancellationToken ct = default);
    Task UpdateHealthAsync(Guid id, HealthStatus health, DateTime validatedUtc, CancellationToken ct = default);
    Task AddValidationLogAsync(ConnectionValidationLog log, CancellationToken ct = default);
    Task<IReadOnlyList<ConnectionValidationLog>> GetRecentValidationsAsync(Guid id, int take = 10, CancellationToken ct = default);
}

public interface IMetadataRepository
{
    Task<IReadOnlyList<SchemaObject>> GetObjectsAsync(Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<ColumnDefinition>> GetColumnsAsync(Guid? schemaObjectId, Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<ObjectRelationship>> GetRelationshipsAsync(Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<MetadataRefreshHistory>> GetRefreshHistoryAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default);
    Task<long> BeginRefreshAsync(Guid dataSourceId, CancellationToken ct = default);
    Task CompleteRefreshAsync(long historyId, string status, int objects, int columns, int relationships, string? error, CancellationToken ct = default);
    Task ReplaceSnapshotAsync(Guid dataSourceId, CapturedMetadataSnapshot snapshot, CancellationToken ct = default);
}

public interface IProcessingJobRepository
{
    Task<IReadOnlyList<ProcessingJob>> GetAllAsync(CancellationToken ct = default);
    Task<ProcessingJob?> GetByIdAsync(Guid jobId, CancellationToken ct = default);
    Task<Guid> CreateAsync(ProcessingJob job, CancellationToken ct = default);
    Task UpdateAsync(ProcessingJob job, CancellationToken ct = default);
    Task<IReadOnlyList<ProcessingJob>> GetDueJobsAsync(DateTime asOfUtc, CancellationToken ct = default);
    Task UpdateScheduleAfterRunAsync(Guid jobId, DateTime lastRunUtc, DateTime nextRunUtc, CancellationToken ct = default);
    Task<Guid> CreateExecutionAsync(JobExecution execution, CancellationToken ct = default);
    Task UpdateExecutionAsync(JobExecution execution, CancellationToken ct = default);
    Task AddExecutionLogAsync(Guid executionId, string level, string message, CancellationToken ct = default);
    Task<IReadOnlyList<JobExecution>> GetExecutionsAsync(Guid jobId, int take = 50, CancellationToken ct = default);
    Task AddRetryAttemptAsync(JobRetryAttempt attempt, CancellationToken ct = default);
    Task<JobExecution?> GetExecutionByIdAsync(Guid executionId, CancellationToken ct = default);
}

public interface IReportRepository
{
    Task<IReadOnlyList<DTOs.ProcessingSummaryRow>> GetProcessingSummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DataSourceHealthRow>> GetDataSourceHealthAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.JobExecutionStatsRow>> GetJobExecutionStatsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.MetadataRefreshStatusRow>> GetMetadataRefreshStatusAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DataQualitySummaryRow>> GetDataQualitySummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetHealthRow>> GetDatasetHealthAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.SchemaChangeHistoryRow>> GetSchemaChangeHistoryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.MetadataSyncStatusRow>> GetMetadataSyncStatusAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityTrendRow>> GetQualityTrendAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
}

public interface IQualityRepository
{
    Task<Guid> CreateProfilingRunAsync(ProfilingRun run, CancellationToken ct = default);
    Task CompleteProfilingRunAsync(Guid runId, string status, int tables, int columns, string? error, CancellationToken ct = default);
    Task SaveTableProfilesAsync(Guid runId, IReadOnlyList<TableProfile> tables, CancellationToken ct = default);
    Task<ProfilingRun?> GetProfilingRunAsync(Guid runId, CancellationToken ct = default);
    Task<IReadOnlyList<ProfilingRun>> GetProfilingRunsAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default);
    Task<ProfilingRun?> GetLatestSucceededRunAsync(Guid dataSourceId, CancellationToken ct = default);
    Task<Guid> SaveQualityAssessmentAsync(QualityAssessment assessment, CancellationToken ct = default);
    Task<QualityAssessment?> GetAssessmentAsync(Guid assessmentId, CancellationToken ct = default);
    Task<IReadOnlyList<QualityAssessment>> GetAssessmentsAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default);
    Task<Guid> BeginSyncLogAsync(MetadataSyncLog log, CancellationToken ct = default);
    Task CompleteSyncLogAsync(Guid syncLogId, string status, int added, int removed, int changed, string? error, CancellationToken ct = default);
    Task AddSchemaChangesAsync(Guid dataSourceId, Guid syncLogId, IReadOnlyList<SchemaChangeEvent> changes, CancellationToken ct = default);
    Task<IReadOnlyList<SchemaChangeEvent>> GetSchemaChangesAsync(Guid dataSourceId, int take = 50, CancellationToken ct = default);
    Task<IReadOnlyList<MetadataSyncLog>> GetSyncLogsAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays, CancellationToken ct = default);
}
