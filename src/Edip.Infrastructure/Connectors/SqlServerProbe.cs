using System.Diagnostics;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Connectors;

public sealed class SqlServerProbe : IConnectionProbe
{
    public string SupportedTypeCode => "SqlServer";

    public async Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new SqlConnection(BuildConnectionString(source, plaintextPassword));
            await conn.OpenAsync(ct);
            await using var cmd = new SqlCommand("SELECT 1;", conn);
            await cmd.ExecuteScalarAsync(ct);
            sw.Stop();
            return new ProbeResult { IsSuccess = true, Message = "SQL Server connection successful.", LatencyMs = (int)sw.ElapsedMilliseconds };
        }
        catch (Exception ex)
        {
            sw.Stop();
            return new ProbeResult { IsSuccess = false, Message = ex.Message, LatencyMs = (int)sw.ElapsedMilliseconds };
        }
    }

    public async Task<CapturedMetadataSnapshot> CaptureMetadataAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        var snapshot = new CapturedMetadataSnapshot();
        await using var conn = new SqlConnection(BuildConnectionString(source, plaintextPassword));
        await conn.OpenAsync(ct);

        var objects = new Dictionary<(string Schema, string Name), Guid>();

        const string objectSql = """
            SELECT s.name AS SchemaName, t.name AS ObjectName, 'Table' AS ObjectType
            FROM sys.tables t
            INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
            UNION ALL
            SELECT s.name, v.name, 'View'
            FROM sys.views v
            INNER JOIN sys.schemas s ON s.schema_id = v.schema_id
            ORDER BY SchemaName, ObjectName;
            """;

        await using (var cmd = new SqlCommand(objectSql, conn))
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var id = Guid.NewGuid();
                var schema = reader.GetString(0);
                var name = reader.GetString(1);
                var type = Enum.Parse<SchemaObjectType>(reader.GetString(2));
                objects[(schema, name)] = id;
                snapshot.Objects.Add(new SchemaObject
                {
                    SchemaObjectId = id,
                    DataSourceId = source.DataSourceId,
                    SchemaName = schema,
                    ObjectName = name,
                    ObjectType = type
                });
            }
        }

        const string columnSql = """
            SELECT s.name AS SchemaName, o.name AS ObjectName, c.name AS ColumnName, ty.name AS DataType,
                   c.max_length, c.precision, c.scale, c.is_nullable, c.column_id,
                   CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END AS IsPrimaryKey,
                   CASE WHEN fk.parent_column_id IS NULL THEN 0 ELSE 1 END AS IsForeignKey
            FROM sys.columns c
            INNER JOIN sys.objects o ON o.object_id = c.object_id AND o.type IN ('U','V')
            INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
            INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
            LEFT JOIN (
                SELECT ic.object_id, ic.column_id
                FROM sys.index_columns ic
                INNER JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 1
            ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
            LEFT JOIN (
                SELECT fkc.parent_object_id, fkc.parent_column_id
                FROM sys.foreign_key_columns fkc
            ) fk ON fk.parent_object_id = c.object_id AND fk.parent_column_id = c.column_id;
            """;

        await using (var cmd = new SqlCommand(columnSql, conn))
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var schema = reader.GetString(0);
                var name = reader.GetString(1);
                if (!objects.TryGetValue((schema, name), out var objectId))
                    continue;

                snapshot.Columns.Add(new ColumnDefinition
                {
                    ColumnDefinitionId = Guid.NewGuid(),
                    SchemaObjectId = objectId,
                    ColumnName = reader.GetString(2),
                    DataType = reader.GetString(3),
                    MaxLength = reader.IsDBNull(4) ? null : Convert.ToInt32(reader.GetValue(4)),
                    NumericPrecision = reader.IsDBNull(5) ? null : Convert.ToByte(reader.GetValue(5)),
                    NumericScale = reader.IsDBNull(6) ? null : Convert.ToInt32(reader.GetValue(6)),
                    IsNullable = reader.GetBoolean(7),
                    OrdinalPosition = reader.GetInt32(8),
                    IsPrimaryKey = Convert.ToBoolean(reader.GetValue(9)),
                    IsForeignKey = Convert.ToBoolean(reader.GetValue(10))
                });
            }
        }

        const string relSql = """
            SELECT fk.name AS ConstraintName,
                   ps.name AS ParentSchema, pt.name AS ParentTable, pc.name AS ParentColumn,
                   cs.name AS ChildSchema, ct.name AS ChildTable, cc.name AS ChildColumn
            FROM sys.foreign_keys fk
            INNER JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
            INNER JOIN sys.tables pt ON pt.object_id = fk.referenced_object_id
            INNER JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
            INNER JOIN sys.columns pc ON pc.object_id = pt.object_id AND pc.column_id = fkc.referenced_column_id
            INNER JOIN sys.tables ct ON ct.object_id = fk.parent_object_id
            INNER JOIN sys.schemas cs ON cs.schema_id = ct.schema_id
            INNER JOIN sys.columns cc ON cc.object_id = ct.object_id AND cc.column_id = fkc.parent_column_id;
            """;

        await using (var cmd = new SqlCommand(relSql, conn))
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var parentKey = (reader.GetString(1), reader.GetString(2));
                var childKey = (reader.GetString(4), reader.GetString(5));
                if (!objects.TryGetValue(parentKey, out var parentId) || !objects.TryGetValue(childKey, out var childId))
                    continue;

                snapshot.Relationships.Add(new ObjectRelationship
                {
                    RelationshipId = Guid.NewGuid(),
                    DataSourceId = source.DataSourceId,
                    ParentObjectId = parentId,
                    ChildObjectId = childId,
                    ParentColumnName = reader.GetString(3),
                    ChildColumnName = reader.GetString(6),
                    ConstraintName = reader.GetString(0)
                });
            }
        }

        return snapshot;
    }

    internal static string BuildConnectionString(DataSource source, string? plaintextPassword)
    {
        var d = source.SqlConnection ?? throw new InvalidOperationException("SQL connection details are missing.");
        var builder = new SqlConnectionStringBuilder
        {
            DataSource = d.Port > 0 ? $"{d.Host},{d.Port}" : d.Host,
            InitialCatalog = d.DatabaseName,
            TrustServerCertificate = d.TrustServerCertificate,
            ConnectTimeout = d.ConnectionTimeoutSeconds
        };

        if (d.AuthMode is "Windows" or "Integrated")
        {
            builder.IntegratedSecurity = true;
        }
        else
        {
            builder.UserID = d.Username;
            builder.Password = plaintextPassword ?? string.Empty;
        }

        return builder.ConnectionString;
    }
}
