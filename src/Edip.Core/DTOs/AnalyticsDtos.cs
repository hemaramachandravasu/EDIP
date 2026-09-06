namespace Edip.Core.DTOs;

// ============================================================
// Task 19 - SQL Analytics & Reporting Engine result contracts
// ============================================================

public sealed class DatasetCountSummaryDto
{
    public int TotalDatasets { get; set; }
    public int ActiveDatasets { get; set; }
    public int StatusActive { get; set; }
    public int StatusInactive { get; set; }
    public int StatusDraft { get; set; }
    public int StatusArchived { get; set; }
    public int StatusDeprecated { get; set; }
    public int DistinctWorkspaces { get; set; }
    public int DistinctCategories { get; set; }
    public int DistinctOwners { get; set; }
    public int CreatedLast7d { get; set; }
    public int CreatedLast30d { get; set; }
    public int ModifiedLast7d { get; set; }
    public int ModifiedLast30d { get; set; }
}

public sealed class DimensionCountRow
{
    public string Dimension { get; set; } = string.Empty;
    public string DimensionValue { get; set; } = string.Empty;
    public int DatasetCount { get; set; }
    public int ActiveCount { get; set; }
    public decimal SharePct { get; set; }
}

public sealed class RecentDatasetRow
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string OwnerName { get; set; } = string.Empty;
    public string DatasetStatus { get; set; } = string.Empty;
    public string? WorkspaceCode { get; set; }
    public string? WorkspaceName { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime ModifiedUtc { get; set; }
}

public sealed class DatasetActivityRow
{
    public DateTime ActivityUtc { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? WorkspaceCode { get; set; }
    public string ActivityType { get; set; } = string.Empty;
    public string Outcome { get; set; } = string.Empty;
    public Guid RefId { get; set; }
    public string? Detail { get; set; }
}

public sealed class ImportAnalyticsSummaryDto
{
    public int TotalImports { get; set; }
    public int SuccessfulImports { get; set; }
    public int FailedImports { get; set; }
    public int CompletedWithErrors { get; set; }
    public int InProgressOrPending { get; set; }
    public long RecordsReceived { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
    public long RecordsInserted { get; set; }
    public long RecordsUpdated { get; set; }
    public long ErrorCount { get; set; }
    public decimal ImportSuccessRatePct { get; set; }
    public decimal? AvgProcessingSeconds { get; set; }
    public decimal? RejectRatePct { get; set; }
}

public sealed class ImportVolumeRow
{
    public DateTime PeriodStart { get; set; }
    public string Granularity { get; set; } = string.Empty;
    public int ImportCount { get; set; }
    public int SuccessfulImports { get; set; }
    public int FailedImports { get; set; }
    public int CompletedWithErrors { get; set; }
    public long RecordsReceived { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
    public decimal SuccessRatePct { get; set; }
}

public sealed class ImportVolumeByDatasetRow
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? WorkspaceCode { get; set; }
    public int ImportCount { get; set; }
    public int SuccessfulImports { get; set; }
    public int FailedImports { get; set; }
    public long RecordsReceived { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
    public decimal SuccessRatePct { get; set; }
    public DateTime? LastImportUtc { get; set; }
}

public sealed class QualityAnalyticsSummaryDto
{
    public int DatasetsWithProfile { get; set; }
    public decimal? AvgOverallScore { get; set; }
    public decimal? MinOverallScore { get; set; }
    public decimal? MaxOverallScore { get; set; }
    public decimal? AvgCompletenessPct { get; set; }
    public decimal? AvgValidityPct { get; set; }
    public decimal? AvgUniquenessPct { get; set; }
    public decimal? AvgConsistencyPct { get; set; }
    public int ThresholdPassing { get; set; }
    public int ThresholdFailing { get; set; }
    public int ThresholdUnknown { get; set; }
    public long TotalQualityIssues { get; set; }
    public int GradeA { get; set; }
    public int GradeB { get; set; }
    public int GradeC { get; set; }
    public int GradeD { get; set; }
    public int GradeF { get; set; }
}

public sealed class QualityByDatasetRow
{
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string OwnerName { get; set; } = string.Empty;
    public decimal? OverallScore { get; set; }
    public string? Grade { get; set; }
    public decimal? CompletenessPct { get; set; }
    public decimal? ValidityPct { get; set; }
    public decimal? UniquenessPct { get; set; }
    public decimal? ConsistencyPct { get; set; }
    public decimal? DuplicatePct { get; set; }
    public string? ThresholdResult { get; set; }
    public int? IssueCount { get; set; }
    public long? TotalRecords { get; set; }
    public DateTime? ProfiledUtc { get; set; }
    public int FailedThresholdCount { get; set; }
}

public sealed class QualityIssueBreakdownRow
{
    public string IssueType { get; set; } = string.Empty;
    public string Severity { get; set; } = string.Empty;
    public int OccurrenceCount { get; set; }
    public long AffectedRecords { get; set; }
    public int DatasetsAffected { get; set; }
}

public sealed class QualityTrendSeriesRow
{
    public string DatasetCode { get; set; } = string.Empty;
    public string PeriodType { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public int ProfileRunCount { get; set; }
    public decimal? OverallScore { get; set; }
    public decimal? CompletenessPct { get; set; }
    public decimal? ValidityPct { get; set; }
    public decimal? UniquenessPct { get; set; }
    public decimal? ConsistencyPct { get; set; }
    public int FailedThresholdRuns { get; set; }
    public decimal? PrevOverallScore { get; set; }
    public decimal? PrevCompletenessPct { get; set; }
    public decimal? PrevValidityPct { get; set; }
    public decimal? PrevUniquenessPct { get; set; }
    public decimal? PrevConsistencyPct { get; set; }
    public decimal? DeltaOverallScore { get; set; }
    public decimal? DeltaCompletenessPct { get; set; }
    public decimal? DeltaValidityPct { get; set; }
    public decimal? DeltaUniquenessPct { get; set; }
    public decimal? DeltaConsistencyPct { get; set; }
    public decimal? OverallScore3pMovingAvg { get; set; }
}

public sealed class QualityProfileComparisonDto
{
    public string DatasetCode { get; set; } = string.Empty;
    public Guid? CurrentRunId { get; set; }
    public DateTime? CurrentUtc { get; set; }
    public Guid? PreviousRunId { get; set; }
    public DateTime? PreviousUtc { get; set; }
    public decimal? CurrentOverallScore { get; set; }
    public decimal? PreviousOverallScore { get; set; }
    public decimal? DeltaOverallScore { get; set; }
    public decimal? CurrentCompletenessPct { get; set; }
    public decimal? PreviousCompletenessPct { get; set; }
    public decimal? DeltaCompletenessPct { get; set; }
    public decimal? CurrentValidityPct { get; set; }
    public decimal? PreviousValidityPct { get; set; }
    public decimal? DeltaValidityPct { get; set; }
    public decimal? CurrentUniquenessPct { get; set; }
    public decimal? PreviousUniquenessPct { get; set; }
    public decimal? DeltaUniquenessPct { get; set; }
    public decimal? CurrentConsistencyPct { get; set; }
    public decimal? PreviousConsistencyPct { get; set; }
    public decimal? DeltaConsistencyPct { get; set; }
    public string? CurrentGrade { get; set; }
    public string? PreviousGrade { get; set; }
    public string? CurrentThreshold { get; set; }
    public string? PreviousThreshold { get; set; }
    public int? CurrentIssueCount { get; set; }
    public int? PreviousIssueCount { get; set; }
}

public sealed class QualityPeriodComparisonRow
{
    public string Bucket { get; set; } = string.Empty;
    public int ProfileRunCount { get; set; }
    public decimal? AvgOverallScore { get; set; }
    public decimal? AvgCompletenessPct { get; set; }
    public decimal? AvgValidityPct { get; set; }
    public decimal? AvgUniquenessPct { get; set; }
    public decimal? AvgConsistencyPct { get; set; }
    public int FailedThresholdRuns { get; set; }
}

public sealed class DatasetComparisonRow
{
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string Category { get; set; } = string.Empty;
    public string OwnerName { get; set; } = string.Empty;
    public long RecordCount { get; set; }
    public decimal? QualityScore { get; set; }
    public decimal? CompletenessPct { get; set; }
    public decimal? ValidityPct { get; set; }
    public decimal? UniquenessPct { get; set; }
    public decimal? ConsistencyPct { get; set; }
    public string? Grade { get; set; }
    public string? ThresholdResult { get; set; }
    public int ImportCount { get; set; }
    public decimal ImportsPerWeek { get; set; }
    public decimal? ErrorRatePct { get; set; }
    public int TotalRows { get; set; }
}

public sealed class WorkspaceAnalyticsRow
{
    public Guid WorkspaceId { get; set; }
    public string WorkspaceCode { get; set; } = string.Empty;
    public string WorkspaceName { get; set; } = string.Empty;
    public int DatasetCount { get; set; }
    public int ActiveDatasetCount { get; set; }
    public int ImportVolume { get; set; }
    public long DataProcessingVolume { get; set; }
    public long RecordsRejected { get; set; }
    public decimal? AvgQualityScore { get; set; }
    public int FailedQualityThresholds { get; set; }
    public long QualityIssues { get; set; }
}

public sealed class TimeBasedActivityRow
{
    public DateTime PeriodStart { get; set; }
    public string Granularity { get; set; } = string.Empty;
    public int ImportCount { get; set; }
    public int SuccessfulImports { get; set; }
    public int FailedImports { get; set; }
    public int CompletedWithErrors { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
    public int ProfileRunCount { get; set; }
    public decimal? AvgOverallScore { get; set; }
    public int FailedThresholdRuns { get; set; }
    public int QualityIssueCount { get; set; }
}

public sealed class QuarterlyTrendRow
{
    public DateTime QuarterStart { get; set; }
    public string QuarterLabel { get; set; } = string.Empty;
    public int ImportCount { get; set; }
    public int SuccessfulImports { get; set; }
    public int FailedImports { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
    public int ProfileRunCount { get; set; }
    public decimal? AvgOverallScore { get; set; }
    public int QualityIssueCount { get; set; }
    public int? DeltaImportCount { get; set; }
    public decimal? DeltaAvgOverallScore { get; set; }
    public decimal? ImportCountQoQPct { get; set; }
}

public sealed class DashboardKpiCardsDto
{
    public int TotalDatasets { get; set; }
    public int ActiveDatasets { get; set; }
    public int Imports30d { get; set; }
    public int ImportsPrev30d { get; set; }
    public decimal? ImportSuccessRate30dPct { get; set; }
    public long RecordsProcessed30d { get; set; }
    public long RecordsRejected30d { get; set; }
    public decimal? AvgQualityScore { get; set; }
    public int DatasetsFailingThreshold { get; set; }
    public long OpenQualityIssues { get; set; }
}

public sealed class DashboardTrendPointRow
{
    public DateTime MetricDate { get; set; }
    public int ImportCount { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
    public decimal? AvgOverallScore { get; set; }
    public decimal? AvgCompletenessPct { get; set; }
    public decimal? AvgValidityPct { get; set; }
    public int QualityIssueCount { get; set; }
}

public sealed class QualityDistributionRow
{
    public string ScoreBand { get; set; } = string.Empty;
    public int BandOrder { get; set; }
    public int DatasetCount { get; set; }
    public decimal? SharePct { get; set; }
}

public sealed class DatasetDistributionRow
{
    public string Dimension { get; set; } = string.Empty;
    public string DimensionValue { get; set; } = string.Empty;
    public int DatasetCount { get; set; }
}

public sealed class DashboardImportActivityRow
{
    public DateTime MetricDate { get; set; }
    public int ImportCount { get; set; }
    public int SuccessfulImports { get; set; }
    public int FailedImports { get; set; }
    public int CompletedWithErrors { get; set; }
    public long RecordsProcessed { get; set; }
    public long RecordsRejected { get; set; }
}

public sealed class DashboardTopIssueRow
{
    public string DatasetCode { get; set; } = string.Empty;
    public string IssueType { get; set; } = string.Empty;
    public string? ColumnName { get; set; }
    public string? ErrorCode { get; set; }
    public string Severity { get; set; } = string.Empty;
    public long AffectedCount { get; set; }
    public int OccurrenceCount { get; set; }
}

public sealed class DatasetInventoryExportRow
{
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? WorkspaceCode { get; set; }
    public string Category { get; set; } = string.Empty;
    public string OwnerName { get; set; } = string.Empty;
    public string DatasetStatus { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime ModifiedUtc { get; set; }
    public decimal? OverallScore { get; set; }
    public string? Grade { get; set; }
    public string? ThresholdResult { get; set; }
    public int? IssueCount { get; set; }
    public DateTime? ProfiledUtc { get; set; }
    public int TotalImports { get; set; }
}

public sealed class ImportDetailExportRow
{
    public Guid BatchId { get; set; }
    public Guid ImportId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string? WorkspaceCode { get; set; }
    public string Status { get; set; } = string.Empty;
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int ProcessedRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int InsertedRecords { get; set; }
    public int UpdatedRecords { get; set; }
    public int ErrorCount { get; set; }
    public int AttemptCount { get; set; }
    public DateTime ImportUtc { get; set; }
    public DateTime? StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int? DurationMs { get; set; }
    public string? SourceInfo { get; set; }
    public string? SourceFile { get; set; }
}

public sealed class QualityDetailExportRow
{
    public Guid ProfileRunId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string? WorkspaceCode { get; set; }
    public DateTime ProfiledUtc { get; set; }
    public string Status { get; set; } = string.Empty;
    public decimal OverallScore { get; set; }
    public string Grade { get; set; } = string.Empty;
    public decimal CompletenessPct { get; set; }
    public decimal ValidityPct { get; set; }
    public decimal UniquenessPct { get; set; }
    public decimal ConsistencyPct { get; set; }
    public decimal DuplicatePct { get; set; }
    public string ThresholdResult { get; set; } = string.Empty;
    public int IssueCount { get; set; }
    public long TotalRecords { get; set; }
    public long ValidRecords { get; set; }
    public long InvalidRecords { get; set; }
    public long DuplicateRecords { get; set; }
    public int? DurationMs { get; set; }
}

public sealed class AnalyticsRefreshResultDto
{
    public int RowsRefreshed { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int SnapshotsMerged { get; set; }
}
