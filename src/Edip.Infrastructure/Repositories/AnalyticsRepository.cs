using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

/// <summary>
/// ADO.NET access to the Task 19 analytics stored procedures.
/// Every call: parameterised, async, scoped connection (await using),
/// explicit command timeout, exceptions surfaced to the caller.
/// </summary>
public sealed class AnalyticsRepository(ISqlConnectionFactory connectionFactory) : IAnalyticsRepository
{
    private const int ReadTimeoutSeconds = 60;
    private const int RefreshTimeoutSeconds = 300;

    // ---------- generic helpers ----------

    private async Task<IReadOnlyList<T>> QueryAsync<T>(
        string proc,
        Action<SqlParameterCollection> bind,
        Func<SqlDataReader, T> map,
        int timeoutSeconds,
        CancellationToken ct)
    {
        var list = new List<T>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(proc, conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = timeoutSeconds
        };
        bind(cmd.Parameters);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(map(reader));
        return list;
    }

    private async Task<T> SingleAsync<T>(
        string proc,
        Action<SqlParameterCollection> bind,
        Func<SqlDataReader, T> map,
        CancellationToken ct)
        where T : new()
    {
        var rows = await QueryAsync(proc, bind, map, ReadTimeoutSeconds, ct);
        return rows.Count > 0 ? rows[0] : new T();
    }

    private Task<IReadOnlyList<T>> QueryAsync<T>(string proc, Action<SqlParameterCollection> bind, Func<SqlDataReader, T> map, CancellationToken ct)
        => QueryAsync(proc, bind, map, ReadTimeoutSeconds, ct);

    // ---------- refresh / maintenance ----------

    public async Task<AnalyticsRefreshResultDto> RefreshDailyMetricsAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("analytics.usp_RefreshDailyMetrics", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = RefreshTimeoutSeconds
        };
        cmd.Parameters.AddNullable("@FromDate", fromDate?.Date);
        cmd.Parameters.AddNullable("@ToDate", toDate?.Date);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var result = new AnalyticsRefreshResultDto();
        if (await reader.ReadAsync(ct))
        {
            result.RowsRefreshed = reader.GetInt32("RowsRefreshed");
            result.FromDate = reader.GetDateTime("FromDate");
            result.ToDate = reader.GetDateTime("ToDate");
        }
        return result;
    }

    public async Task<int> SnapshotQualityTrendAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("analytics.usp_SnapshotQualityTrend", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = RefreshTimeoutSeconds
        };
        cmd.Parameters.AddNullable("@FromDate", fromDate?.Date);
        cmd.Parameters.AddNullable("@ToDate", toDate?.Date);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? reader.GetInt32("SnapshotsMerged") : 0;
    }

    // ---------- dataset analytics ----------

    public Task<DatasetCountSummaryDto> GetDatasetCountSummaryAsync(Guid? workspaceId, CancellationToken ct = default)
        => SingleAsync("rpt.usp_DatasetCountSummary",
            p => p.AddNullable("@WorkspaceId", workspaceId),
            r => new DatasetCountSummaryDto
            {
                TotalDatasets = r.GetInt32("TotalDatasets"),
                ActiveDatasets = r.GetInt32("ActiveDatasets"),
                StatusActive = r.GetInt32("StatusActive"),
                StatusInactive = r.GetInt32("StatusInactive"),
                StatusDraft = r.GetInt32("StatusDraft"),
                StatusArchived = r.GetInt32("StatusArchived"),
                StatusDeprecated = r.GetInt32("StatusDeprecated"),
                DistinctWorkspaces = r.GetInt32("DistinctWorkspaces"),
                DistinctCategories = r.GetInt32("DistinctCategories"),
                DistinctOwners = r.GetInt32("DistinctOwners"),
                CreatedLast7d = r.GetInt32("CreatedLast7d"),
                CreatedLast30d = r.GetInt32("CreatedLast30d"),
                ModifiedLast7d = r.GetInt32("ModifiedLast7d"),
                ModifiedLast30d = r.GetInt32("ModifiedLast30d")
            }, ct);

    public Task<IReadOnlyList<DimensionCountRow>> GetDatasetCountByDimensionAsync(string dimension, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DatasetCountByDimension",
            p => { p.AddWithValue("@Dimension", dimension); p.AddNullable("@WorkspaceId", workspaceId); },
            r => new DimensionCountRow
            {
                Dimension = r.GetString("Dimension"),
                DimensionValue = r.GetNullableString("DimensionValue") ?? "(none)",
                DatasetCount = r.GetInt32("DatasetCount"),
                ActiveCount = r.GetInt32("ActiveCount"),
                SharePct = r.GetDecimal("SharePct")
            }, ct);

    public Task<IReadOnlyList<RecentDatasetRow>> GetRecentDatasetsAsync(string mode, DateTime? sinceUtc, int take, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_RecentDatasets",
            p =>
            {
                p.AddWithValue("@Mode", mode);
                p.AddNullable("@SinceUtc", sinceUtc);
                p.AddWithValue("@Take", take);
                p.AddNullable("@WorkspaceId", workspaceId);
            },
            r => new RecentDatasetRow
            {
                DatasetId = r.GetGuid("DatasetId"),
                DatasetCode = r.GetString("DatasetCode"),
                DisplayName = r.GetString("DisplayName"),
                Category = r.GetString("Category"),
                OwnerName = r.GetString("OwnerName"),
                DatasetStatus = r.GetString("DatasetStatus"),
                WorkspaceCode = r.GetNullableString("WorkspaceCode"),
                WorkspaceName = r.GetNullableString("WorkspaceName"),
                CreatedUtc = r.GetDateTime("CreatedUtc"),
                ModifiedUtc = r.GetDateTime("ModifiedUtc")
            }, ct);

    public Task<IReadOnlyList<DatasetActivityRow>> GetDatasetActivityAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, int take, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DatasetActivity",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@DatasetCode", datasetCode);
                p.AddWithValue("@Take", take);
            },
            r => new DatasetActivityRow
            {
                ActivityUtc = r.GetDateTime("ActivityUtc"),
                DatasetCode = r.GetString("DatasetCode"),
                DisplayName = r.GetString("DisplayName"),
                WorkspaceCode = r.GetNullableString("WorkspaceCode"),
                ActivityType = r.GetString("ActivityType"),
                Outcome = r.GetString("Outcome"),
                RefId = r.GetGuid("RefId"),
                Detail = r.GetNullableString("Detail")
            }, ct);

    // ---------- import analytics ----------

    public Task<ImportAnalyticsSummaryDto> GetImportAnalyticsSummaryAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => SingleAsync("rpt.usp_ImportAnalyticsSummary",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@DatasetCode", datasetCode);
            },
            r => new ImportAnalyticsSummaryDto
            {
                TotalImports = r.GetInt32("TotalImports"),
                SuccessfulImports = r.GetInt32("SuccessfulImports"),
                FailedImports = r.GetInt32("FailedImports"),
                CompletedWithErrors = r.GetInt32("CompletedWithErrors"),
                InProgressOrPending = r.GetInt32("InProgressOrPending"),
                RecordsReceived = r.GetNullableInt64("RecordsReceived") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                RecordsInserted = r.GetNullableInt64("RecordsInserted") ?? 0,
                RecordsUpdated = r.GetNullableInt64("RecordsUpdated") ?? 0,
                ErrorCount = r.GetNullableInt64("ErrorCount") ?? 0,
                ImportSuccessRatePct = r.GetNullableDecimal("ImportSuccessRatePct") ?? 0m,
                AvgProcessingSeconds = r.GetNullableDecimal("AvgProcessingSeconds"),
                RejectRatePct = r.GetNullableDecimal("RejectRatePct")
            }, ct);

    public Task<IReadOnlyList<ImportVolumeRow>> GetImportVolumeByDateAsync(DateTime fromUtc, DateTime toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => QueryAsync("rpt.usp_ImportVolumeByDate",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddWithValue("@Granularity", granularity);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@DatasetCode", datasetCode);
            },
            r => new ImportVolumeRow
            {
                PeriodStart = r.GetDateTime("PeriodStart"),
                Granularity = r.GetString("Granularity"),
                ImportCount = r.GetInt32("ImportCount"),
                SuccessfulImports = r.GetInt32("SuccessfulImports"),
                FailedImports = r.GetInt32("FailedImports"),
                CompletedWithErrors = r.GetInt32("CompletedWithErrors"),
                RecordsReceived = r.GetNullableInt64("RecordsReceived") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                SuccessRatePct = r.GetNullableDecimal("SuccessRatePct") ?? 0m
            }, ct);

    public Task<IReadOnlyList<ImportVolumeByDatasetRow>> GetImportVolumeByDatasetAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_ImportVolumeByDataset",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddNullable("@WorkspaceId", workspaceId);
            },
            r => new ImportVolumeByDatasetRow
            {
                DatasetId = r.GetGuid("DatasetId"),
                DatasetCode = r.GetString("DatasetCode"),
                DisplayName = r.GetString("DisplayName"),
                WorkspaceCode = r.GetNullableString("WorkspaceCode"),
                ImportCount = r.GetInt32("ImportCount"),
                SuccessfulImports = r.GetInt32("SuccessfulImports"),
                FailedImports = r.GetInt32("FailedImports"),
                RecordsReceived = r.GetNullableInt64("RecordsReceived") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                SuccessRatePct = r.GetNullableDecimal("SuccessRatePct") ?? 0m,
                LastImportUtc = r.GetNullableDateTime("LastImportUtc")
            }, ct);

    // ---------- quality analytics ----------

    public Task<QualityAnalyticsSummaryDto> GetQualityAnalyticsSummaryAsync(Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => SingleAsync("rpt.usp_QualityAnalyticsSummary",
            p => { p.AddNullable("@WorkspaceId", workspaceId); p.AddNullable("@DatasetCode", datasetCode); },
            r => new QualityAnalyticsSummaryDto
            {
                DatasetsWithProfile = r.GetInt32("DatasetsWithProfile"),
                AvgOverallScore = r.GetNullableDecimal("AvgOverallScore"),
                MinOverallScore = r.GetNullableDecimal("MinOverallScore"),
                MaxOverallScore = r.GetNullableDecimal("MaxOverallScore"),
                AvgCompletenessPct = r.GetNullableDecimal("AvgCompletenessPct"),
                AvgValidityPct = r.GetNullableDecimal("AvgValidityPct"),
                AvgUniquenessPct = r.GetNullableDecimal("AvgUniquenessPct"),
                AvgConsistencyPct = r.GetNullableDecimal("AvgConsistencyPct"),
                ThresholdPassing = r.GetInt32("ThresholdPassing"),
                ThresholdFailing = r.GetInt32("ThresholdFailing"),
                ThresholdUnknown = r.GetInt32("ThresholdUnknown"),
                TotalQualityIssues = r.GetNullableInt64("TotalQualityIssues") ?? 0,
                GradeA = r.GetInt32("GradeA"),
                GradeB = r.GetInt32("GradeB"),
                GradeC = r.GetInt32("GradeC"),
                GradeD = r.GetInt32("GradeD"),
                GradeF = r.GetInt32("GradeF")
            }, ct);

    private static QualityByDatasetRow MapQualityByDataset(SqlDataReader r) => new()
    {
        DatasetCode = r.GetString("DatasetCode"),
        DisplayName = r.GetString("DisplayName"),
        Category = r.GetString("Category"),
        OwnerName = r.GetString("OwnerName"),
        OverallScore = r.GetNullableDecimal("OverallScore"),
        Grade = r.GetNullableString("Grade"),
        CompletenessPct = r.GetNullableDecimal("CompletenessPct"),
        ValidityPct = r.GetNullableDecimal("ValidityPct"),
        UniquenessPct = r.GetNullableDecimal("UniquenessPct"),
        ConsistencyPct = r.GetNullableDecimal("ConsistencyPct"),
        DuplicatePct = HasColumn(r, "DuplicatePct") ? r.GetNullableDecimal("DuplicatePct") : null,
        ThresholdResult = r.GetNullableString("ThresholdResult"),
        IssueCount = r.GetNullableInt32("IssueCount"),
        TotalRecords = HasColumn(r, "TotalRecords") ? r.GetNullableInt64("TotalRecords") : null,
        ProfiledUtc = r.GetNullableDateTime("ProfiledUtc"),
        FailedThresholdCount = HasColumn(r, "FailedThresholdCount") ? r.GetInt32("FailedThresholdCount") : 0
    };

    private static bool HasColumn(SqlDataReader r, string name)
    {
        for (var i = 0; i < r.FieldCount; i++)
            if (string.Equals(r.GetName(i), name, StringComparison.OrdinalIgnoreCase)) return true;
        return false;
    }

    public Task<IReadOnlyList<QualityByDatasetRow>> GetQualityByDatasetAsync(Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_QualityByDataset",
            p => p.AddNullable("@WorkspaceId", workspaceId), MapQualityByDataset, ct);

    public Task<IReadOnlyList<QualityByDatasetRow>> GetLowestQualityScoresAsync(int take, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_LowestQualityScores",
            p => { p.AddWithValue("@Take", take); p.AddNullable("@WorkspaceId", workspaceId); },
            MapQualityByDataset, ct);

    public Task<IReadOnlyList<QualityIssueBreakdownRow>> GetQualityIssueBreakdownAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_QualityIssueBreakdown",
            p => { p.AddWithValue("@FromUtc", fromUtc); p.AddWithValue("@ToUtc", toUtc); p.AddNullable("@WorkspaceId", workspaceId); },
            r => new QualityIssueBreakdownRow
            {
                IssueType = r.GetString("IssueType"),
                Severity = r.GetString("Severity"),
                OccurrenceCount = r.GetInt32("OccurrenceCount"),
                AffectedRecords = r.GetNullableInt64("AffectedRecords") ?? 0,
                DatasetsAffected = r.GetInt32("DatasetsAffected")
            }, ct);

    // ---------- trend analysis ----------

    public Task<IReadOnlyList<QualityTrendSeriesRow>> GetQualityTrendSeriesAsync(string datasetCode, string periodType, DateTime? fromDate, DateTime? toDate, CancellationToken ct = default)
        => QueryAsync("rpt.usp_QualityTrendSeries",
            p =>
            {
                p.AddWithValue("@DatasetCode", datasetCode);
                p.AddWithValue("@PeriodType", periodType);
                p.AddNullable("@FromDate", fromDate?.Date);
                p.AddNullable("@ToDate", toDate?.Date);
            },
            r => new QualityTrendSeriesRow
            {
                DatasetCode = r.GetString("DatasetCode"),
                PeriodType = r.GetString("PeriodType"),
                PeriodStart = r.GetDateTime("PeriodStart"),
                ProfileRunCount = r.GetInt32("ProfileRunCount"),
                OverallScore = r.GetNullableDecimal("OverallScore"),
                CompletenessPct = r.GetNullableDecimal("CompletenessPct"),
                ValidityPct = r.GetNullableDecimal("ValidityPct"),
                UniquenessPct = r.GetNullableDecimal("UniquenessPct"),
                ConsistencyPct = r.GetNullableDecimal("ConsistencyPct"),
                FailedThresholdRuns = r.GetInt32("FailedThresholdRuns"),
                PrevOverallScore = r.GetNullableDecimal("PrevOverallScore"),
                PrevCompletenessPct = r.GetNullableDecimal("PrevCompletenessPct"),
                PrevValidityPct = r.GetNullableDecimal("PrevValidityPct"),
                PrevUniquenessPct = r.GetNullableDecimal("PrevUniquenessPct"),
                PrevConsistencyPct = r.GetNullableDecimal("PrevConsistencyPct"),
                DeltaOverallScore = r.GetNullableDecimal("DeltaOverallScore"),
                DeltaCompletenessPct = r.GetNullableDecimal("DeltaCompletenessPct"),
                DeltaValidityPct = r.GetNullableDecimal("DeltaValidityPct"),
                DeltaUniquenessPct = r.GetNullableDecimal("DeltaUniquenessPct"),
                DeltaConsistencyPct = r.GetNullableDecimal("DeltaConsistencyPct"),
                OverallScore3pMovingAvg = r.GetNullableDecimal("OverallScore3pMovingAvg")
            }, ct);

    public async Task<QualityProfileComparisonDto?> GetQualityProfileComparisonAsync(string datasetCode, CancellationToken ct = default)
    {
        var rows = await QueryAsync("rpt.usp_QualityProfileComparison",
            p => p.AddWithValue("@DatasetCode", datasetCode),
            r => new QualityProfileComparisonDto
            {
                DatasetCode = r.GetString("DatasetCode"),
                CurrentRunId = r.IsDBNull(r.GetOrdinal("CurrentRunId")) ? null : r.GetGuid("CurrentRunId"),
                CurrentUtc = r.GetNullableDateTime("CurrentUtc"),
                PreviousRunId = r.IsDBNull(r.GetOrdinal("PreviousRunId")) ? null : r.GetGuid("PreviousRunId"),
                PreviousUtc = r.GetNullableDateTime("PreviousUtc"),
                CurrentOverallScore = r.GetNullableDecimal("CurrentOverallScore"),
                PreviousOverallScore = r.GetNullableDecimal("PreviousOverallScore"),
                DeltaOverallScore = r.GetNullableDecimal("DeltaOverallScore"),
                CurrentCompletenessPct = r.GetNullableDecimal("CurrentCompletenessPct"),
                PreviousCompletenessPct = r.GetNullableDecimal("PreviousCompletenessPct"),
                DeltaCompletenessPct = r.GetNullableDecimal("DeltaCompletenessPct"),
                CurrentValidityPct = r.GetNullableDecimal("CurrentValidityPct"),
                PreviousValidityPct = r.GetNullableDecimal("PreviousValidityPct"),
                DeltaValidityPct = r.GetNullableDecimal("DeltaValidityPct"),
                CurrentUniquenessPct = r.GetNullableDecimal("CurrentUniquenessPct"),
                PreviousUniquenessPct = r.GetNullableDecimal("PreviousUniquenessPct"),
                DeltaUniquenessPct = r.GetNullableDecimal("DeltaUniquenessPct"),
                CurrentConsistencyPct = r.GetNullableDecimal("CurrentConsistencyPct"),
                PreviousConsistencyPct = r.GetNullableDecimal("PreviousConsistencyPct"),
                DeltaConsistencyPct = r.GetNullableDecimal("DeltaConsistencyPct"),
                CurrentGrade = r.GetNullableString("CurrentGrade"),
                PreviousGrade = r.GetNullableString("PreviousGrade"),
                CurrentThreshold = r.GetNullableString("CurrentThreshold"),
                PreviousThreshold = r.GetNullableString("PreviousThreshold"),
                CurrentIssueCount = r.GetNullableInt32("CurrentIssueCount"),
                PreviousIssueCount = r.GetNullableInt32("PreviousIssueCount")
            }, ct);
        return rows.Count > 0 ? rows[0] : null;
    }

    public Task<IReadOnlyList<QualityPeriodComparisonRow>> GetQualityPeriodComparisonAsync(string periodType, string? datasetCode, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_QualityPeriodComparison",
            p =>
            {
                p.AddWithValue("@PeriodType", periodType);
                p.AddNullable("@DatasetCode", datasetCode);
                p.AddNullable("@WorkspaceId", workspaceId);
            },
            r => new QualityPeriodComparisonRow
            {
                Bucket = r.GetString("Bucket"),
                ProfileRunCount = r.GetInt32("ProfileRunCount"),
                AvgOverallScore = r.GetNullableDecimal("AvgOverallScore"),
                AvgCompletenessPct = r.GetNullableDecimal("AvgCompletenessPct"),
                AvgValidityPct = r.GetNullableDecimal("AvgValidityPct"),
                AvgUniquenessPct = r.GetNullableDecimal("AvgUniquenessPct"),
                AvgConsistencyPct = r.GetNullableDecimal("AvgConsistencyPct"),
                FailedThresholdRuns = r.GetInt32("FailedThresholdRuns")
            }, ct);

    // ---------- comparison / workspace / time ----------

    public Task<IReadOnlyList<DatasetComparisonRow>> GetDatasetComparisonAsync(string? datasetCodes, Guid? workspaceId, int windowDays, int pageNumber, int pageSize, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DatasetComparison",
            p =>
            {
                p.AddNullable("@DatasetCodes", datasetCodes);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddWithValue("@WindowDays", windowDays);
                p.AddWithValue("@PageNumber", pageNumber);
                p.AddWithValue("@PageSize", pageSize);
            },
            r => new DatasetComparisonRow
            {
                DatasetCode = r.GetString("DatasetCode"),
                DisplayName = r.GetString("DisplayName"),
                Category = r.GetString("Category"),
                OwnerName = r.GetString("OwnerName"),
                RecordCount = r.GetNullableInt64("RecordCount") ?? 0,
                QualityScore = r.GetNullableDecimal("QualityScore"),
                CompletenessPct = r.GetNullableDecimal("CompletenessPct"),
                ValidityPct = r.GetNullableDecimal("ValidityPct"),
                UniquenessPct = r.GetNullableDecimal("UniquenessPct"),
                ConsistencyPct = r.GetNullableDecimal("ConsistencyPct"),
                Grade = r.GetNullableString("Grade"),
                ThresholdResult = r.GetNullableString("ThresholdResult"),
                ImportCount = r.GetInt32("ImportCount"),
                ImportsPerWeek = r.GetNullableDecimal("ImportsPerWeek") ?? 0m,
                ErrorRatePct = r.GetNullableDecimal("ErrorRatePct"),
                TotalRows = r.GetInt32("TotalRows")
            }, ct);

    public Task<IReadOnlyList<WorkspaceAnalyticsRow>> GetWorkspaceAnalyticsAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
        => QueryAsync("rpt.usp_WorkspaceAnalytics",
            p =>
            {
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@FromUtc", fromUtc);
                p.AddNullable("@ToUtc", toUtc);
            },
            r => new WorkspaceAnalyticsRow
            {
                WorkspaceId = r.GetGuid("WorkspaceId"),
                WorkspaceCode = r.GetString("WorkspaceCode"),
                WorkspaceName = r.GetString("WorkspaceName"),
                DatasetCount = r.GetInt32("DatasetCount"),
                ActiveDatasetCount = r.GetInt32("ActiveDatasetCount"),
                ImportVolume = r.GetInt32("ImportVolume"),
                DataProcessingVolume = r.GetNullableInt64("DataProcessingVolume") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                AvgQualityScore = r.GetNullableDecimal("AvgQualityScore"),
                FailedQualityThresholds = r.GetInt32("FailedQualityThresholds"),
                QualityIssues = r.GetNullableInt64("QualityIssues") ?? 0
            }, ct);

    public Task<IReadOnlyList<TimeBasedActivityRow>> GetTimeBasedActivityAsync(DateTime fromUtc, DateTime toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => QueryAsync("rpt.usp_TimeBasedActivity",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddWithValue("@Granularity", granularity);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@DatasetCode", datasetCode);
            },
            r => new TimeBasedActivityRow
            {
                PeriodStart = r.GetDateTime("PeriodStart"),
                Granularity = r.GetString("Granularity"),
                ImportCount = r.GetNullableInt32("ImportCount") ?? 0,
                SuccessfulImports = r.GetNullableInt32("SuccessfulImports") ?? 0,
                FailedImports = r.GetNullableInt32("FailedImports") ?? 0,
                CompletedWithErrors = r.GetNullableInt32("CompletedWithErrors") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                ProfileRunCount = r.GetNullableInt32("ProfileRunCount") ?? 0,
                AvgOverallScore = r.GetNullableDecimal("AvgOverallScore"),
                FailedThresholdRuns = r.GetNullableInt32("FailedThresholdRuns") ?? 0,
                QualityIssueCount = r.GetNullableInt32("QualityIssueCount") ?? 0
            }, ct);

    public Task<IReadOnlyList<QuarterlyTrendRow>> GetQuarterlyTrendsAsync(Guid? workspaceId, int quarters, CancellationToken ct = default)
        => QueryAsync("rpt.usp_QuarterlyTrends",
            p => { p.AddNullable("@WorkspaceId", workspaceId); p.AddWithValue("@Quarters", quarters); },
            r => new QuarterlyTrendRow
            {
                QuarterStart = r.GetDateTime("QuarterStart"),
                QuarterLabel = r.GetString("QuarterLabel"),
                ImportCount = r.GetNullableInt32("ImportCount") ?? 0,
                SuccessfulImports = r.GetNullableInt32("SuccessfulImports") ?? 0,
                FailedImports = r.GetNullableInt32("FailedImports") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                ProfileRunCount = r.GetNullableInt32("ProfileRunCount") ?? 0,
                AvgOverallScore = r.GetNullableDecimal("AvgOverallScore"),
                QualityIssueCount = r.GetNullableInt32("QualityIssueCount") ?? 0,
                DeltaImportCount = r.GetNullableInt32("DeltaImportCount"),
                DeltaAvgOverallScore = r.GetNullableDecimal("DeltaAvgOverallScore"),
                ImportCountQoQPct = r.GetNullableDecimal("ImportCountQoQPct")
            }, ct);

    // ---------- dashboard feeds ----------

    public Task<DashboardKpiCardsDto> GetDashboardKpiCardsAsync(Guid? workspaceId, CancellationToken ct = default)
        => SingleAsync("rpt.usp_DashboardKpiCards",
            p => p.AddNullable("@WorkspaceId", workspaceId),
            r => new DashboardKpiCardsDto
            {
                TotalDatasets = r.GetInt32("TotalDatasets"),
                ActiveDatasets = r.GetInt32("ActiveDatasets"),
                Imports30d = r.GetInt32("Imports30d"),
                ImportsPrev30d = r.GetInt32("ImportsPrev30d"),
                ImportSuccessRate30dPct = r.GetNullableDecimal("ImportSuccessRate30dPct"),
                RecordsProcessed30d = r.GetNullableInt64("RecordsProcessed30d") ?? 0,
                RecordsRejected30d = r.GetNullableInt64("RecordsRejected30d") ?? 0,
                AvgQualityScore = r.GetNullableDecimal("AvgQualityScore"),
                DatasetsFailingThreshold = r.GetInt32("DatasetsFailingThreshold"),
                OpenQualityIssues = r.GetNullableInt64("OpenQualityIssues") ?? 0
            }, ct);

    public Task<IReadOnlyList<DashboardTrendPointRow>> GetDashboardTrendChartAsync(string? datasetCode, int days, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DashboardTrendChart",
            p => { p.AddNullable("@DatasetCode", datasetCode); p.AddWithValue("@Days", days); p.AddNullable("@WorkspaceId", workspaceId); },
            r => new DashboardTrendPointRow
            {
                MetricDate = r.GetDateTime("MetricDate"),
                ImportCount = r.GetNullableInt32("ImportCount") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0,
                AvgOverallScore = r.GetNullableDecimal("AvgOverallScore"),
                AvgCompletenessPct = r.GetNullableDecimal("AvgCompletenessPct"),
                AvgValidityPct = r.GetNullableDecimal("AvgValidityPct"),
                QualityIssueCount = r.GetNullableInt32("QualityIssueCount") ?? 0
            }, ct);

    public Task<IReadOnlyList<QualityDistributionRow>> GetDashboardQualityDistributionAsync(Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DashboardQualityDistribution",
            p => p.AddNullable("@WorkspaceId", workspaceId),
            r => new QualityDistributionRow
            {
                ScoreBand = r.GetString("ScoreBand"),
                BandOrder = r.GetInt32("BandOrder"),
                DatasetCount = r.GetInt32("DatasetCount"),
                SharePct = r.GetNullableDecimal("SharePct")
            }, ct);

    public Task<IReadOnlyList<DatasetDistributionRow>> GetDashboardDatasetDistributionAsync(Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DashboardDatasetDistribution",
            p => p.AddNullable("@WorkspaceId", workspaceId),
            r => new DatasetDistributionRow
            {
                Dimension = r.GetString("Dimension"),
                DimensionValue = r.GetNullableString("DimensionValue") ?? "(none)",
                DatasetCount = r.GetInt32("DatasetCount")
            }, ct);

    public Task<IReadOnlyList<DashboardImportActivityRow>> GetDashboardImportActivityAsync(int days, Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DashboardImportActivity",
            p => { p.AddWithValue("@Days", days); p.AddNullable("@WorkspaceId", workspaceId); },
            r => new DashboardImportActivityRow
            {
                MetricDate = r.GetDateTime("MetricDate"),
                ImportCount = r.GetNullableInt32("ImportCount") ?? 0,
                SuccessfulImports = r.GetNullableInt32("SuccessfulImports") ?? 0,
                FailedImports = r.GetNullableInt32("FailedImports") ?? 0,
                CompletedWithErrors = r.GetNullableInt32("CompletedWithErrors") ?? 0,
                RecordsProcessed = r.GetNullableInt64("RecordsProcessed") ?? 0,
                RecordsRejected = r.GetNullableInt64("RecordsRejected") ?? 0
            }, ct);

    public Task<IReadOnlyList<DashboardTopIssueRow>> GetDashboardTopQualityIssuesAsync(int take, Guid? workspaceId, int days, CancellationToken ct = default)
        => QueryAsync("rpt.usp_DashboardTopQualityIssues",
            p => { p.AddWithValue("@Take", take); p.AddNullable("@WorkspaceId", workspaceId); p.AddWithValue("@Days", days); },
            r => new DashboardTopIssueRow
            {
                DatasetCode = r.GetString("DatasetCode"),
                IssueType = r.GetString("IssueType"),
                ColumnName = r.GetNullableString("ColumnName"),
                ErrorCode = r.GetNullableString("ErrorCode"),
                Severity = r.GetString("Severity"),
                AffectedCount = r.GetNullableInt64("AffectedCount") ?? 0,
                OccurrenceCount = r.GetInt32("OccurrenceCount")
            }, ct);

    // ---------- export feeds ----------

    public Task<IReadOnlyList<DatasetInventoryExportRow>> GetDatasetInventoryExportAsync(Guid? workspaceId, CancellationToken ct = default)
        => QueryAsync("rpt.usp_ExportDatasetInventory",
            p => p.AddNullable("@WorkspaceId", workspaceId),
            r => new DatasetInventoryExportRow
            {
                DatasetCode = r.GetString("DatasetCode"),
                DisplayName = r.GetString("DisplayName"),
                WorkspaceCode = r.GetNullableString("WorkspaceCode"),
                Category = r.GetString("Category"),
                OwnerName = r.GetString("OwnerName"),
                DatasetStatus = r.GetString("DatasetStatus"),
                IsActive = r.GetBoolean("IsActive"),
                CreatedUtc = r.GetDateTime("CreatedUtc"),
                ModifiedUtc = r.GetDateTime("ModifiedUtc"),
                OverallScore = r.GetNullableDecimal("OverallScore"),
                Grade = r.GetNullableString("Grade"),
                ThresholdResult = r.GetNullableString("ThresholdResult"),
                IssueCount = r.GetNullableInt32("IssueCount"),
                ProfiledUtc = r.GetNullableDateTime("ProfiledUtc"),
                TotalImports = r.GetInt32("TotalImports")
            }, ct);

    public Task<IReadOnlyList<ImportDetailExportRow>> GetImportDetailExportAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => QueryAsync("rpt.usp_ExportImportDetail",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@DatasetCode", datasetCode);
            },
            r => new ImportDetailExportRow
            {
                BatchId = r.GetGuid("BatchId"),
                ImportId = r.GetGuid("ImportId"),
                DatasetCode = r.GetString("DatasetCode"),
                WorkspaceCode = r.GetNullableString("WorkspaceCode"),
                Status = r.GetString("Status"),
                TotalRecords = r.GetInt32("TotalRecords"),
                ValidRecords = r.GetInt32("ValidRecords"),
                ProcessedRecords = r.GetInt32("ProcessedRecords"),
                RejectedRecords = r.GetInt32("RejectedRecords"),
                InsertedRecords = r.GetInt32("InsertedRecords"),
                UpdatedRecords = r.GetInt32("UpdatedRecords"),
                ErrorCount = r.GetInt32("ErrorCount"),
                AttemptCount = r.GetInt32("AttemptCount"),
                ImportUtc = r.GetDateTime("ImportUtc"),
                StartedUtc = r.GetNullableDateTime("StartedUtc"),
                CompletedUtc = r.GetNullableDateTime("CompletedUtc"),
                DurationMs = r.GetNullableInt32("DurationMs"),
                SourceInfo = r.GetNullableString("SourceInfo"),
                SourceFile = r.GetNullableString("SourceFile")
            }, ct);

    public Task<IReadOnlyList<QualityDetailExportRow>> GetQualityDetailExportAsync(DateTime fromUtc, DateTime toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => QueryAsync("rpt.usp_ExportQualityDetail",
            p =>
            {
                p.AddWithValue("@FromUtc", fromUtc);
                p.AddWithValue("@ToUtc", toUtc);
                p.AddNullable("@WorkspaceId", workspaceId);
                p.AddNullable("@DatasetCode", datasetCode);
            },
            r => new QualityDetailExportRow
            {
                ProfileRunId = r.GetGuid("ProfileRunId"),
                DatasetCode = r.GetString("DatasetCode"),
                WorkspaceCode = r.GetNullableString("WorkspaceCode"),
                ProfiledUtc = r.GetDateTime("ProfiledUtc"),
                Status = r.GetString("Status"),
                OverallScore = r.GetDecimal("OverallScore"),
                Grade = r.GetString("Grade"),
                CompletenessPct = r.GetDecimal("CompletenessPct"),
                ValidityPct = r.GetDecimal("ValidityPct"),
                UniquenessPct = r.GetDecimal("UniquenessPct"),
                ConsistencyPct = r.GetDecimal("ConsistencyPct"),
                DuplicatePct = r.GetDecimal("DuplicatePct"),
                ThresholdResult = r.GetString("ThresholdResult"),
                IssueCount = r.GetInt32("IssueCount"),
                TotalRecords = r.GetInt64("TotalRecords"),
                ValidRecords = r.GetInt64("ValidRecords"),
                InvalidRecords = r.GetInt64("InvalidRecords"),
                DuplicateRecords = r.GetInt64("DuplicateRecords"),
                DurationMs = r.GetNullableInt32("DurationMs")
            }, ct);
}
