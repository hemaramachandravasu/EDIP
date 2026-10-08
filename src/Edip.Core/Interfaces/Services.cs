using Edip.Core.Models;

namespace Edip.Core.Interfaces;

public sealed class ProbeResult
{
    public bool IsSuccess { get; init; }
    public string Message { get; init; } = string.Empty;
    public int LatencyMs { get; init; }
}

public interface IConnectionProbe
{
    string SupportedTypeCode { get; }
    Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default);
    Task<CapturedMetadataSnapshot> CaptureMetadataAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default);
}

public interface IConnectionProbeFactory
{
    IConnectionProbe GetProbe(string dataSourceTypeCode);
}

public interface IExportService
{
    byte[] ExportToCsv<T>(IEnumerable<T> rows);
    byte[] ExportToExcel<T>(IEnumerable<T> rows, string sheetName);
}

public interface IDataSourceService
{
    Task<IReadOnlyList<DTOs.DataSourceDto>> GetAllAsync(CancellationToken ct = default);
    Task<DTOs.DataSourceDto?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<DTOs.DataSourceDto> CreateAsync(DTOs.CreateDataSourceRequest request, CancellationToken ct = default);
    Task<DTOs.DataSourceDto?> UpdateAsync(Guid id, DTOs.UpdateDataSourceRequest request, CancellationToken ct = default);
    Task<bool> DeleteAsync(Guid id, CancellationToken ct = default);
    Task<DTOs.ValidationResultDto> ValidateAsync(Guid id, CancellationToken ct = default);
    Task<DTOs.DataSourceHealthDto?> GetHealthAsync(Guid id, CancellationToken ct = default);
}

public interface IMetadataService
{
    Task<DTOs.MetadataRefreshResultDto> RefreshAsync(Guid dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.SchemaObjectDto>> GetObjectsAsync(Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ColumnDefinitionDto>> GetColumnsAsync(Guid? schemaObjectId, Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ObjectRelationshipDto>> GetRelationshipsAsync(Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.MetadataRefreshResultDto>> GetRefreshHistoryAsync(Guid dataSourceId, CancellationToken ct = default);
}

public interface IProcessingJobService
{
    Task<IReadOnlyList<DTOs.ProcessingJobDto>> GetAllAsync(CancellationToken ct = default);
    Task<DTOs.ProcessingJobDto?> GetByIdAsync(Guid jobId, CancellationToken ct = default);
    Task<DTOs.ProcessingJobDto> CreateAsync(DTOs.CreateProcessingJobRequest request, CancellationToken ct = default);
    Task<DTOs.ProcessingJobDto?> UpdateAsync(Guid jobId, DTOs.UpdateProcessingJobRequest request, CancellationToken ct = default);
    Task<DTOs.ExecuteJobResultDto> ExecuteAsync(Guid jobId, Enums.JobTriggerType trigger, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.JobExecutionDto>> GetExecutionsAsync(Guid jobId, CancellationToken ct = default);
    Task ProcessDueJobsAsync(CancellationToken ct = default);
}

public interface IReportService
{
    Task<object> GetReportAsync(string reportName, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<(byte[] Content, string ContentType, string FileName)> ExportReportAsync(string reportName, string format, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
}

public interface IDataProfiler
{
    Task<ProfilingRun> ProfileAsync(DataSource source, string? plaintextPassword, string triggerType, CancellationToken ct = default);
}

public interface IProfilingService
{
    Task<DTOs.ProfilingRunDto> ProfileAsync(Guid dataSourceId, string triggerType = "Manual", CancellationToken ct = default);
    Task<DTOs.ProfilingRunDto?> GetRunAsync(Guid runId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ProfilingRunDto>> GetRunsAsync(Guid dataSourceId, CancellationToken ct = default);
}

public interface IQualityAssessmentService
{
    Task<DTOs.QualityAssessmentDto> AssessAsync(Guid dataSourceId, Guid? profilingRunId = null, CancellationToken ct = default);
    Task<DTOs.QualityAssessmentDto?> GetAssessmentAsync(Guid assessmentId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityAssessmentDto>> GetAssessmentsAsync(Guid dataSourceId, CancellationToken ct = default);
}

public interface IMetadataSyncService
{
    Task<DTOs.MetadataSyncResultDto> SynchronizeAsync(Guid dataSourceId, string triggerType = "Manual", CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.MetadataSyncResultDto>> GetSyncHistoryAsync(Guid dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.SchemaChangeEventDto>> GetSchemaChangesAsync(Guid dataSourceId, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays = 90, CancellationToken ct = default);
}

public interface IAnalyticsService
{
    Task<DTOs.AnalyticsRefreshResultDto> RefreshAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct = default);

    Task<DTOs.DatasetCountSummaryDto> GetDatasetCountSummaryAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DimensionCountRow>> GetDatasetCountByDimensionAsync(string dimension, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.RecentDatasetRow>> GetRecentDatasetsAsync(string mode, int days, int take, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetActivityRow>> GetDatasetActivityAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, string? datasetCode, int take, CancellationToken ct = default);

    Task<DTOs.ImportAnalyticsSummaryDto> GetImportAnalyticsSummaryAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportVolumeRow>> GetImportVolumeByDateAsync(DateTime? fromUtc, DateTime? toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportVolumeByDatasetRow>> GetImportVolumeByDatasetAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, CancellationToken ct = default);

    Task<DTOs.QualityAnalyticsSummaryDto> GetQualityAnalyticsSummaryAsync(Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityByDatasetRow>> GetQualityByDatasetAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityByDatasetRow>> GetLowestQualityScoresAsync(int take, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityIssueBreakdownRow>> GetQualityIssueBreakdownAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, CancellationToken ct = default);

    Task<IReadOnlyList<DTOs.QualityTrendSeriesRow>> GetQualityTrendSeriesAsync(string datasetCode, string periodType, DateTime? fromDate, DateTime? toDate, CancellationToken ct = default);
    Task<DTOs.QualityProfileComparisonDto?> GetQualityProfileComparisonAsync(string datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityPeriodComparisonRow>> GetQualityPeriodComparisonAsync(string periodType, string? datasetCode, Guid? workspaceId, CancellationToken ct = default);

    Task<IReadOnlyList<DTOs.DatasetComparisonRow>> GetDatasetComparisonAsync(string? datasetCodes, Guid? workspaceId, int windowDays, int pageNumber, int pageSize, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.WorkspaceAnalyticsRow>> GetWorkspaceAnalyticsAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.TimeBasedActivityRow>> GetTimeBasedActivityAsync(DateTime? fromUtc, DateTime? toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QuarterlyTrendRow>> GetQuarterlyTrendsAsync(Guid? workspaceId, int quarters, CancellationToken ct = default);

    Task<DTOs.DashboardKpiCardsDto> GetDashboardKpiCardsAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DashboardTrendPointRow>> GetDashboardTrendChartAsync(string? datasetCode, int days, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityDistributionRow>> GetDashboardQualityDistributionAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetDistributionRow>> GetDashboardDatasetDistributionAsync(Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DashboardImportActivityRow>> GetDashboardImportActivityAsync(int days, Guid? workspaceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DashboardTopIssueRow>> GetDashboardTopQualityIssuesAsync(int take, Guid? workspaceId, int days, CancellationToken ct = default);

    Task<(byte[] Content, string ContentType, string FileName)> ExportAsync(string feed, string format, DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default);
}

public interface IDatasetProfileService
{
    Task<DTOs.ProfileRunDto> ProfileAsync(string datasetCode, string profileScope = "Processed", Guid? importId = null, Guid? batchId = null, CancellationToken ct = default);
    Task<DTOs.ProfileRunDto?> GetRunAsync(Guid profileRunId, CancellationToken ct = default);
    Task<DTOs.ProfileRunDto?> GetLatestScoreAsync(string datasetCode, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetColumnProfileDto>> GetColumnProfilesAsync(Guid profileRunId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualityIssueDto>> GetIssuesAsync(Guid profileRunId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetThresholdResultDto>> GetThresholdResultsAsync(Guid profileRunId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetQualityTrendRow>> GetTrendAsync(string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<int> ProfileDueDatasetsAsync(int maxDatasets = 10, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays = 180, CancellationToken ct = default);
}

public interface ILineageService
{
    Task<IReadOnlyList<DTOs.LineageNodeDto>> GetUpstreamAsync(Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber, Guid? workspaceId, int maxDepth = 20, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageNodeDto>> GetDownstreamAsync(Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber, Guid? workspaceId, int maxDepth = 20, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageNodeDto>> ImpactAnalysisAsync(Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber, string changeType = "Dataset", Guid? workspaceId = null, int maxDepth = 20, CancellationToken ct = default);
    Task<DTOs.VersionLineageResultDto> GetVersionLineageAsync(string datasetCode, int? versionNumber = null, Guid? datasetVersionId = null, Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CircularDependencyDto>> DetectCircularAsync(Guid? workspaceId = null, int maxDepth = 50, CancellationToken ct = default);
    Task<DTOs.AddRelationshipResultDto> AddRelationshipAsync(DTOs.AddRelationshipRequest request, CancellationToken ct = default);
    Task<DTOs.LineageSyncResultDto> SyncPlatformAsync(int maxBatches = 200, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays = 365, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageEntityDto>> GetEntitiesAsync(Guid? entityId = null, string? entityCode = null, string? entityTypeCode = null, Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageConnectedRow>> GetMostConnectedAsync(Guid? workspaceId = null, int take = 20, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDegreeRow>> GetHighestDependenciesAsync(Guid? workspaceId = null, int take = 20, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDegreeRow>> GetHighestDependentsAsync(Guid? workspaceId = null, int take = 20, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageRelationshipCountRow>> GetRelationshipCountsAsync(Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageSourceToDatasetRow>> GetSourceToDatasetCountsAsync(Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDatasetToReportRow>> GetDatasetToReportAsync(Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.LineageDepthRow>> GetDependencyDepthAsync(Guid? workspaceId = null, int maxDepth = 20, CancellationToken ct = default);
}

public interface IGovernanceService
{
    Task<DTOs.DatasetGovernanceDto> UpsertAsync(string datasetCode, DTOs.UpsertDatasetGovernanceRequest request, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetGovernanceDto>> GetAsync(string? datasetCode = null, Guid? workspaceId = null, CancellationToken ct = default);
    Task<DTOs.DatasetGovernanceDto> CertifyAsync(string datasetCode, DTOs.CertifyDatasetRequest request, CancellationToken ct = default);
    Task<DTOs.DatasetGovernanceDto> SubmitForReviewAsync(string datasetCode, DTOs.SubmitReviewRequest request, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CertificationHistoryRow>> GetCertificationHistoryAsync(string datasetCode, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> SubmitAccessRequestAsync(DTOs.SubmitAccessRequest request, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> ApproveAccessRequestAsync(Guid accessRequestId, DTOs.ReviewAccessRequest request, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> RejectAccessRequestAsync(Guid accessRequestId, DTOs.ReviewAccessRequest request, CancellationToken ct = default);
    Task<DTOs.AccessRequestActionResult> RevokeAccessAsync(DTOs.RevokeAccessRequest request, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.AccessRequestDto>> GetPendingAccessRequestsAsync(Guid? workspaceId = null, string? datasetCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.AccessRequestDto>> GetAccessRequestHistoryAsync(string? datasetCode = null, string? userName = null, Guid? workspaceId = null, int take = 100, CancellationToken ct = default);
    Task<DTOs.PolicyEvaluationDto> EvaluateAccessAsync(string datasetCode, string userName, string requiredAccessLevel = "Read", CancellationToken ct = default);
    Task<DTOs.GovernanceSummaryDto> GetSummaryAsync(Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ClassificationCountRow>> GetByClassificationAsync(Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.GovernanceStatusCountRow>> GetStatusDistributionAsync(Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.AccessRequestsByWorkspaceRow>> GetAccessRequestsByWorkspaceAsync(CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.GovernanceAuditRow>> GetAuditEventsAsync(string? datasetCode = null, string? eventType = null, int take = 100, CancellationToken ct = default);
    Task<int> ExpireCertificationsAsync(CancellationToken ct = default);
    Task ArchiveAuditAsync(int retainDays = 730, CancellationToken ct = default);
}

public interface ISharingService
{
    Task<DTOs.ShareActionResult> CreateShareAsync(DTOs.CreateShareRequest request, CancellationToken ct = default);
    Task<DTOs.ShareActionResult> UpdateShareAsync(Guid shareId, DTOs.UpdateShareRequest request, CancellationToken ct = default);
    Task<DTOs.ShareActionResult> RevokeShareAsync(Guid shareId, DTOs.RevokeShareRequest request, CancellationToken ct = default);
    Task<DTOs.DatasetShareDto?> GetShareAsync(Guid shareId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetShareDto>> GetActiveSharesAsync(string? datasetCode = null, string? recipientUserName = null, Guid? workspaceId = null, CancellationToken ct = default);
    Task<DTOs.PagedList<DTOs.DatasetShareDto>> GetSharesAsync(string? datasetCode = null, string? recipientUserName = null, Guid? workspaceId = null, string? effectiveStatus = null, int pageNumber = 1, int pageSize = 50, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.DatasetShareDto>> GetExpiredSharesAsync(Guid? workspaceId = null, bool onlyUnmarked = false, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ShareHistoryRow>> GetShareHistoryAsync(Guid? shareId = null, string? datasetCode = null, string? recipientUserName = null, int take = 100, CancellationToken ct = default);
    Task<int> ExpireSharesAsync(CancellationToken ct = default);

    Task<DTOs.ExportAccessEvaluationDto> EvaluateExportAccessAsync(string datasetCode, string userName, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportableColumnDto>> GetExportableColumnsAsync(string datasetCode, CancellationToken ct = default);
    Task<int> SyncExportableColumnsAsync(string? datasetCode = null, CancellationToken ct = default);

    Task<DTOs.ExportActionResult> SubmitExportAsync(DTOs.SubmitExportRequest request, CancellationToken ct = default);
    Task<DTOs.ExportActionResult> TransitionExportAsync(Guid exportRequestId, DTOs.TransitionExportRequest request, CancellationToken ct = default);
    Task<DTOs.ExportActionResult> ClaimNextExportAsync(CancellationToken ct = default);
    Task<DTOs.ExportRequestDetailDto?> GetExportRequestAsync(Guid exportRequestId, CancellationToken ct = default);
    Task<DTOs.ExportDataPageDto> GetExportDataAsync(Guid exportRequestId, string? userName = null, int pageSize = 5000, int pageNumber = 1, string? afterKey = null, bool includeTotalCount = false, CancellationToken ct = default);
    Task<DTOs.ExportDownloadResult> RecordDownloadAsync(Guid exportRequestId, DTOs.RecordDownloadRequest request, CancellationToken ct = default);
    Task<DTOs.PagedList<DTOs.ExportRequestDto>> GetExportHistoryAsync(DTOs.ExportHistoryQuery query, CancellationToken ct = default);
    Task<DTOs.ExportCleanupResult> CleanupStaleExportsAsync(int processingTimeoutMinutes = 120, int pendingTimeoutHours = 72, CancellationToken ct = default);

    Task<DTOs.ExportSummaryDto> GetExportSummaryAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportCountRow>> GetExportsByFormatAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportCountRow>> GetExportsByDatasetAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportCountRow>> GetExportsByUserAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ExportActivityRow>> GetExportActivityAsync(int days = 30, Guid? workspaceId = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ShareStatusSummaryRow>> GetShareStatusSummaryAsync(Guid? workspaceId = null, CancellationToken ct = default);
}

public interface ICatalogService
{
    Task<DTOs.CatalogSearchResult> SearchAsync(DTOs.CatalogSearchQuery query, CancellationToken ct = default);
    Task<DTOs.CatalogDetailResult> GetDatasetDetailAsync(string datasetCode, string userName, int recentImportCount = 5,
        int lineageNeighborLimit = 20, bool includeHistory = false, int historyCount = 10, CancellationToken ct = default);

    Task<DTOs.CatalogTagListResult> GetTagsAsync(string userName, string? search = null, bool includeUnused = false, CancellationToken ct = default);
    Task<DTOs.DatasetTagActionResult> AddDatasetTagsAsync(string datasetCode, DTOs.DatasetTagsRequest request, CancellationToken ct = default);
    Task<DTOs.DatasetTagActionResult> RemoveDatasetTagsAsync(string datasetCode, DTOs.DatasetTagsRequest request, CancellationToken ct = default);

    Task<DTOs.CatalogSummaryDto> GetSummaryAsync(string userName, string? workspaceCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogCountRow>> GetByClassificationAsync(string userName, string? workspaceCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogCountRow>> GetByGovernanceStatusAsync(string userName, string? workspaceCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogCountRow>> GetByCategoryAsync(string userName, string? workspaceCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogCertificationRow>> GetCertificationAsync(string userName, string? workspaceCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogQualityBucketRow>> GetQualityDistributionAsync(string userName, string? workspaceCode = null, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogRecentDatasetRow>> GetRecentlyUpdatedAsync(string userName, string? workspaceCode = null, int days = 30, int top = 10, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.CatalogRecentDatasetRow>> GetRecentlyImportedAsync(string userName, string? workspaceCode = null, int days = 30, int top = 10, CancellationToken ct = default);
}

public interface IIngestionService
{
    Task<IReadOnlyList<DTOs.IngestDatasetDto>> GetDatasetsAsync(CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> CreateBatchAsync(DTOs.CreateImportBatchRequest request, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto?> GetBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> ValidateBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> ProcessBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> RetryBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportErrorDto>> GetErrorsByDatasetAsync(string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<int> ProcessPendingBatchesAsync(int maxBatches = 10, CancellationToken ct = default);
    Task ArchiveImportHistoryAsync(int retainDays = 90, CancellationToken ct = default);
}

public interface IEtlService
{
    Task<DTOs.ImportBatchDto> RunPipelineAsync(Guid batchId, bool forceFail = false, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> RetryAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto?> GetBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlErrorDto>> GetErrorsByDatasetAsync(string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<int> ProcessPendingAsync(int maxBatches = 10, CancellationToken ct = default);
    Task ArchiveErrorsAsync(int retainDays = 90, CancellationToken ct = default);
    Task CleanupBatchesAsync(int retainDays = 90, CancellationToken ct = default);
    Task GenerateQualitySnapshotAsync(CancellationToken ct = default);
    Task<Guid> GenerateTestBatchAsync(int rowCount = 1000, CancellationToken ct = default);
}
