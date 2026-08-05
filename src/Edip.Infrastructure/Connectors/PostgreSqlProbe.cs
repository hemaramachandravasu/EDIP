using System.Diagnostics;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Npgsql;

namespace Edip.Infrastructure.Connectors;

public sealed class PostgreSqlProbe : IConnectionProbe
{
    public string SupportedTypeCode => "PostgreSql";

    public async Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new NpgsqlConnection(BuildConnectionString(source, plaintextPassword));
            await conn.OpenAsync(ct);
            await using var cmd = new NpgsqlCommand("SELECT 1;", conn);
            await cmd.ExecuteScalarAsync(ct);
            sw.Stop();
            return new ProbeResult { IsSuccess = true, Message = "PostgreSQL connection successful.", LatencyMs = (int)sw.ElapsedMilliseconds };
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
        await using var conn = new NpgsqlConnection(BuildConnectionString(source, plaintextPassword));
        await conn.OpenAsync(ct);

        var objects = new Dictionary<(string Schema, string Name), Guid>();

        await using (var cmd = new NpgsqlCommand("""
            SELECT table_schema, table_name, CASE WHEN table_type = 'VIEW' THEN 'View' ELSE 'Table' END
            FROM information_schema.tables
            WHERE table_schema NOT IN ('pg_catalog', 'information_schema');
            """, conn))
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var id = Guid.NewGuid();
                var schema = reader.GetString(0);
                var name = reader.GetString(1);
                objects[(schema, name)] = id;
                snapshot.Objects.Add(new SchemaObject
                {
                    SchemaObjectId = id,
                    DataSourceId = source.DataSourceId,
                    SchemaName = schema,
                    ObjectName = name,
                    ObjectType = Enum.Parse<SchemaObjectType>(reader.GetString(2))
                });
            }
        }

        await using (var cmd = new NpgsqlCommand("""
            SELECT c.table_schema, c.table_name, c.column_name, c.data_type, c.character_maximum_length,
                   c.numeric_precision, c.numeric_scale, c.is_nullable, c.ordinal_position,
                   CASE WHEN tc.constraint_type = 'PRIMARY KEY' THEN 1 ELSE 0 END AS is_pk,
                   CASE WHEN tc.constraint_type = 'FOREIGN KEY' THEN 1 ELSE 0 END AS is_fk
            FROM information_schema.columns c
            LEFT JOIN information_schema.key_column_usage kcu
                ON kcu.table_schema = c.table_schema AND kcu.table_name = c.table_name AND kcu.column_name = c.column_name
            LEFT JOIN information_schema.table_constraints tc
                ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE c.table_schema NOT IN ('pg_catalog', 'information_schema');
            """, conn))
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                var key = (reader.GetString(0), reader.GetString(1));
                if (!objects.TryGetValue(key, out var objectId))
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
                    IsNullable = string.Equals(reader.GetString(7), "YES", StringComparison.OrdinalIgnoreCase),
                    OrdinalPosition = reader.GetInt32(8),
                    IsPrimaryKey = Convert.ToInt32(reader.GetValue(9)) == 1,
                    IsForeignKey = Convert.ToInt32(reader.GetValue(10)) == 1
                });
            }
        }

        await using (var cmd = new NpgsqlCommand("""
            SELECT tc.constraint_name,
                   ccu.table_schema AS parent_schema, ccu.table_name AS parent_table, ccu.column_name AS parent_column,
                   tc.table_schema AS child_schema, tc.table_name AS child_table, kcu.column_name AS child_column
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
            WHERE tc.constraint_type = 'FOREIGN KEY';
            """, conn))
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

    private static string BuildConnectionString(DataSource source, string? plaintextPassword)
    {
        var d = source.SqlConnection ?? throw new InvalidOperationException("PostgreSQL connection details are missing.");
        return new NpgsqlConnectionStringBuilder
        {
            Host = d.Host,
            Port = d.Port <= 0 ? 5432 : d.Port,
            Database = d.DatabaseName,
            Username = d.Username,
            Password = plaintextPassword ?? string.Empty,
            Timeout = d.ConnectionTimeoutSeconds
        }.ConnectionString;
    }
}
