using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class ReportRepository(ISqlConnectionFactory connectionFactory) : IReportRepository
{
    public async Task<IReadOnlyList<ProcessingSummaryRow>> GetProcessingSummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<ProcessingSummaryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_ProcessingSuccessFailureSummary @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ProcessingSummaryRow
            {
                DayUtc = reader.GetDateTime("DayUtc"),
                TotalExecutions = reader.GetInt32("TotalExecutions"),
                Succeeded = reader.GetInt32("Succeeded"),
                Failed = reader.GetInt32("Failed"),
                Retrying = reader.GetInt32("Retrying"),
                SuccessRatePct = reader.GetDecimal("SuccessRatePct")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DataSourceHealthRow>> GetDataSourceHealthAsync(CancellationToken ct = default)
    {
        var list = new List<DataSourceHealthRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_DataSourceHealthStatus;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DataSourceHealthRow
            {
                DataSourceId = reader.GetGuid("DataSourceId"),
                Name = reader.GetString("Name"),
                DataSourceTypeCode = reader.GetString("DataSourceTypeCode"),
                Status = reader.GetString("Status"),
                HealthStatus = reader.GetString("HealthStatus"),
                LastValidatedUtc = reader.GetNullableDateTime("LastValidatedUtc"),
                ValidationFailures24h = reader.GetInt32("ValidationFailures24h")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<JobExecutionStatsRow>> GetJobExecutionStatsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<JobExecutionStatsRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_JobExecutionStatistics @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new JobExecutionStatsRow
            {
                JobId = reader.GetGuid("JobId"),
                JobName = reader.GetString("JobName"),
                JobType = reader.GetString("JobType"),
                TotalRuns = reader.GetInt32("TotalRuns"),
                Succeeded = reader.GetInt32("Succeeded"),
                Failed = reader.GetInt32("Failed"),
                AvgDurationSeconds = reader.GetNullableDouble("AvgDurationSeconds"),
                LastRunUtc = reader.GetNullableDateTime("LastRunUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<MetadataRefreshStatusRow>> GetMetadataRefreshStatusAsync(CancellationToken ct = default)
    {
        var list = new List<MetadataRefreshStatusRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_MetadataRefreshStatus;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new MetadataRefreshStatusRow
            {
                DataSourceId = reader.GetGuid("DataSourceId"),
                DataSourceName = reader.GetString("DataSourceName"),
                LastRefreshUtc = reader.GetNullableDateTime("LastRefreshUtc"),
                LastStatus = reader.GetNullableString("LastStatus"),
                ObjectsCaptured = reader.GetNullableInt32("ObjectsCaptured"),
                ColumnsCaptured = reader.GetNullableInt32("ColumnsCaptured"),
                RefreshCount30d = reader.GetInt32("RefreshCount30d")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DataQualitySummaryRow>> GetDataQualitySummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<DataQualitySummaryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_DataQualitySummary @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DataQualitySummaryRow
            {
                DataSourceId = reader.GetGuid("DataSourceId"),
                DataSourceName = reader.GetString("DataSourceName"),
                AssessmentId = reader.GetGuid("AssessmentId"),
                OverallScore = reader.GetDecimal("OverallScore"),
                Grade = reader.GetString("Grade"),
                MissingScore = reader.GetDecimal("MissingScore"),
                DuplicateScore = reader.GetDecimal("DuplicateScore"),
                TypeScore = reader.GetDecimal("TypeScore"),
                ReferentialScore = reader.GetDecimal("ReferentialScore"),
                EmptyTableScore = reader.GetDecimal("EmptyTableScore"),
                FreshnessScore = reader.GetDecimal("FreshnessScore"),
                AssessedUtc = reader.GetDateTime("AssessedUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DatasetHealthRow>> GetDatasetHealthAsync(CancellationToken ct = default)
    {
        var list = new List<DatasetHealthRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_DatasetHealthStatus;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DatasetHealthRow
            {
                DataSourceId = reader.GetGuid("DataSourceId"),
                DataSourceName = reader.GetString("DataSourceName"),
                ConnectionHealth = reader.GetString("ConnectionHealth"),
                LatestQualityScore = reader.IsDBNull(reader.GetOrdinal("LatestQualityScore")) ? null : reader.GetDecimal("LatestQualityScore"),
                LatestGrade = reader.GetNullableString("LatestGrade"),
                LastAssessedUtc = reader.GetNullableDateTime("LastAssessedUtc"),
                LastProfiledUtc = reader.GetNullableDateTime("LastProfiledUtc"),
                LastProfileStatus = reader.GetNullableString("LastProfileStatus"),
                DatasetHealth = reader.GetString("DatasetHealth")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<SchemaChangeHistoryRow>> GetSchemaChangeHistoryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<SchemaChangeHistoryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_SchemaChangeHistory @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new SchemaChangeHistoryRow
            {
                SchemaChangeId = reader.GetGuid("SchemaChangeId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                DataSourceName = reader.GetString("DataSourceName"),
                ChangeType = reader.GetString("ChangeType"),
                SchemaName = reader.GetString("SchemaName"),
                ObjectName = reader.GetString("ObjectName"),
                ColumnName = reader.GetNullableString("ColumnName"),
                OldValue = reader.GetNullableString("OldValue"),
                NewValue = reader.GetNullableString("NewValue"),
                DetectedUtc = reader.GetDateTime("DetectedUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<MetadataSyncStatusRow>> GetMetadataSyncStatusAsync(CancellationToken ct = default)
    {
        var list = new List<MetadataSyncStatusRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_MetadataSyncStatus;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new MetadataSyncStatusRow
            {
                DataSourceId = reader.GetGuid("DataSourceId"),
                DataSourceName = reader.GetString("DataSourceName"),
                SyncLogId = reader.IsDBNull(reader.GetOrdinal("SyncLogId")) ? null : reader.GetGuid("SyncLogId"),
                LastSyncStatus = reader.GetNullableString("LastSyncStatus"),
                LastSyncUtc = reader.GetNullableDateTime("LastSyncUtc"),
                ObjectsAdded = reader.GetNullableInt32("ObjectsAdded"),
                ObjectsRemoved = reader.GetNullableInt32("ObjectsRemoved"),
                ColumnsChanged = reader.GetNullableInt32("ColumnsChanged"),
                SyncCount30d = reader.GetInt32("SyncCount30d")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<QualityTrendRow>> GetQualityTrendAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<QualityTrendRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_QualityTrendAnalysis @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new QualityTrendRow
            {
                DayUtc = reader.GetDateTime("DayUtc"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                DataSourceName = reader.GetString("DataSourceName"),
                AvgOverallScore = reader.GetDecimal("AvgOverallScore"),
                MinOverallScore = reader.GetDecimal("MinOverallScore"),
                MaxOverallScore = reader.GetDecimal("MaxOverallScore"),
                AssessmentCount = reader.GetInt32("AssessmentCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<ImportSummaryRow>> GetImportSummaryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<ImportSummaryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_ImportSummary @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ImportSummaryRow
            {
                DayUtc = reader.GetDateTime("DayUtc"),
                DatasetCode = reader.GetString("DatasetCode"),
                TotalBatches = reader.GetInt32("TotalBatches"),
                SuccessfulBatches = reader.GetInt32("SuccessfulBatches"),
                FailedBatches = reader.GetInt32("FailedBatches"),
                SuccessRatePct = reader.GetDecimal("SuccessRatePct"),
                TotalRecords = reader.GetInt32("TotalRecords"),
                ProcessedRecords = reader.GetInt32("ProcessedRecords"),
                RejectedRecords = reader.GetInt32("RejectedRecords")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<BatchProcessingHistoryRow>> GetBatchProcessingHistoryAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<BatchProcessingHistoryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_BatchProcessingHistory @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapBatchHistory(reader));
        return list;
    }

    public async Task<IReadOnlyList<ValidationErrorReportRow>> GetValidationErrorsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<ValidationErrorReportRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_ValidationErrors @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ValidationErrorReportRow
            {
                ErrorId = reader.GetInt64("ErrorId"),
                BatchId = reader.GetGuid("BatchId"),
                DatasetCode = reader.GetString("DatasetCode"),
                RowReference = reader.GetNullableString("RowReference"),
                ColumnName = reader.GetNullableString("ColumnName"),
                InvalidValue = reader.GetNullableString("InvalidValue"),
                ErrorCode = reader.GetString("ErrorCode"),
                ErrorDescription = reader.GetString("ErrorDescription"),
                Severity = reader.GetString("Severity"),
                ErrorUtc = reader.GetDateTime("ErrorUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DatasetProcessingStatisticsRow>> GetDatasetProcessingStatisticsAsync(CancellationToken ct = default)
    {
        var list = new List<DatasetProcessingStatisticsRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_DatasetProcessingStatistics;", conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DatasetProcessingStatisticsRow
            {
                DatasetId = reader.GetGuid("DatasetId"),
                DatasetCode = reader.GetString("DatasetCode"),
                DisplayName = reader.GetString("DisplayName"),
                BatchCount = reader.GetInt32("BatchCount"),
                TotalRecords = reader.GetInt32("TotalRecords"),
                ProcessedRecords = reader.GetInt32("ProcessedRecords"),
                RejectedRecords = reader.GetInt32("RejectedRecords"),
                InsertedRecords = reader.GetInt32("InsertedRecords"),
                UpdatedRecords = reader.GetInt32("UpdatedRecords"),
                ErrorCount = reader.GetInt32("ErrorCount"),
                AvgDurationSeconds = reader.GetNullableDouble("AvgDurationSeconds"),
                LastImportUtc = reader.GetNullableDateTime("LastImportUtc"),
                LastSuccessUtc = reader.GetNullableDateTime("LastSuccessUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<ImportErrorTrendRow>> GetImportErrorTrendsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<ImportErrorTrendRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_ImportErrorTrends @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ImportErrorTrendRow
            {
                DayUtc = reader.GetDateTime("DayUtc"),
                DatasetCode = reader.GetString("DatasetCode"),
                ErrorCode = reader.GetString("ErrorCode"),
                ErrorCount = reader.GetInt32("ErrorCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<BatchProcessingHistoryRow>> GetFailedImportsAsync(DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<BatchProcessingHistoryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC rpt.usp_FailedImports @FromUtc, @ToUtc;", conn);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapBatchHistory(reader));
        return list;
    }

    private static BatchProcessingHistoryRow MapBatchHistory(SqlDataReader reader) => new()
    {
        BatchId = reader.GetGuid("BatchId"),
        DatasetCode = reader.GetString("DatasetCode"),
        DatasetName = reader.GetString("DatasetName"),
        SourceInfo = reader.GetNullableString("SourceInfo"),
        Status = reader.GetString("Status"),
        TotalRecords = reader.GetInt32("TotalRecords"),
        ValidRecords = reader.IsDBNull(reader.GetOrdinal("ValidRecords")) ? 0 : reader.GetInt32("ValidRecords"),
        RejectedRecords = reader.GetInt32("RejectedRecords"),
        ProcessedRecords = reader.IsDBNull(reader.GetOrdinal("ProcessedRecords")) ? 0 : reader.GetInt32("ProcessedRecords"),
        InsertedRecords = reader.IsDBNull(reader.GetOrdinal("InsertedRecords")) ? 0 : reader.GetInt32("InsertedRecords"),
        UpdatedRecords = reader.IsDBNull(reader.GetOrdinal("UpdatedRecords")) ? 0 : reader.GetInt32("UpdatedRecords"),
        ErrorCount = reader.GetInt32("ErrorCount"),
        AttemptCount = reader.IsDBNull(reader.GetOrdinal("AttemptCount")) ? 0 : reader.GetInt32("AttemptCount"),
        ImportUtc = reader.GetDateTime("ImportUtc"),
        StartedUtc = reader.GetNullableDateTime("StartedUtc"),
        CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
        DurationSeconds = reader.GetNullableDouble("DurationSeconds"),
        LastErrorMessage = reader.GetNullableString("LastErrorMessage")
    };
}
