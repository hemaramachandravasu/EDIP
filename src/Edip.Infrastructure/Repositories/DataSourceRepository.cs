using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;
// ISqlConnectionFactory lives in Edip.Infrastructure.Data

namespace Edip.Infrastructure.Repositories;

public sealed class DataSourceRepository(ISqlConnectionFactory connectionFactory, ISecretProtector secretProtector) : IDataSourceRepository
{
    public async Task<IReadOnlyList<DataSource>> GetAllAsync(CancellationToken ct = default)
    {
        const string sql = """
            SELECT ds.DataSourceId, ds.Name, ds.Description, ds.DataSourceTypeId, dst.TypeCode AS DataSourceTypeCode,
                   ds.Status, ds.HealthStatus, ds.LastValidatedUtc, ds.CreatedUtc, ds.ModifiedUtc, ds.IsDeleted
            FROM reg.DataSource ds
            INNER JOIN reg.DataSourceType dst ON dst.DataSourceTypeId = ds.DataSourceTypeId
            WHERE ds.IsDeleted = 0
            ORDER BY ds.Name;
            """;

        var list = new List<DataSource>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapHeader(reader));
        return list;
    }

    public async Task<DataSource?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        const string sql = """
            SELECT ds.DataSourceId, ds.Name, ds.Description, ds.DataSourceTypeId, dst.TypeCode AS DataSourceTypeCode,
                   ds.Status, ds.HealthStatus, ds.LastValidatedUtc, ds.CreatedUtc, ds.ModifiedUtc, ds.IsDeleted
            FROM reg.DataSource ds
            INNER JOIN reg.DataSourceType dst ON dst.DataSourceTypeId = ds.DataSourceTypeId
            WHERE ds.DataSourceId = @Id AND ds.IsDeleted = 0;
            """;

        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null;

        var source = MapHeader(reader);
        await reader.CloseAsync();

        if (IsSqlType(source.DataSourceTypeCode))
            source.SqlConnection = await LoadSqlDetailAsync(conn, id, ct);
        else
            source.FileDetail = await LoadFileDetailAsync(conn, id, ct);

        return source;
    }

    public async Task<Guid> CreateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        var id = source.DataSourceId == Guid.Empty ? Guid.NewGuid() : source.DataSourceId;
        var typeId = await ResolveTypeIdAsync(conn, tx, source.DataSourceTypeCode, ct);

        const string insertDs = """
            INSERT INTO reg.DataSource (DataSourceId, Name, Description, DataSourceTypeId, Status, HealthStatus)
            VALUES (@Id, @Name, @Description, @TypeId, @Status, @Health);
            """;

        await using (var cmd = new SqlCommand(insertDs, conn, tx))
        {
            cmd.Parameters.AddWithValue("@Id", id);
            cmd.Parameters.AddWithValue("@Name", source.Name);
            cmd.Parameters.AddNullable("@Description", source.Description);
            cmd.Parameters.AddWithValue("@TypeId", typeId);
            cmd.Parameters.AddWithValue("@Status", source.Status);
            cmd.Parameters.AddWithValue("@Health", source.HealthStatus.ToString());
            await cmd.ExecuteNonQueryAsync(ct);
        }

        if (source.SqlConnection is not null)
            await UpsertSqlDetailAsync(conn, tx, id, source.SqlConnection, plaintextPassword, ct);
        if (source.FileDetail is not null)
            await UpsertFileDetailAsync(conn, tx, id, source.FileDetail, ct);

        await tx.CommitAsync(ct);
        return id;
    }

    public async Task UpdateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        const string sql = """
            UPDATE reg.DataSource
            SET Name = @Name, Description = @Description, Status = @Status, ModifiedUtc = SYSUTCDATETIME()
            WHERE DataSourceId = @Id AND IsDeleted = 0;
            """;

        await using (var cmd = new SqlCommand(sql, conn, tx))
        {
            cmd.Parameters.AddWithValue("@Id", source.DataSourceId);
            cmd.Parameters.AddWithValue("@Name", source.Name);
            cmd.Parameters.AddNullable("@Description", source.Description);
            cmd.Parameters.AddWithValue("@Status", source.Status);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        if (source.SqlConnection is not null)
            await UpsertSqlDetailAsync(conn, tx, source.DataSourceId, source.SqlConnection, plaintextPassword, ct);
        if (source.FileDetail is not null)
            await UpsertFileDetailAsync(conn, tx, source.DataSourceId, source.FileDetail, ct);

        await tx.CommitAsync(ct);
    }

    public async Task SoftDeleteAsync(Guid id, CancellationToken ct = default)
    {
        const string sql = """
            UPDATE reg.DataSource
            SET IsDeleted = 1, ModifiedUtc = SYSUTCDATETIME(), Status = N'Disabled'
            WHERE DataSourceId = @Id;
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task UpdateHealthAsync(Guid id, HealthStatus health, DateTime validatedUtc, CancellationToken ct = default)
    {
        const string sql = """
            UPDATE reg.DataSource
            SET HealthStatus = @Health, LastValidatedUtc = @ValidatedUtc, ModifiedUtc = SYSUTCDATETIME()
            WHERE DataSourceId = @Id;
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@Health", health.ToString());
        cmd.Parameters.AddWithValue("@ValidatedUtc", validatedUtc);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task AddValidationLogAsync(ConnectionValidationLog log, CancellationToken ct = default)
    {
        const string sql = """
            INSERT INTO reg.ConnectionValidationLog (DataSourceId, IsSuccess, Message, LatencyMs, ValidatedUtc)
            VALUES (@DataSourceId, @IsSuccess, @Message, @LatencyMs, @ValidatedUtc);
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@DataSourceId", log.DataSourceId);
        cmd.Parameters.AddWithValue("@IsSuccess", log.IsSuccess);
        cmd.Parameters.AddNullable("@Message", log.Message);
        cmd.Parameters.AddNullable("@LatencyMs", log.LatencyMs);
        cmd.Parameters.AddWithValue("@ValidatedUtc", log.ValidatedUtc);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IReadOnlyList<ConnectionValidationLog>> GetRecentValidationsAsync(Guid id, int take = 10, CancellationToken ct = default)
    {
        const string sql = """
            SELECT TOP (@Take) ValidationLogId, DataSourceId, IsSuccess, Message, LatencyMs, ValidatedUtc
            FROM reg.ConnectionValidationLog
            WHERE DataSourceId = @Id
            ORDER BY ValidatedUtc DESC;
            """;
        var list = new List<ConnectionValidationLog>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ConnectionValidationLog
            {
                ValidationLogId = reader.GetInt64("ValidationLogId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                IsSuccess = reader.GetBoolean("IsSuccess"),
                Message = reader.GetNullableString("Message"),
                LatencyMs = reader.GetNullableInt32("LatencyMs"),
                ValidatedUtc = reader.GetDateTime("ValidatedUtc")
            });
        }
        return list;
    }

    private static DataSource MapHeader(SqlDataReader reader) => new()
    {
        DataSourceId = reader.GetGuid("DataSourceId"),
        Name = reader.GetString("Name"),
        Description = reader.GetNullableString("Description"),
        DataSourceTypeId = reader.GetInt32("DataSourceTypeId"),
        DataSourceTypeCode = reader.GetString("DataSourceTypeCode"),
        Status = reader.GetString("Status"),
        HealthStatus = Enum.Parse<HealthStatus>(reader.GetString("HealthStatus")),
        LastValidatedUtc = reader.GetNullableDateTime("LastValidatedUtc"),
        CreatedUtc = reader.GetDateTime("CreatedUtc"),
        ModifiedUtc = reader.GetDateTime("ModifiedUtc"),
        IsDeleted = reader.GetBoolean("IsDeleted")
    };

    private static bool IsSqlType(string code) =>
        code is "SqlServer" or "MySql" or "PostgreSql";

    private static async Task<int> ResolveTypeIdAsync(SqlConnection conn, SqlTransaction tx, string typeCode, CancellationToken ct)
    {
        await using var cmd = new SqlCommand("SELECT DataSourceTypeId FROM reg.DataSourceType WHERE TypeCode = @Code;", conn, tx);
        cmd.Parameters.AddWithValue("@Code", typeCode);
        var result = await cmd.ExecuteScalarAsync(ct);
        if (result is null or DBNull)
            throw new InvalidOperationException($"Unknown data source type '{typeCode}'.");
        return Convert.ToInt32(result);
    }

    private async Task UpsertSqlDetailAsync(SqlConnection conn, SqlTransaction tx, Guid id, SqlConnectionDetail detail, string? plaintextPassword, CancellationToken ct)
    {
        string? encrypted = null;
        if (!string.IsNullOrWhiteSpace(plaintextPassword))
            encrypted = secretProtector.Protect(plaintextPassword);
        else if (!string.IsNullOrWhiteSpace(detail.EncryptedPassword))
            encrypted = detail.EncryptedPassword;

        const string sql = """
            MERGE reg.SqlConnectionDetail AS t
            USING (SELECT @Id AS DataSourceId) AS s
            ON t.DataSourceId = s.DataSourceId
            WHEN MATCHED THEN UPDATE SET
                Host = @Host, Port = @Port, DatabaseName = @DatabaseName, AuthMode = @AuthMode,
                Username = @Username,
                EncryptedPassword = CASE WHEN @EncryptedPassword IS NULL THEN t.EncryptedPassword ELSE @EncryptedPassword END,
                TrustServerCertificate = @Trust, ConnectionTimeoutSeconds = @Timeout
            WHEN NOT MATCHED THEN INSERT
                (DataSourceId, Host, Port, DatabaseName, AuthMode, Username, EncryptedPassword, TrustServerCertificate, ConnectionTimeoutSeconds)
            VALUES
                (@Id, @Host, @Port, @DatabaseName, @AuthMode, @Username, @EncryptedPassword, @Trust, @Timeout);
            """;

        await using var cmd = new SqlCommand(sql, conn, tx);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@Host", detail.Host);
        cmd.Parameters.AddWithValue("@Port", detail.Port);
        cmd.Parameters.AddWithValue("@DatabaseName", detail.DatabaseName);
        cmd.Parameters.AddWithValue("@AuthMode", detail.AuthMode);
        cmd.Parameters.AddWithValue("@Username", detail.Username);
        cmd.Parameters.AddNullable("@EncryptedPassword", encrypted);
        cmd.Parameters.AddWithValue("@Trust", detail.TrustServerCertificate);
        cmd.Parameters.AddWithValue("@Timeout", detail.ConnectionTimeoutSeconds);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task UpsertFileDetailAsync(SqlConnection conn, SqlTransaction tx, Guid id, FileDataSourceDetail detail, CancellationToken ct)
    {
        const string sql = """
            MERGE reg.FileDataSourceDetail AS t
            USING (SELECT @Id AS DataSourceId) AS s
            ON t.DataSourceId = s.DataSourceId
            WHEN MATCHED THEN UPDATE SET
                FilePath = @FilePath, Format = @Format, Delimiter = @Delimiter,
                HasHeaderRow = @HasHeaderRow, SheetName = @SheetName, EncodingName = @EncodingName
            WHEN NOT MATCHED THEN INSERT
                (DataSourceId, FilePath, Format, Delimiter, HasHeaderRow, SheetName, EncodingName)
            VALUES
                (@Id, @FilePath, @Format, @Delimiter, @HasHeaderRow, @SheetName, @EncodingName);
            """;

        await using var cmd = new SqlCommand(sql, conn, tx);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@FilePath", detail.FilePath);
        cmd.Parameters.AddWithValue("@Format", detail.Format);
        cmd.Parameters.AddWithValue("@Delimiter", detail.Delimiter);
        cmd.Parameters.AddWithValue("@HasHeaderRow", detail.HasHeaderRow);
        cmd.Parameters.AddNullable("@SheetName", detail.SheetName);
        cmd.Parameters.AddWithValue("@EncodingName", detail.EncodingName);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static async Task<SqlConnectionDetail?> LoadSqlDetailAsync(SqlConnection conn, Guid id, CancellationToken ct)
    {
        const string sql = """
            SELECT DataSourceId, Host, Port, DatabaseName, AuthMode, Username, EncryptedPassword,
                   TrustServerCertificate, ConnectionTimeoutSeconds
            FROM reg.SqlConnectionDetail WHERE DataSourceId = @Id;
            """;
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null;

        return new SqlConnectionDetail
        {
            DataSourceId = reader.GetGuid("DataSourceId"),
            Host = reader.GetString("Host"),
            Port = reader.GetInt32("Port"),
            DatabaseName = reader.GetString("DatabaseName"),
            AuthMode = reader.GetString("AuthMode"),
            Username = reader.GetString("Username"),
            EncryptedPassword = reader.GetNullableString("EncryptedPassword"),
            TrustServerCertificate = reader.GetBoolean("TrustServerCertificate"),
            ConnectionTimeoutSeconds = reader.GetInt32("ConnectionTimeoutSeconds")
        };
    }

    private static async Task<FileDataSourceDetail?> LoadFileDetailAsync(SqlConnection conn, Guid id, CancellationToken ct)
    {
        const string sql = """
            SELECT DataSourceId, FilePath, Format, Delimiter, HasHeaderRow, SheetName, EncodingName
            FROM reg.FileDataSourceDetail WHERE DataSourceId = @Id;
            """;
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null;

        return new FileDataSourceDetail
        {
            DataSourceId = reader.GetGuid("DataSourceId"),
            FilePath = reader.GetString("FilePath"),
            Format = reader.GetString("Format"),
            Delimiter = reader.GetString("Delimiter"),
            HasHeaderRow = reader.GetBoolean("HasHeaderRow"),
            SheetName = reader.GetNullableString("SheetName"),
            EncodingName = reader.GetString("EncodingName")
        };
    }
}
