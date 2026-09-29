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
    Task<IReadOnlyList<DTOs.ImportSummaryRow>> GetImportSummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.BatchProcessingHistoryRow>> GetBatchProcessingHistoryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ValidationErrorReportRow>> GetValidationErrorsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetProcessingStatisticsRow>> GetDatasetProcessingStatisticsAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportErrorTrendRow>> GetImportErrorTrendsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.BatchProcessingHistoryRow>> GetFailedImportsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlBatchSummaryRow>> GetEtlBatchSummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlSuccessRateRow>> GetEtlSuccessRateAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlFailedBatchRow>> GetEtlFailedBatchesAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlValidationErrorSummaryRow>> GetEtlValidationErrorSummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlDatasetHistoryRow>> GetEtlDatasetHistoryAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualitySummaryRow>> GetDatasetQualitySummaryAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualitySummaryRow>> GetLowestQualityDatasetsAsync(int take = 20, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.TopQualityIssueRow>> GetTopDataQualityIssuesAsync(int take = 50, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualityTrendRow>> GetDatasetQualityTrendAsync(string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.FailedThresholdReportRow>> GetFailedQualityThresholdsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualitySummaryRow>> GetDatasetQualityComparisonAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportQualitySummaryRow>> GetImportQualitySummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
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

public interface IIngestionRepository
{
    Task<IReadOnlyList<IngestDataset>> GetDatasetsAsync(CancellationToken ct = default);
    Task<Guid> CreateBatchAsync(string datasetCode, Guid? dataSourceId, string? sourceInfo, CancellationToken ct = default, string? sourceFile = null, string? loadMode = null, string? duplicateStrategy = null);
    Task LoadStagingCustomersAsync(Guid batchId, Guid datasetId, IReadOnlyList<StagingCustomerRow> rows, string? sourceInfo, CancellationToken ct = default);
    Task CompleteStagingLoadAsync(Guid batchId, CancellationToken ct = default);
    Task<ImportBatch?> GetBatchAsync(Guid batchId, CancellationToken ct = default);
    Task ValidateBatchAsync(Guid batchId, CancellationToken ct = default);
    Task ProcessBatchAsync(Guid batchId, string triggerType, CancellationToken ct = default);
    Task RetryBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<ImportError>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<ImportError>> GetErrorsByDatasetAsync(string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<int> ProcessPendingBatchesAsync(int maxBatches, CancellationToken ct = default);
    Task ArchiveImportHistoryAsync(int retainDays, CancellationToken ct = default);
    Task<Guid?> GetDatasetIdByCodeAsync(string datasetCode, CancellationToken ct = default);
}

public interface IEtlRepository
{
    Task RunPipelineAsync(Guid batchId, string triggerType, bool forceFail, CancellationToken ct = default);
    Task RetryBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlErrorDto>> GetErrorsByDatasetAsync(string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<int> ProcessPendingAsync(int maxBatches, CancellationToken ct = default);
    Task ArchiveErrorsAsync(int retainDays, CancellationToken ct = default);
    Task CleanupBatchesAsync(int retainDays, CancellationToken ct = default);
    Task GenerateQualitySnapshotAsync(CancellationToken ct = default);
    Task<Guid> GenerateTestBatchAsync(int rowCount, CancellationToken ct = default);
}

public interface IAnalyticsRepository
{
    // Refresh / maintenance
    Task<DTOs.AnalyticsRefreshResultDto> RefreshDailyMetricsAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct = default);
    Task<int> SnapshotQualityTrendAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct = default);

    // Dataset analytics
    Task<DTOs.DatasetCountSummaryDto> GetDatasetCountSummaryAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DimensionCountRow>> GetDatasetCountByDimensionAsync(string dimension, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.RecentDatasetRow>> GetRecentDatasetsAsync(string mode, DateTime? sinceUtc, int take, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetActivityRow>> GetDatasetActivityAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, int take, CancellationToken ct = default);

    // Import analytics
    Task<DTOs.ImportAnalyticsSummaryDto> GetImportAnalyticsSummaryAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportVolumeRow>> GetImportVolumeByDateAsync(DateTime fromUtc, DateTime toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportVolumeByDatasetRow>> GetImportVolumeByDatasetAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, CancellationToken ct = default);

    // Quality analytics
    Task<DTOs.QualityAnalyticsSummaryDto> GetQualityAnalyticsSummaryAsync(Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityByDatasetRow>> GetQualityByDatasetAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityByDatasetRow>> GetLowestQualityScoresAsync(int take, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityIssueBreakdownRow>> GetQualityIssueBreakdownAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, CancellationToken ct = default);

    // Trend analysis
    Task<IReadOnlyList<DTOs.QualityTrendSeriesRow>> GetQualityTrendSeriesAsync(string datasetCode, string periodType, DateTime? fromDate, DateTime? toDate, CancellationToken ct = default);
    Task<DTOs.QualityProfileComparisonDto?> GetQualityProfileComparisonAsync(string datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityPeriodComparisonRow>> GetQualityPeriodComparisonAsync(string periodType, string? datasetCode, Guid? workspaceId, CancellationToken ct = default);

    // Comparison / workspace / time
    Task<IReadOnlyList<DTOs.DatasetComparisonRow>> GetDatasetComparisonAsync(string? datasetCodes, Guid? workspaceId, int windowDays, int pageNumber, int pageSize, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.WorkspaceAnalyticsRow>> GetWorkspaceAnalyticsAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.TimeBasedActivityRow>> GetTimeBasedActivityAsync(DateTime fromUtc, DateTime toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QuarterlyTrendRow>> GetQuarterlyTrendsAsync(Guid? workspaceId, int quarters, CancellationToken ct = default);

    // Dashboard feeds
    Task<DTOs.DashboardKpiCardsDto> GetDashboardKpiCardsAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DashboardTrendPointRow>> GetDashboardTrendChartAsync(string? datasetCode, int days, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityDistributionRow>> GetDashboardQualityDistributionAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetDistributionRow>> GetDashboardDatasetDistributionAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DashboardImportActivityRow>> GetDashboardImportActivityAsync(int days, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DashboardTopIssueRow>> GetDashboardTopQualityIssuesAsync(int take, Guid? workspaceId, int days, CancellationToken ct = default);

    // Export feeds
    Task<IReadOnlyList<DTOs.DatasetInventoryExportRow>> GetDatasetInventoryExportAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportDetailExportRow>> GetImportDetailExportAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityDetailExportRow>> GetQualityDetailExportAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
}

public interface IDatasetProfileRepository
{
    Task<DTOs.ProfileRunDto> ProfileAsync(string datasetCode, string profileScope, string triggerType, Guid? importId, Guid? batchId, CancellationToken ct = default);
    Task<DTOs.ProfileRunDto?> GetRunAsync(Guid profileRunId, CancellationToken ct = default);
    Task<DTOs.ProfileRunDto?> GetLatestScoreAsync(string datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetColumnProfileDto>> GetColumnProfilesAsync(Guid profileRunId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualityIssueDto>> GetIssuesAsync(Guid profileRunId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetThresholdResultDto>> GetThresholdResultsAsync(Guid profileRunId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualityTrendRow>> GetTrendAsync(string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default);
    Task<int> ProfileDueDatasetsAsync(int maxDatasets, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays, CancellationToken ct = default);
}

public interface ILineageRepository
{
    Task<IReadOnlyList<DTOs.LineageNodeDto>> GetUpstreamAsync(Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber, Guid? workspaceId, int maxDepth, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageNodeDto>> GetDownstreamAsync(Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber, Guid? workspaceId, int maxDepth, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageNodeDto>> ImpactAnalysisAsync(Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber, string changeType, Guid? workspaceId, int maxDepth, CancellationToken ct = default);
    Task<DTOs.VersionLineageResultDto> GetVersionLineageAsync(string datasetCode, int? versionNumber, Guid? datasetVersionId, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CircularDependencyDto>> DetectCircularAsync(Guid? workspaceId, int maxDepth, CancellationToken ct = default);
    Task<DTOs.AddRelationshipResultDto> AddRelationshipAsync(DTOs.AddRelationshipRequest request, CancellationToken ct = default);
    Task<DTOs.LineageSyncResultDto> SyncPlatformAsync(int maxBatches, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageEntityDto>> GetEntitiesAsync(Guid? entityId, string? entityCode, string? entityTypeCode, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageConnectedRow>> GetMostConnectedAsync(Guid? workspaceId, int take, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDegreeRow>> GetHighestDependenciesAsync(Guid? workspaceId, int take, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDegreeRow>> GetHighestDependentsAsync(Guid? workspaceId, int take, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageRelationshipCountRow>> GetRelationshipCountsAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageSourceToDatasetRow>> GetSourceToDatasetCountsAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDatasetToReportRow>> GetDatasetToReportAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDepthRow>> GetDependencyDepthAsync(Guid? workspaceId, int maxDepth, CancellationToken ct = default);
}

public interface IGovernanceRepository
{
    Task<DTOs.DatasetGovernanceDto> UpsertAsync(string datasetCode, DTOs.UpsertDatasetGovernanceRequest request, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetGovernanceDto>> GetAsync(string? datasetCode, Guid? workspaceId, CancellationToken ct = default);
    Task<DTOs.DatasetGovernanceDto> CertifyAsync(string datasetCode, DTOs.CertifyDatasetRequest request, CancellationToken ct = default);
    Task<DTOs.DatasetGovernanceDto> SubmitForReviewAsync(string datasetCode, DTOs.SubmitReviewRequest request, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CertificationHistoryRow>> GetCertificationHistoryAsync(string datasetCode, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> SubmitAccessRequestAsync(DTOs.SubmitAccessRequest request, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> ApproveAccessRequestAsync(Guid accessRequestId, DTOs.ReviewAccessRequest request, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> RejectAccessRequestAsync(Guid accessRequestId, DTOs.ReviewAccessRequest request, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> RevokeAccessAsync(DTOs.RevokeAccessRequest request, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.AccessRequestDto>> GetPendingAccessRequestsAsync(Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.AccessRequestDto>> GetAccessRequestHistoryAsync(string? datasetCode, string? userName, Guid? workspaceId, int take, CancellationToken ct = default);
    Task<DTOs.PolicyEvaluationDto> EvaluateAccessAsync(string datasetCode, string userName, string requiredAccessLevel, CancellationToken ct = default);
    Task<DTOs.GovernanceSummaryDto> GetSummaryAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ClassificationCountRow>> GetByClassificationAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.GovernanceStatusCountRow>> GetStatusDistributionAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.AccessRequestsByWorkspaceRow>> GetAccessRequestsByWorkspaceAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.GovernanceAuditRow>> GetAuditEventsAsync(string? datasetCode, string? eventType, int take, CancellationToken ct = default);
    Task<int> ExpireCertificationsAsync(CancellationToken ct = default);
    Task ArchiveAuditAsync(int retainDays, CancellationToken ct = default);
}

public interface ISharingRepository
{
    Task<DTOs.ShareActionResult> CreateShareAsync(DTOs.CreateShareRequest request, CancellationToken ct = default);
    Task<DTOs.ShareActionResult> UpdateShareAsync(Guid shareId, DTOs.UpdateShareRequest request, CancellationToken ct = default);
    Task<DTOs.ShareActionResult> RevokeShareAsync(Guid shareId, DTOs.RevokeShareRequest request, CancellationToken ct = default);
    Task<DTOs.DatasetShareDto?> GetShareAsync(Guid shareId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetShareDto>> GetActiveSharesAsync(string? datasetCode, string? recipientUserName, Guid? workspaceId, CancellationToken ct = default);
    Task<DTOs.PagedList<DTOs.DatasetShareDto>> GetSharesAsync(string? datasetCode, string? recipientUserName, Guid? workspaceId, string? effectiveStatus, int pageNumber, int pageSize, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetShareDto>> GetExpiredSharesAsync(Guid? workspaceId, bool onlyUnmarked, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ShareHistoryRow>> GetShareHistoryAsync(Guid? shareId, string? datasetCode, string? recipientUserName, int take, CancellationToken ct = default);
    Task<int> ExpireSharesAsync(CancellationToken ct = default);

    Task<DTOs.ExportAccessEvaluationDto> EvaluateExportAccessAsync(string datasetCode, string userName, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportableColumnDto>> GetExportableColumnsAsync(string datasetCode, CancellationToken ct = default);
    Task<int> SyncExportableColumnsAsync(string? datasetCode, CancellationToken ct = default);

    Task<DTOs.ExportActionResult> SubmitExportAsync(string datasetCode, string userName, string formatCode, Guid? datasetVersionId,
        string? selectedColumnsJson, string? filtersJson, string? sortJson, CancellationToken ct = default);
    Task<DTOs.ExportActionResult> TransitionExportAsync(Guid exportRequestId, DTOs.TransitionExportRequest request, CancellationToken ct = default);
    Task<DTOs.ExportActionResult> ClaimNextExportAsync(CancellationToken ct = default);
    Task<DTOs.ExportRequestDetailDto?> GetExportRequestAsync(Guid exportRequestId, CancellationToken ct = default);
    Task<DTOs.ExportDataPageDto> GetExportDataAsync(Guid exportRequestId, string? userName, int pageSize, int pageNumber, string? afterKey, bool includeTotalCount, CancellationToken ct = default);
    Task<DTOs.ExportDownloadResult> RecordDownloadAsync(Guid exportRequestId, DTOs.RecordDownloadRequest request, CancellationToken ct = default);
    Task<DTOs.PagedList<DTOs.ExportRequestDto>> GetExportHistoryAsync(DTOs.ExportHistoryQuery query, CancellationToken ct = default);
    Task<DTOs.ExportCleanupResult> CleanupStaleExportsAsync(int processingTimeoutMinutes, int pendingTimeoutHours, CancellationToken ct = default);

    Task<DTOs.ExportSummaryDto> GetExportSummaryAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportCountRow>> GetExportsByFormatAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportCountRow>> GetExportsByDatasetAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportCountRow>> GetExportsByUserAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportActivityRow>> GetExportActivityAsync(int days, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ShareStatusSummaryRow>> GetShareStatusSummaryAsync(Guid? workspaceId, CancellationToken ct = default);
}
