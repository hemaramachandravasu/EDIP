using System.Diagnostics;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using MySqlConnector;

namespace Edip.Infrastructure.Connectors;

public sealed class MySqlProbe : IConnectionProbe
{
    public string SupportedTypeCode => "MySql";

    public async Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            await using var conn = new MySqlConnection(BuildConnectionString(source, plaintextPassword));
            await conn.OpenAsync(ct);
            await using var cmd = new MySqlCommand("SELECT 1;", conn);
            await cmd.ExecuteScalarAsync(ct);
            sw.Stop();
            return new ProbeResult { IsSuccess = true, Message = "MySQL connection successful.", LatencyMs = (int)sw.ElapsedMilliseconds };
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
        var db = source.SqlConnection!.DatabaseName;
        await using var conn = new MySqlConnection(BuildConnectionString(source, plaintextPassword));
        await conn.OpenAsync(ct);

        var objects = new Dictionary<(string Schema, string Name), Guid>();

        await using (var cmd = new MySqlCommand("""
            SELECT TABLE_SCHEMA, TABLE_NAME, CASE WHEN TABLE_TYPE = 'VIEW' THEN 'View' ELSE 'Table' END AS ObjectType
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = @Db;
            """, conn))
        {
            cmd.Parameters.AddWithValue("@Db", db);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
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

        await using (var cmd = new MySqlCommand("""
            SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH,
                   NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE, ORDINAL_POSITION,
                   CASE WHEN COLUMN_KEY = 'PRI' THEN 1 ELSE 0 END AS IsPrimaryKey,
                   CASE WHEN COLUMN_KEY = 'MUL' THEN 1 ELSE 0 END AS IsForeignKey
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = @Db
            ORDER BY TABLE_NAME, ORDINAL_POSITION;
            """, conn))
        {
            cmd.Parameters.AddWithValue("@Db", db);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
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

        await using (var cmd = new MySqlCommand("""
            SELECT CONSTRAINT_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME,
                   TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = @Db AND REFERENCED_TABLE_NAME IS NOT NULL;
            """, conn))
        {
            cmd.Parameters.AddWithValue("@Db", db);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
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
        var d = source.SqlConnection ?? throw new InvalidOperationException("MySQL connection details are missing.");
        return new MySqlConnectionStringBuilder
        {
            Server = d.Host,
            Port = (uint)(d.Port <= 0 ? 3306 : d.Port),
            Database = d.DatabaseName,
            UserID = d.Username,
            Password = plaintextPassword ?? string.Empty,
            ConnectionTimeout = (uint)d.ConnectionTimeoutSeconds
        }.ConnectionString;
    }
}
