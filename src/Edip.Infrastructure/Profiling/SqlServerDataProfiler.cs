using System.Text;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Edip.Infrastructure.Connectors;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Profiling;

public sealed class SqlServerDataProfiler(
    IMetadataRepository metadataRepository,
    IQualityRepository qualityRepository) : IDataProfiler
{
    private const int MaxTables = 40;
    private const int MaxColumnsPerTable = 30;

    public async Task<ProfilingRun> ProfileAsync(DataSource source, string? plaintextPassword, string triggerType, CancellationToken ct = default)
    {
        if (!string.Equals(source.DataSourceTypeCode, "SqlServer", StringComparison.OrdinalIgnoreCase))
            throw new NotSupportedException($"Live profiling currently supports SqlServer sources. Type '{source.DataSourceTypeCode}' is not supported yet.");

        var run = new ProfilingRun
        {
            DataSourceId = source.DataSourceId,
            TriggerType = triggerType,
            Status = "Running",
            StartedUtc = DateTime.UtcNow
        };
        run.ProfilingRunId = await qualityRepository.CreateProfilingRunAsync(run, ct);

        try
        {
            var objects = (await metadataRepository.GetObjectsAsync(source.DataSourceId, ct))
                .Where(o => o.ObjectType == Core.Enums.SchemaObjectType.Table)
                .Take(MaxTables)
                .ToList();

            if (objects.Count == 0)
            {
                // Fall back: profile a few user tables discovered live
                objects = await DiscoverTablesAsync(source, plaintextPassword, ct);
            }

            var cs = SqlServerProbe.BuildConnectionString(source, plaintextPassword);
            await using var conn = new SqlConnection(cs);
            await conn.OpenAsync(ct);

            var tables = new List<TableProfile>();
            var columnTotal = 0;

            foreach (var obj in objects)
            {
                var columns = (await metadataRepository.GetColumnsAsync(obj.SchemaObjectId, source.DataSourceId, ct))
                    .OrderBy(c => c.OrdinalPosition)
                    .Take(MaxColumnsPerTable)
                    .ToList();

                if (columns.Count == 0)
                    columns = await DiscoverColumnsAsync(conn, obj.SchemaName, obj.ObjectName, ct);

                var tableProfile = await ProfileTableAsync(conn, obj.SchemaName, obj.ObjectName, columns, ct);
                tables.Add(tableProfile);
                columnTotal += tableProfile.Columns.Count;
            }

            await qualityRepository.SaveTableProfilesAsync(run.ProfilingRunId, tables, ct);
            await qualityRepository.CompleteProfilingRunAsync(run.ProfilingRunId, "Succeeded", tables.Count, columnTotal, null, ct);

            run.Status = "Succeeded";
            run.CompletedUtc = DateTime.UtcNow;
            run.TablesProfiled = tables.Count;
            run.ColumnsProfiled = columnTotal;
            run.Tables = tables;
            return run;
        }
        catch (Exception ex)
        {
            await qualityRepository.CompleteProfilingRunAsync(run.ProfilingRunId, "Failed", 0, 0, ex.Message, ct);
            run.Status = "Failed";
            run.ErrorMessage = ex.Message;
            run.CompletedUtc = DateTime.UtcNow;
            throw;
        }
    }

    private static async Task<TableProfile> ProfileTableAsync(
        SqlConnection conn, string schema, string table, IReadOnlyList<ColumnDefinition> columns, CancellationToken ct)
    {
        var fullName = $"[{Escape(schema)}].[{Escape(table)}]";
        long rowCount = 0;
        await using (var cmd = new SqlCommand($"SELECT COUNT_BIG(*) FROM {fullName};", conn))
        {
            cmd.CommandTimeout = 120;
            rowCount = Convert.ToInt64(await cmd.ExecuteScalarAsync(ct));
        }

        long dupes = 0;
        if (rowCount > 0 && rowCount <= 500_000 && columns.Count > 0)
        {
            var colList = string.Join(", ", columns.Select(c => $"[{Escape(c.ColumnName)}]"));
            await using var cmd = new SqlCommand($"""
                SELECT ISNULL(SUM(cnt - 1), 0)
                FROM (
                    SELECT COUNT_BIG(*) AS cnt
                    FROM {fullName}
                    GROUP BY {colList}
                    HAVING COUNT_BIG(*) > 1
                ) d;
                """, conn);
            cmd.CommandTimeout = 180;
            try { dupes = Convert.ToInt64(await cmd.ExecuteScalarAsync(ct) ?? 0L); }
            catch { /* skip duplicate scan on exotic types */ }
        }

        DateTime? lastChange = null;
        try
        {
            await using var cmd = new SqlCommand("""
                SELECT MAX(modify_date) FROM sys.tables t
                INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
                WHERE s.name = @Schema AND t.name = @Table;
                """, conn);
            cmd.Parameters.AddWithValue("@Schema", schema);
            cmd.Parameters.AddWithValue("@Table", table);
            var val = await cmd.ExecuteScalarAsync(ct);
            if (val is DateTime dt) lastChange = DateTime.SpecifyKind(dt, DateTimeKind.Utc);
        }
        catch { /* ignore */ }

        var profile = new TableProfile
        {
            TableProfileId = Guid.NewGuid(),
            SchemaName = schema,
            ObjectName = table,
            ObjectType = "Table",
            RowCountValue = rowCount,
            DuplicateRowCount = dupes,
            IsEmpty = rowCount == 0,
            LastDataChangeUtc = lastChange
        };

        foreach (var col in columns)
        {
            profile.Columns.Add(await ProfileColumnAsync(conn, fullName, col, rowCount, ct));
        }

        return profile;
    }

    private static async Task<ColumnProfile> ProfileColumnAsync(
        SqlConnection conn, string fullName, ColumnDefinition col, long rowCount, CancellationToken ct)
    {
        var colName = $"[{Escape(col.ColumnName)}]";
        long nullCount = 0;
        long distinct = 0;
        string? min = null;
        string? max = null;
        long invalid = 0;

        try
        {
            await using var cmd = new SqlCommand($"""
                SELECT
                    SUM(CASE WHEN {colName} IS NULL THEN 1 ELSE 0 END) AS NullCount,
                    COUNT(DISTINCT {colName}) AS DistinctCount
                FROM {fullName};
                """, conn);
            cmd.CommandTimeout = 120;
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (await reader.ReadAsync(ct))
            {
                nullCount = reader.IsDBNull(0) ? 0 : Convert.ToInt64(reader.GetValue(0));
                distinct = reader.IsDBNull(1) ? 0 : Convert.ToInt64(reader.GetValue(1));
            }
        }
        catch { /* skip */ }

        if (IsComparable(col.DataType))
        {
            try
            {
                await using var cmd = new SqlCommand($"""
                    SELECT CONVERT(NVARCHAR(500), MIN({colName})), CONVERT(NVARCHAR(500), MAX({colName}))
                    FROM {fullName} WHERE {colName} IS NOT NULL;
                    """, conn);
                cmd.CommandTimeout = 120;
                await using var reader = await cmd.ExecuteReaderAsync(ct);
                if (await reader.ReadAsync(ct))
                {
                    min = reader.IsDBNull(0) ? null : reader.GetString(0);
                    max = reader.IsDBNull(1) ? null : reader.GetString(1);
                }
            }
            catch { /* skip min/max */ }
        }

        // Invalid type heuristic: for numeric-looking columns stored as string-ish types with non-numeric values
        if (col.DataType.Contains("char", StringComparison.OrdinalIgnoreCase) &&
            col.ColumnName.Contains("id", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                await using var cmd = new SqlCommand($"""
                    SELECT COUNT_BIG(*) FROM {fullName}
                    WHERE {colName} IS NOT NULL AND TRY_CONVERT(FLOAT, {colName}) IS NULL
                      AND TRY_CONVERT(UNIQUEIDENTIFIER, {colName}) IS NULL;
                    """, conn);
                invalid = Convert.ToInt64(await cmd.ExecuteScalarAsync(ct) ?? 0L);
            }
            catch { invalid = 0; }
        }

        var nullPct = rowCount == 0 ? 0m : Math.Round(100m * nullCount / rowCount, 4);
        return new ColumnProfile
        {
            ColumnProfileId = Guid.NewGuid(),
            ColumnName = col.ColumnName,
            DataType = col.DataType,
            NullCount = nullCount,
            NullPct = nullPct,
            DistinctCount = distinct,
            MinValue = min,
            MaxValue = max,
            SampleInvalidCount = invalid
        };
    }

    private static async Task<List<SchemaObject>> DiscoverTablesAsync(DataSource source, string? password, CancellationToken ct)
    {
        var list = new List<SchemaObject>();
        var cs = SqlServerProbe.BuildConnectionString(source, password);
        await using var conn = new SqlConnection(cs);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT TOP (40) s.name, t.name
            FROM sys.tables t
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
            ORDER BY s.name, t.name;
            """, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new SchemaObject
            {
                SchemaObjectId = Guid.NewGuid(),
                DataSourceId = source.DataSourceId,
                SchemaName = reader.GetString(0),
                ObjectName = reader.GetString(1),
                ObjectType = Core.Enums.SchemaObjectType.Table
            });
        }
        return list;
    }

    private static async Task<List<ColumnDefinition>> DiscoverColumnsAsync(SqlConnection conn, string schema, string table, CancellationToken ct)
    {
        var list = new List<ColumnDefinition>();
        await using var cmd = new SqlCommand("""
            SELECT c.name, ty.name, c.column_id, c.is_nullable
            FROM sys.columns c
            INNER JOIN sys.tables t ON t.object_id = c.object_id
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
            WHERE s.name = @Schema AND t.name = @Table
            ORDER BY c.column_id;
            """, conn);
        cmd.Parameters.AddWithValue("@Schema", schema);
        cmd.Parameters.AddWithValue("@Table", table);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ColumnDefinition
            {
                ColumnName = reader.GetString(0),
                DataType = reader.GetString(1),
                OrdinalPosition = reader.GetInt32(2),
                IsNullable = reader.GetBoolean(3)
            });
        }
        return list;
    }

    private static bool IsComparable(string dataType)
    {
        var t = dataType.ToLowerInvariant();
        return t is "int" or "bigint" or "smallint" or "tinyint" or "decimal" or "numeric" or "float" or "real"
            or "money" or "smallmoney" or "date" or "datetime" or "datetime2" or "smalldatetime"
            or "char" or "varchar" or "nchar" or "nvarchar";
    }

    private static string Escape(string name) => name.Replace("]", "]]", StringComparison.Ordinal);
}
