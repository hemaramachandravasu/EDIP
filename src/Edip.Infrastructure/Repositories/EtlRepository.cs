using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class EtlRepository(ISqlConnectionFactory connectionFactory) : IEtlRepository
{
    public async Task RunPipelineAsync(Guid batchId, string triggerType, bool forceFail, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_RunPipeline", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        cmd.Parameters.AddWithValue("@TriggerType", triggerType);
        cmd.Parameters.AddWithValue("@ForceFail", forceFail);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task RetryBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_RetryFailedBatch", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IReadOnlyList<EtlErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        var list = new List<EtlErrorDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_GetErrorsByBatch", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapError(reader));
        return list;
    }

    public async Task<IReadOnlyList<EtlErrorDto>> GetErrorsByDatasetAsync(
        string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<EtlErrorDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_GetErrorsByDataset", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapError(reader));
        return list;
    }

    public async Task<int> ProcessPendingAsync(int maxBatches, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_ProcessPendingBatches", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 300
        };
        cmd.Parameters.AddWithValue("@MaxBatches", maxBatches);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct))
            return reader.GetInt32("BatchesProcessed");
        return 0;
    }

    public async Task ArchiveErrorsAsync(int retainDays, CancellationToken ct = default)
    {
        await ExecProc("etl.usp_ArchiveErrors", "@RetainDays", retainDays, ct);
    }

    public async Task CleanupBatchesAsync(int retainDays, CancellationToken ct = default)
    {
        await ExecProc("etl.usp_CleanupBatches", "@RetainDays", retainDays, ct);
    }

    public async Task GenerateQualitySnapshotAsync(CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_GenerateQualitySnapshot", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<Guid> GenerateTestBatchAsync(int rowCount, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("etl.usp_GenerateTestBatch", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180
        };
        cmd.Parameters.AddWithValue("@RowCount", rowCount);
        var batchParam = new SqlParameter("@BatchId", SqlDbType.UniqueIdentifier)
        {
            Direction = ParameterDirection.InputOutput,
            Value = DBNull.Value
        };
        cmd.Parameters.Add(batchParam);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (await reader.ReadAsync(ct))
            return reader.GetGuid("BatchId");
        if (batchParam.Value is Guid id)
            return id;
        throw new InvalidOperationException("Failed to generate ETL test batch.");
    }

    private async Task ExecProc(string proc, string paramName, int value, CancellationToken ct)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(proc, conn) { CommandType = CommandType.StoredProcedure };
        cmd.Parameters.AddWithValue(paramName, value);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static EtlErrorDto MapError(SqlDataReader reader) => new()
    {
        ErrorId = reader.GetInt64("ErrorId"),
        RunId = reader.IsDBNull(reader.GetOrdinal("RunId")) ? null : reader.GetGuid("RunId"),
        BatchId = reader.GetGuid("BatchId"),
        ImportId = reader.IsDBNull(reader.GetOrdinal("ImportId")) ? null : reader.GetGuid("ImportId"),
        RowNumber = reader.GetNullableInt32("RowNumber"),
        ColumnName = reader.GetNullableString("ColumnName"),
        InvalidValue = reader.GetNullableString("InvalidValue"),
        ErrorCode = reader.GetString("ErrorCode"),
        ErrorDescription = reader.GetString("ErrorDescription"),
        Phase = reader.GetString("Phase"),
        Severity = reader.GetString("Severity"),
        ErrorUtc = reader.GetDateTime("ErrorUtc")
    };
}
