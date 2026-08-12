using System.Data;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class IngestionRepository(ISqlConnectionFactory connectionFactory) : IIngestionRepository
{
    public async Task<IReadOnlyList<IngestDataset>> GetDatasetsAsync(CancellationToken ct = default)
    {
        var list = new List<IngestDataset>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable, IsActive
            FROM ingest.Dataset
            ORDER BY DatasetCode;
            """, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new IngestDataset
            {
                DatasetId = reader.GetGuid("DatasetId"),
                DatasetCode = reader.GetString("DatasetCode"),
                DisplayName = reader.GetString("DisplayName"),
                Description = reader.GetNullableString("Description"),
                StagingTable = reader.GetString("StagingTable"),
                TargetTable = reader.GetString("TargetTable"),
                IsActive = reader.GetBoolean("IsActive")
            });
        }
        return list;
    }

    public async Task<Guid?> GetDatasetIdByCodeAsync(string datasetCode, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(
            "SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = @Code AND IsActive = 1;", conn);
        cmd.Parameters.AddWithValue("@Code", datasetCode);
        var result = await cmd.ExecuteScalarAsync(ct);
        return result is Guid g ? g : null;
    }

    public async Task<Guid> CreateBatchAsync(string datasetCode, Guid? dataSourceId, string? sourceInfo, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_CreateImportBatch", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@DataSourceId", dataSourceId);
        cmd.Parameters.AddNullable("@SourceInfo", sourceInfo);
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

        throw new InvalidOperationException("Failed to create import batch.");
    }

    public async Task LoadStagingCustomersAsync(
        Guid batchId,
        Guid datasetId,
        IReadOnlyList<StagingCustomerRow> rows,
        string? sourceInfo,
        CancellationToken ct = default)
    {
        if (rows.Count == 0)
            return;

        var table = new DataTable();
        table.Columns.Add("BatchId", typeof(Guid));
        table.Columns.Add("DatasetId", typeof(Guid));
        table.Columns.Add("RowNumber", typeof(int));
        table.Columns.Add("RawCustomerCode", typeof(string));
        table.Columns.Add("RawCustomerName", typeof(string));
        table.Columns.Add("RawCountryCode", typeof(string));
        table.Columns.Add("RawEmail", typeof(string));
        table.Columns.Add("RawCreditLimit", typeof(string));
        table.Columns.Add("RawStatus", typeof(string));
        table.Columns.Add("RawCreatedDate", typeof(string));
        table.Columns.Add("SourceInfo", typeof(string));

        var rowNum = 1;
        foreach (var row in rows)
        {
            table.Rows.Add(
                batchId,
                datasetId,
                row.RowNumber > 0 ? row.RowNumber : rowNum++,
                (object?)row.CustomerCode ?? DBNull.Value,
                (object?)row.CustomerName ?? DBNull.Value,
                (object?)row.CountryCode ?? DBNull.Value,
                (object?)row.Email ?? DBNull.Value,
                (object?)row.CreditLimit ?? DBNull.Value,
                (object?)row.Status ?? DBNull.Value,
                (object?)row.CreatedDate ?? DBNull.Value,
                (object?)sourceInfo ?? DBNull.Value);
        }

        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        using var bulk = new SqlBulkCopy(conn)
        {
            DestinationTableName = "ingest.StagingCustomer",
            BatchSize = 1000
        };
        bulk.ColumnMappings.Add("BatchId", "BatchId");
        bulk.ColumnMappings.Add("DatasetId", "DatasetId");
        bulk.ColumnMappings.Add("RowNumber", "RowNumber");
        bulk.ColumnMappings.Add("RawCustomerCode", "RawCustomerCode");
        bulk.ColumnMappings.Add("RawCustomerName", "RawCustomerName");
        bulk.ColumnMappings.Add("RawCountryCode", "RawCountryCode");
        bulk.ColumnMappings.Add("RawEmail", "RawEmail");
        bulk.ColumnMappings.Add("RawCreditLimit", "RawCreditLimit");
        bulk.ColumnMappings.Add("RawStatus", "RawStatus");
        bulk.ColumnMappings.Add("RawCreatedDate", "RawCreatedDate");
        bulk.ColumnMappings.Add("SourceInfo", "SourceInfo");
        await bulk.WriteToServerAsync(table, ct);
    }

    public async Task CompleteStagingLoadAsync(Guid batchId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_CompleteStagingLoad", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<ImportBatch?> GetBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_GetBatchStatus", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null;

        return MapBatch(reader);
    }

    public async Task ValidateBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_ValidateCustomerBatch", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 120
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task ProcessBatchAsync(Guid batchId, string triggerType, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_ProcessCustomerBatch", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        cmd.Parameters.AddWithValue("@TriggerType", triggerType);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task RetryBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_RetryFailedBatch", conn)
        {
            CommandType = CommandType.StoredProcedure,
            CommandTimeout = 180
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IReadOnlyList<ImportError>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        var list = new List<ImportError>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_GetErrorsByBatch", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@BatchId", batchId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapError(reader));
        return list;
    }

    public async Task<IReadOnlyList<ImportError>> GetErrorsByDatasetAsync(
        string datasetCode, DateTime fromUtc, DateTime toUtc, CancellationToken ct = default)
    {
        var list = new List<ImportError>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_GetErrorsByDataset", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@FromUtc", fromUtc);
        cmd.Parameters.AddWithValue("@ToUtc", toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapError(reader, includeDatasetCode: true));
        return list;
    }

    public async Task<int> ProcessPendingBatchesAsync(int maxBatches, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_ProcessPendingBatches", conn)
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

    public async Task ArchiveImportHistoryAsync(int retainDays, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("ingest.usp_ArchiveImportHistory", conn)
        {
            CommandType = CommandType.StoredProcedure
        };
        cmd.Parameters.AddWithValue("@RetainDays", retainDays);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static ImportBatch MapBatch(SqlDataReader reader) => new()
    {
        BatchId = reader.GetGuid("BatchId"),
        DatasetCode = reader.GetString("DatasetCode"),
        DatasetName = reader.GetString("DatasetName"),
        DataSourceId = reader.IsDBNull(reader.GetOrdinal("DataSourceId")) ? null : reader.GetGuid("DataSourceId"),
        SourceInfo = reader.GetNullableString("SourceInfo"),
        ImportUtc = reader.GetDateTime("ImportUtc"),
        Status = reader.GetString("Status"),
        TotalRecords = reader.GetInt32("TotalRecords"),
        ValidRecords = reader.GetInt32("ValidRecords"),
        RejectedRecords = reader.GetInt32("RejectedRecords"),
        ProcessedRecords = reader.GetInt32("ProcessedRecords"),
        InsertedRecords = reader.GetInt32("InsertedRecords"),
        UpdatedRecords = reader.GetInt32("UpdatedRecords"),
        ErrorCount = reader.GetInt32("ErrorCount"),
        AttemptCount = reader.GetInt32("AttemptCount"),
        StartedUtc = reader.GetNullableDateTime("StartedUtc"),
        CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
        DurationSeconds = reader.GetNullableDouble("DurationSeconds"),
        LastErrorMessage = reader.GetNullableString("LastErrorMessage")
    };

    private static ImportError MapError(SqlDataReader reader, bool includeDatasetCode = false) => new()
    {
        ErrorId = reader.GetInt64("ErrorId"),
        BatchId = reader.GetGuid("BatchId"),
        DatasetId = reader.GetGuid("DatasetId"),
        DatasetCode = includeDatasetCode ? reader.GetNullableString("DatasetCode") : null,
        StagingRowId = reader.IsDBNull(reader.GetOrdinal("StagingRowId")) ? null : reader.GetInt64("StagingRowId"),
        RowReference = reader.GetNullableString("RowReference"),
        ColumnName = reader.GetNullableString("ColumnName"),
        InvalidValue = reader.GetNullableString("InvalidValue"),
        ErrorCode = reader.GetString("ErrorCode"),
        ErrorDescription = reader.GetString("ErrorDescription"),
        Severity = reader.GetString("Severity"),
        ErrorUtc = reader.GetDateTime("ErrorUtc")
    };
}
