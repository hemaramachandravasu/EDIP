using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class DatasetProfileRepository(ISqlConnectionFactory connectionFactory) : IDatasetProfileRepository
{
    public async Task<ProfileRunDto> ProfileAsync(
        string datasetCode, string profileScope, string triggerType, Guid? importId, Guid? batchId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_ProfileCustomerDataset", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 300
        };
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@ProfileScope", profileScope);
        cmd.Parameters.AddWithValue("@TriggerType", triggerType);
        cmd.Parameters.AddNullable("@ImportId", importId);
        cmd.Parameters.AddNullable("@BatchId", batchId);
        var runParam = new SqlParameter("@ProfileRunId", SqlDbType.UniqueIdentifier)
        {
            Direction = ParameterDirection.InputOutput,
            Value = DBNull.Value
        };
        cmd.Parameters.Add(runParam);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        Guid runId;
        if (await reader.ReadAsync(ct))
            runId = reader.GetGuid("ProfileRunId");
        else if (runParam.Value is Guid id)
            runId = id;
        else
            throw new InvalidOperationException("Profiling failed to return a run.");

        await reader.CloseAsync();
        return (await GetRunAsync(runId, ct))!;
    }

    public async Task<ProfileRunDto?> GetRunAsync(Guid profileRunId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_GetProfileRun", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@ProfileRunId", profileRunId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        return MapRun(reader, includeNames: true);
    }

    public async Task<ProfileRunDto?> GetLatestScoreAsync(string datasetCode, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_GetLatestDatasetScore", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        return MapRun(reader, includeNames: true);
    }

    public async Task<IReadOnlyList<DatasetColumnProfileDto>> GetColumnProfilesAsync(Guid profileRunId, CancellationToken ct = default)
    {
        var list = new List<DatasetColumnProfileDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_GetColumnProfiles", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@ProfileRunId", profileRunId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DatasetColumnProfileDto
            {
                ColumnProfileId = reader.GetGuid("ColumnProfileId"),
                ProfileRunId = reader.GetGuid("ProfileRunId"),
                ColumnName = reader.GetString("ColumnName"),
                DataCategory = reader.GetString("DataCategory"),
                TotalRecords = reader.GetInt64("TotalRecords"),
                NonNullRecords = reader.GetInt64("NonNullRecords"),
                NullRecords = reader.GetInt64("NullRecords"),
                NullPct = reader.GetDecimal("NullPct"),
                CompletenessPct = reader.GetDecimal("CompletenessPct"),
                DistinctCount = reader.GetInt64("DistinctCount"),
                DuplicateValueCount = reader.GetInt64("DuplicateValueCount"),
                UniquePct = reader.GetDecimal("UniquePct"),
                DuplicatePct = reader.GetDecimal("DuplicatePct"),
                MinValue = reader.GetNullableString("MinValue"),
                MaxValue = reader.GetNullableString("MaxValue"),
                AvgValue = reader.GetNullableDecimal("AvgValue"),
                MedianValue = reader.GetNullableDecimal("MedianValue"),
                StdDevValue = reader.GetNullableDecimal("StdDevValue"),
                MinLength = reader.GetNullableInt32("MinLength"),
                MaxLength = reader.GetNullableInt32("MaxLength"),
                AvgLength = reader.GetNullableDecimal("AvgLength"),
                MinDate = reader.GetNullableDateTime("MinDate"),
                MaxDate = reader.GetNullableDateTime("MaxDate"),
                DistinctDateCount = reader.GetNullableInt64("DistinctDateCount"),
                InvalidCount = reader.GetInt64("InvalidCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DatasetQualityIssueDto>> GetIssuesAsync(Guid profileRunId, CancellationToken ct = default)
    {
        var list = new List<DatasetQualityIssueDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_GetQualityIssues", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@ProfileRunId", profileRunId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DatasetQualityIssueDto
            {
                QualityIssueId = reader.GetInt64("QualityIssueId"),
                ProfileRunId = reader.GetGuid("ProfileRunId"),
                DatasetId = reader.GetGuid("DatasetId"),
                ImportId = reader.IsDBNull(reader.GetOrdinal("ImportId")) ? null : reader.GetGuid("ImportId"),
                IssueType = reader.GetString("IssueType"),
                ColumnName = reader.GetNullableString("ColumnName"),
                ErrorCode = reader.GetNullableString("ErrorCode"),
                AffectedCount = reader.GetInt64("AffectedCount"),
                SampleValue = reader.GetNullableString("SampleValue"),
                Description = reader.GetString("Description"),
                Severity = reader.GetString("Severity")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DatasetThresholdResultDto>> GetThresholdResultsAsync(Guid profileRunId, CancellationToken ct = default)
    {
        var list = new List<DatasetThresholdResultDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_GetThresholdResults", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@ProfileRunId", profileRunId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new DatasetThresholdResultDto
            {
                ThresholdResultId = reader.GetInt64("ThresholdResultId"),
                ProfileRunId = reader.GetGuid("ProfileRunId"),
                ThresholdId = reader.GetInt32("ThresholdId"),
                MetricCode = reader.GetString("MetricCode"),
                ActualValue = reader.GetDecimal("ActualValue"),
                ThresholdValue = reader.GetDecimal("ThresholdValue"),
                OperatorCode = reader.GetString("OperatorCode"),
                Passed = reader.GetBoolean("Passed")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<DatasetQualityTrendRow>> GetTrendAsync(
        string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<DatasetQualityTrendRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_GetQualityTrend", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapTrend(reader));
        return list;
    }

    public async Task<int> ProfileDueDatasetsAsync(int maxDatasets, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_ProfileDueDatasets", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 600
        };
        cmd.Parameters.AddWithValue("@MaxDatasets", maxDatasets);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct))
            return reader.GetInt32("DatasetsProfiled");
        return 0;
    }

    public async Task ArchiveHistoryAsync(int retainDays, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("profile.usp_ArchiveProfileHistory", conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue("@RetainDays", retainDays);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static ProfileRunDto MapRun(SqlDataReader reader, bool includeNames) => new()
    {
        ProfileRunId = reader.GetGuid("ProfileRunId"),
        DatasetId = reader.GetGuid("DatasetId"),
        DatasetCode = includeNames ? reader.GetString("DatasetCode") : string.Empty,
        DatasetName = includeNames ? reader.GetString("DatasetName") : string.Empty,
        ImportId = reader.IsDBNull(reader.GetOrdinal("ImportId")) ? null : reader.GetGuid("ImportId"),
        BatchId = reader.IsDBNull(reader.GetOrdinal("BatchId")) ? null : reader.GetGuid("BatchId"),
        ProfileScope = reader.GetString("ProfileScope"),
        TriggerType = reader.GetString("TriggerType"),
        Status = reader.GetString("Status"),
        StartedUtc = reader.GetDateTime("StartedUtc"),
        CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
        DurationMs = reader.GetNullableInt32("DurationMs"),
        TotalRecords = reader.GetInt64("TotalRecords"),
        ValidRecords = reader.GetInt64("ValidRecords"),
        InvalidRecords = reader.GetInt64("InvalidRecords"),
        DuplicateRecords = reader.GetInt64("DuplicateRecords"),
        NullCellCount = reader.GetInt64("NullCellCount"),
        CompletenessPct = reader.GetDecimal("CompletenessPct"),
        UniquenessPct = reader.GetDecimal("UniquenessPct"),
        ValidityPct = reader.GetDecimal("ValidityPct"),
        ConsistencyPct = reader.GetDecimal("ConsistencyPct"),
        DuplicatePct = reader.GetDecimal("DuplicatePct"),
        ErrorPct = reader.GetDecimal("ErrorPct"),
        OverallScore = reader.GetDecimal("OverallScore"),
        Grade = reader.GetString("Grade"),
        ThresholdResult = reader.GetString("ThresholdResult"),
        ColumnsProfiled = reader.GetInt32("ColumnsProfiled"),
        IssueCount = reader.GetInt32("IssueCount"),
        ErrorMessage = reader.GetNullableString("ErrorMessage")
    };

    internal static DatasetQualityTrendRow MapTrend(SqlDataReader reader) => new()
    {
        ProfileRunId = reader.GetGuid("ProfileRunId"),
        DatasetCode = reader.GetString("DatasetCode"),
        StartedUtc = reader.GetDateTime("StartedUtc"),
        OverallScore = reader.GetDecimal("OverallScore"),
        CompletenessPct = reader.GetDecimal("CompletenessPct"),
        ValidityPct = reader.GetDecimal("ValidityPct"),
        UniquenessPct = reader.GetDecimal("UniquenessPct"),
        ConsistencyPct = reader.GetDecimal("ConsistencyPct"),
        DuplicatePct = reader.GetDecimal("DuplicatePct"),
        ThresholdResult = reader.GetString("ThresholdResult"),
        Grade = reader.GetString("Grade"),
        PrevOverallScore = reader.GetNullableDecimal("PrevOverallScore"),
        PrevCompletenessPct = reader.GetNullableDecimal("PrevCompletenessPct"),
        PrevValidityPct = reader.GetNullableDecimal("PrevValidityPct"),
        PrevDuplicatePct = reader.GetNullableDecimal("PrevDuplicatePct"),
        DeltaOverallScore = reader.GetNullableDecimal("DeltaOverallScore"),
        DeltaCompletenessPct = reader.GetNullableDecimal("DeltaCompletenessPct"),
        DeltaValidityPct = reader.GetNullableDecimal("DeltaValidityPct"),
        DeltaDuplicatePct = reader.GetNullableDecimal("DeltaDuplicatePct")
    };
}
