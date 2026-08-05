using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class MetadataRepository(ISqlConnectionFactory connectionFactory) : IMetadataRepository
{
    public async Task<IReadOnlyList<SchemaObject>> GetObjectsAsync(Guid? dataSourceId, CancellationToken ct = default)
    {
        var sql = """
            SELECT SchemaObjectId, DataSourceId, SchemaName, ObjectName, ObjectType, CapturedUtc
            FROM meta.SchemaObject
            WHERE (@DataSourceId IS NULL OR DataSourceId = @DataSourceId)
            ORDER BY SchemaName, ObjectName;
            """;
        var list = new List<SchemaObject>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddNullable("@DataSourceId", dataSourceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new SchemaObject
            {
                SchemaObjectId = reader.GetGuid("SchemaObjectId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                SchemaName = reader.GetString("SchemaName"),
                ObjectName = reader.GetString("ObjectName"),
                ObjectType = Enum.Parse<SchemaObjectType>(reader.GetString("ObjectType")),
                CapturedUtc = reader.GetDateTime("CapturedUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<ColumnDefinition>> GetColumnsAsync(Guid? schemaObjectId, Guid? dataSourceId, CancellationToken ct = default)
    {
        var sql = """
            SELECT c.ColumnDefinitionId, c.SchemaObjectId, c.ColumnName, c.DataType, c.MaxLength,
                   c.NumericPrecision, c.NumericScale, c.IsNullable, c.OrdinalPosition, c.IsPrimaryKey, c.IsForeignKey
            FROM meta.ColumnDefinition c
            INNER JOIN meta.SchemaObject o ON o.SchemaObjectId = c.SchemaObjectId
            WHERE (@SchemaObjectId IS NULL OR c.SchemaObjectId = @SchemaObjectId)
              AND (@DataSourceId IS NULL OR o.DataSourceId = @DataSourceId)
            ORDER BY c.OrdinalPosition;
            """;
        var list = new List<ColumnDefinition>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddNullable("@SchemaObjectId", schemaObjectId);
        cmd.Parameters.AddNullable("@DataSourceId", dataSourceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ColumnDefinition
            {
                ColumnDefinitionId = reader.GetGuid("ColumnDefinitionId"),
                SchemaObjectId = reader.GetGuid("SchemaObjectId"),
                ColumnName = reader.GetString("ColumnName"),
                DataType = reader.GetString("DataType"),
                MaxLength = reader.GetNullableInt32("MaxLength"),
                NumericPrecision = reader.GetNullableByte("NumericPrecision"),
                NumericScale = reader.GetNullableInt32("NumericScale"),
                IsNullable = reader.GetBoolean("IsNullable"),
                OrdinalPosition = reader.GetInt32("OrdinalPosition"),
                IsPrimaryKey = reader.GetBoolean("IsPrimaryKey"),
                IsForeignKey = reader.GetBoolean("IsForeignKey")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<ObjectRelationship>> GetRelationshipsAsync(Guid? dataSourceId, CancellationToken ct = default)
    {
        var sql = """
            SELECT RelationshipId, DataSourceId, ParentObjectId, ChildObjectId,
                   ParentColumnName, ChildColumnName, ConstraintName
            FROM meta.ObjectRelationship
            WHERE (@DataSourceId IS NULL OR DataSourceId = @DataSourceId);
            """;
        var list = new List<ObjectRelationship>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddNullable("@DataSourceId", dataSourceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ObjectRelationship
            {
                RelationshipId = reader.GetGuid("RelationshipId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                ParentObjectId = reader.GetGuid("ParentObjectId"),
                ChildObjectId = reader.GetGuid("ChildObjectId"),
                ParentColumnName = reader.GetString("ParentColumnName"),
                ChildColumnName = reader.GetString("ChildColumnName"),
                ConstraintName = reader.GetNullableString("ConstraintName")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<MetadataRefreshHistory>> GetRefreshHistoryAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default)
    {
        const string sql = """
            SELECT TOP (@Take) RefreshHistoryId, DataSourceId, StartedUtc, CompletedUtc, Status,
                   ObjectsCaptured, ColumnsCaptured, RelationshipsCaptured, ErrorMessage
            FROM meta.MetadataRefreshHistory
            WHERE DataSourceId = @DataSourceId
            ORDER BY StartedUtc DESC;
            """;
        var list = new List<MetadataRefreshHistory>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@DataSourceId", dataSourceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new MetadataRefreshHistory
            {
                RefreshHistoryId = reader.GetInt64("RefreshHistoryId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                StartedUtc = reader.GetDateTime("StartedUtc"),
                CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
                Status = reader.GetString("Status"),
                ObjectsCaptured = reader.GetInt32("ObjectsCaptured"),
                ColumnsCaptured = reader.GetInt32("ColumnsCaptured"),
                RelationshipsCaptured = reader.GetInt32("RelationshipsCaptured"),
                ErrorMessage = reader.GetNullableString("ErrorMessage")
            });
        }
        return list;
    }

    public async Task<long> BeginRefreshAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        const string sql = """
            INSERT INTO meta.MetadataRefreshHistory (DataSourceId, Status)
            OUTPUT INSERTED.RefreshHistoryId
            VALUES (@DataSourceId, N'Running');
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@DataSourceId", dataSourceId);
        return (long)(await cmd.ExecuteScalarAsync(ct))!;
    }

    public async Task CompleteRefreshAsync(long historyId, string status, int objects, int columns, int relationships, string? error, CancellationToken ct = default)
    {
        const string sql = """
            UPDATE meta.MetadataRefreshHistory
            SET CompletedUtc = SYSUTCDATETIME(), Status = @Status,
                ObjectsCaptured = @Objects, ColumnsCaptured = @Columns,
                RelationshipsCaptured = @Relationships, ErrorMessage = @Error
            WHERE RefreshHistoryId = @Id;
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", historyId);
        cmd.Parameters.AddWithValue("@Status", status);
        cmd.Parameters.AddWithValue("@Objects", objects);
        cmd.Parameters.AddWithValue("@Columns", columns);
        cmd.Parameters.AddWithValue("@Relationships", relationships);
        cmd.Parameters.AddNullable("@Error", error);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task ReplaceSnapshotAsync(Guid dataSourceId, CapturedMetadataSnapshot snapshot, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        await using (var delRel = new SqlCommand("DELETE FROM meta.ObjectRelationship WHERE DataSourceId = @Id;", conn, tx))
        {
            delRel.Parameters.AddWithValue("@Id", dataSourceId);
            await delRel.ExecuteNonQueryAsync(ct);
        }

        await using (var delCols = new SqlCommand("""
            DELETE c FROM meta.ColumnDefinition c
            INNER JOIN meta.SchemaObject o ON o.SchemaObjectId = c.SchemaObjectId
            WHERE o.DataSourceId = @Id;
            """, conn, tx))
        {
            delCols.Parameters.AddWithValue("@Id", dataSourceId);
            await delCols.ExecuteNonQueryAsync(ct);
        }

        await using (var delObj = new SqlCommand("DELETE FROM meta.SchemaObject WHERE DataSourceId = @Id;", conn, tx))
        {
            delObj.Parameters.AddWithValue("@Id", dataSourceId);
            await delObj.ExecuteNonQueryAsync(ct);
        }

        var objectIdMap = new Dictionary<(string Schema, string Name, string Type), Guid>();

        foreach (var obj in snapshot.Objects)
        {
            var objectId = obj.SchemaObjectId == Guid.Empty ? Guid.NewGuid() : obj.SchemaObjectId;
            objectIdMap[(obj.SchemaName, obj.ObjectName, obj.ObjectType.ToString())] = objectId;

            await using var cmd = new SqlCommand("""
                INSERT INTO meta.SchemaObject (SchemaObjectId, DataSourceId, SchemaName, ObjectName, ObjectType, CapturedUtc)
                VALUES (@Id, @DataSourceId, @SchemaName, @ObjectName, @ObjectType, SYSUTCDATETIME());
                """, conn, tx);
            cmd.Parameters.AddWithValue("@Id", objectId);
            cmd.Parameters.AddWithValue("@DataSourceId", dataSourceId);
            cmd.Parameters.AddWithValue("@SchemaName", obj.SchemaName);
            cmd.Parameters.AddWithValue("@ObjectName", obj.ObjectName);
            cmd.Parameters.AddWithValue("@ObjectType", obj.ObjectType.ToString());
            await cmd.ExecuteNonQueryAsync(ct);
        }

        foreach (var col in snapshot.Columns)
        {
            var schemaObjectId = col.SchemaObjectId;
            if (schemaObjectId == Guid.Empty)
                continue;

            await using var cmd = new SqlCommand("""
                INSERT INTO meta.ColumnDefinition
                    (ColumnDefinitionId, SchemaObjectId, ColumnName, DataType, MaxLength, NumericPrecision,
                     NumericScale, IsNullable, OrdinalPosition, IsPrimaryKey, IsForeignKey)
                VALUES
                    (@Id, @SchemaObjectId, @ColumnName, @DataType, @MaxLength, @NumericPrecision,
                     @NumericScale, @IsNullable, @OrdinalPosition, @IsPrimaryKey, @IsForeignKey);
                """, conn, tx);
            cmd.Parameters.AddWithValue("@Id", col.ColumnDefinitionId == Guid.Empty ? Guid.NewGuid() : col.ColumnDefinitionId);
            cmd.Parameters.AddWithValue("@SchemaObjectId", schemaObjectId);
            cmd.Parameters.AddWithValue("@ColumnName", col.ColumnName);
            cmd.Parameters.AddWithValue("@DataType", col.DataType);
            cmd.Parameters.AddNullable("@MaxLength", col.MaxLength);
            cmd.Parameters.AddNullable("@NumericPrecision", col.NumericPrecision);
            cmd.Parameters.AddNullable("@NumericScale", col.NumericScale);
            cmd.Parameters.AddWithValue("@IsNullable", col.IsNullable);
            cmd.Parameters.AddWithValue("@OrdinalPosition", col.OrdinalPosition);
            cmd.Parameters.AddWithValue("@IsPrimaryKey", col.IsPrimaryKey);
            cmd.Parameters.AddWithValue("@IsForeignKey", col.IsForeignKey);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        foreach (var rel in snapshot.Relationships)
        {
            await using var cmd = new SqlCommand("""
                INSERT INTO meta.ObjectRelationship
                    (RelationshipId, DataSourceId, ParentObjectId, ChildObjectId, ParentColumnName, ChildColumnName, ConstraintName)
                VALUES
                    (@Id, @DataSourceId, @ParentObjectId, @ChildObjectId, @ParentColumnName, @ChildColumnName, @ConstraintName);
                """, conn, tx);
            cmd.Parameters.AddWithValue("@Id", rel.RelationshipId == Guid.Empty ? Guid.NewGuid() : rel.RelationshipId);
            cmd.Parameters.AddWithValue("@DataSourceId", dataSourceId);
            cmd.Parameters.AddWithValue("@ParentObjectId", rel.ParentObjectId);
            cmd.Parameters.AddWithValue("@ChildObjectId", rel.ChildObjectId);
            cmd.Parameters.AddWithValue("@ParentColumnName", rel.ParentColumnName);
            cmd.Parameters.AddWithValue("@ChildColumnName", rel.ChildColumnName);
            cmd.Parameters.AddNullable("@ConstraintName", rel.ConstraintName);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }
}
