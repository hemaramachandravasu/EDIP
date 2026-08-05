using Edip.Core.Interfaces;
using Edip.Core.Models;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class QualityRepository(ISqlConnectionFactory connectionFactory) : IQualityRepository
{
    public async Task<Guid> CreateProfilingRunAsync(ProfilingRun run, CancellationToken ct = default)
    {
        var id = run.ProfilingRunId == Guid.Empty ? Guid.NewGuid() : run.ProfilingRunId;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            INSERT INTO dq.ProfilingRun (ProfilingRunId, DataSourceId, TriggerType, Status, StartedUtc)
            VALUES (@Id, @DataSourceId, @TriggerType, N'Running', SYSUTCDATETIME());
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@DataSourceId", run.DataSourceId);
        cmd.Parameters.AddWithValue("@TriggerType", run.TriggerType);
        await cmd.ExecuteNonQueryAsync(ct);
        return id;
    }

    public async Task CompleteProfilingRunAsync(Guid runId, string status, int tables, int columns, string? error, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE dq.ProfilingRun
            SET Status = @Status, CompletedUtc = SYSUTCDATETIME(),
                TablesProfiled = @Tables, ColumnsProfiled = @Columns, ErrorMessage = @Error
            WHERE ProfilingRunId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", runId);
        cmd.Parameters.AddWithValue("@Status", status);
        cmd.Parameters.AddWithValue("@Tables", tables);
        cmd.Parameters.AddWithValue("@Columns", columns);
        cmd.Parameters.AddNullable("@Error", error);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task SaveTableProfilesAsync(Guid runId, IReadOnlyList<TableProfile> tables, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        foreach (var table in tables)
        {
            var tableId = table.TableProfileId == Guid.Empty ? Guid.NewGuid() : table.TableProfileId;
            await using (var cmd = new SqlCommand("""
                INSERT INTO dq.TableProfile
                    (TableProfileId, ProfilingRunId, SchemaName, ObjectName, ObjectType, RowCountValue,
                     DuplicateRowCount, IsEmpty, LastDataChangeUtc)
                VALUES
                    (@Id, @RunId, @SchemaName, @ObjectName, @ObjectType, @RowCount,
                     @Dupes, @IsEmpty, @LastChange);
                """, conn, tx))
            {
                cmd.Parameters.AddWithValue("@Id", tableId);
                cmd.Parameters.AddWithValue("@RunId", runId);
                cmd.Parameters.AddWithValue("@SchemaName", table.SchemaName);
                cmd.Parameters.AddWithValue("@ObjectName", table.ObjectName);
                cmd.Parameters.AddWithValue("@ObjectType", table.ObjectType);
                cmd.Parameters.AddWithValue("@RowCount", table.RowCountValue);
                cmd.Parameters.AddWithValue("@Dupes", table.DuplicateRowCount);
                cmd.Parameters.AddWithValue("@IsEmpty", table.IsEmpty);
                cmd.Parameters.AddNullable("@LastChange", table.LastDataChangeUtc);
                await cmd.ExecuteNonQueryAsync(ct);
            }

            foreach (var col in table.Columns)
            {
                await using var cmd = new SqlCommand("""
                    INSERT INTO dq.ColumnProfile
                        (ColumnProfileId, TableProfileId, ColumnName, DataType, NullCount, NullPct,
                         DistinctCount, MinValue, MaxValue, SampleInvalidCount)
                    VALUES
                        (@Id, @TableId, @ColumnName, @DataType, @NullCount, @NullPct,
                         @DistinctCount, @MinValue, @MaxValue, @Invalid);
                    """, conn, tx);
                cmd.Parameters.AddWithValue("@Id", col.ColumnProfileId == Guid.Empty ? Guid.NewGuid() : col.ColumnProfileId);
                cmd.Parameters.AddWithValue("@TableId", tableId);
                cmd.Parameters.AddWithValue("@ColumnName", col.ColumnName);
                cmd.Parameters.AddWithValue("@DataType", col.DataType);
                cmd.Parameters.AddWithValue("@NullCount", col.NullCount);
                cmd.Parameters.AddWithValue("@NullPct", col.NullPct);
                cmd.Parameters.AddWithValue("@DistinctCount", col.DistinctCount);
                cmd.Parameters.AddNullable("@MinValue", col.MinValue);
                cmd.Parameters.AddNullable("@MaxValue", col.MaxValue);
                cmd.Parameters.AddWithValue("@Invalid", col.SampleInvalidCount);
                await cmd.ExecuteNonQueryAsync(ct);
            }
        }

        await tx.CommitAsync(ct);
    }

    public async Task<ProfilingRun?> GetProfilingRunAsync(Guid runId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT ProfilingRunId, DataSourceId, TriggerType, Status, StartedUtc, CompletedUtc,
                   TablesProfiled, ColumnsProfiled, ErrorMessage
            FROM dq.ProfilingRun WHERE ProfilingRunId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", runId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        var run = MapRun(reader);
        await reader.CloseAsync();
        run.Tables = (await LoadTablesAsync(conn, run.ProfilingRunId, ct)).ToList();
        return run;
    }

    public async Task<IReadOnlyList<ProfilingRun>> GetProfilingRunsAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default)
    {
        var list = new List<ProfilingRun>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT TOP (@Take) ProfilingRunId, DataSourceId, TriggerType, Status, StartedUtc, CompletedUtc,
                   TablesProfiled, ColumnsProfiled, ErrorMessage
            FROM dq.ProfilingRun WHERE DataSourceId = @Id ORDER BY StartedUtc DESC;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", dataSourceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct)) list.Add(MapRun(reader));
        return list;
    }

    public async Task<ProfilingRun?> GetLatestSucceededRunAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT TOP (1) ProfilingRunId, DataSourceId, TriggerType, Status, StartedUtc, CompletedUtc,
                   TablesProfiled, ColumnsProfiled, ErrorMessage
            FROM dq.ProfilingRun
            WHERE DataSourceId = @Id AND Status = N'Succeeded'
            ORDER BY StartedUtc DESC;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", dataSourceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        var run = MapRun(reader);
        await reader.CloseAsync();
        run.Tables = (await LoadTablesAsync(conn, run.ProfilingRunId, ct)).ToList();
        return run;
    }

    public async Task<Guid> SaveQualityAssessmentAsync(QualityAssessment assessment, CancellationToken ct = default)
    {
        var id = assessment.AssessmentId == Guid.Empty ? Guid.NewGuid() : assessment.AssessmentId;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        await using (var cmd = new SqlCommand("""
            INSERT INTO dq.QualityAssessment
                (AssessmentId, DataSourceId, ProfilingRunId, OverallScore, Grade, MissingScore, DuplicateScore,
                 TypeScore, ReferentialScore, EmptyTableScore, FreshnessScore, Summary)
            VALUES
                (@Id, @DataSourceId, @ProfilingRunId, @Overall, @Grade, @Missing, @Dupes,
                 @Type, @Ref, @Empty, @Fresh, @Summary);
            """, conn, tx))
        {
            cmd.Parameters.AddWithValue("@Id", id);
            cmd.Parameters.AddWithValue("@DataSourceId", assessment.DataSourceId);
            cmd.Parameters.AddNullable("@ProfilingRunId", assessment.ProfilingRunId);
            cmd.Parameters.AddWithValue("@Overall", assessment.OverallScore);
            cmd.Parameters.AddWithValue("@Grade", assessment.Grade);
            cmd.Parameters.AddWithValue("@Missing", assessment.MissingScore);
            cmd.Parameters.AddWithValue("@Dupes", assessment.DuplicateScore);
            cmd.Parameters.AddWithValue("@Type", assessment.TypeScore);
            cmd.Parameters.AddWithValue("@Ref", assessment.ReferentialScore);
            cmd.Parameters.AddWithValue("@Empty", assessment.EmptyTableScore);
            cmd.Parameters.AddWithValue("@Fresh", assessment.FreshnessScore);
            cmd.Parameters.AddNullable("@Summary", assessment.Summary);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        foreach (var check in assessment.Checks)
        {
            await using var cmd = new SqlCommand("""
                INSERT INTO dq.QualityCheckResult
                    (CheckResultId, AssessmentId, CheckCode, CheckName, Severity, Passed, AffectedCount, Details)
                VALUES
                    (@Id, @AssessmentId, @Code, @Name, @Severity, @Passed, @Count, @Details);
                """, conn, tx);
            cmd.Parameters.AddWithValue("@Id", Guid.NewGuid());
            cmd.Parameters.AddWithValue("@AssessmentId", id);
            cmd.Parameters.AddWithValue("@Code", check.CheckCode);
            cmd.Parameters.AddWithValue("@Name", check.CheckName);
            cmd.Parameters.AddWithValue("@Severity", check.Severity);
            cmd.Parameters.AddWithValue("@Passed", check.Passed);
            cmd.Parameters.AddWithValue("@Count", check.AffectedCount);
            cmd.Parameters.AddNullable("@Details", check.Details);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return id;
    }

    public async Task<QualityAssessment?> GetAssessmentAsync(Guid assessmentId, CancellationToken ct = default)
    {
        var items = await LoadAssessmentsAsync("""
            SELECT a.AssessmentId, a.DataSourceId, a.ProfilingRunId, a.OverallScore, a.Grade,
                   a.MissingScore, a.DuplicateScore, a.TypeScore, a.ReferentialScore, a.EmptyTableScore,
                   a.FreshnessScore, a.AssessedUtc, a.Summary
            FROM dq.QualityAssessment a WHERE a.AssessmentId = @Id;
            """, cmd => cmd.Parameters.AddWithValue("@Id", assessmentId), ct);
        return items.FirstOrDefault();
    }

    public async Task<IReadOnlyList<QualityAssessment>> GetAssessmentsAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default)
        => await LoadAssessmentsAsync("""
            SELECT TOP (@Take) a.AssessmentId, a.DataSourceId, a.ProfilingRunId, a.OverallScore, a.Grade,
                   a.MissingScore, a.DuplicateScore, a.TypeScore, a.ReferentialScore, a.EmptyTableScore,
                   a.FreshnessScore, a.AssessedUtc, a.Summary
            FROM dq.QualityAssessment a
            WHERE a.DataSourceId = @Id
            ORDER BY a.AssessedUtc DESC;
            """, cmd =>
        {
            cmd.Parameters.AddWithValue("@Id", dataSourceId);
            cmd.Parameters.AddWithValue("@Take", take);
        }, ct);

    public async Task<Guid> BeginSyncLogAsync(MetadataSyncLog log, CancellationToken ct = default)
    {
        var id = log.SyncLogId == Guid.Empty ? Guid.NewGuid() : log.SyncLogId;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            INSERT INTO dq.MetadataSyncLog (SyncLogId, DataSourceId, TriggerType, Status, StartedUtc)
            VALUES (@Id, @DataSourceId, @TriggerType, N'Running', SYSUTCDATETIME());
            """, conn);
        cmd.Parameters.AddWithValue("@Id", id);
        cmd.Parameters.AddWithValue("@DataSourceId", log.DataSourceId);
        cmd.Parameters.AddWithValue("@TriggerType", log.TriggerType);
        await cmd.ExecuteNonQueryAsync(ct);
        return id;
    }

    public async Task CompleteSyncLogAsync(Guid syncLogId, string status, int added, int removed, int changed, string? error, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            UPDATE dq.MetadataSyncLog
            SET Status = @Status, CompletedUtc = SYSUTCDATETIME(),
                ObjectsAdded = @Added, ObjectsRemoved = @Removed, ColumnsChanged = @Changed, ErrorMessage = @Error
            WHERE SyncLogId = @Id;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", syncLogId);
        cmd.Parameters.AddWithValue("@Status", status);
        cmd.Parameters.AddWithValue("@Added", added);
        cmd.Parameters.AddWithValue("@Removed", removed);
        cmd.Parameters.AddWithValue("@Changed", changed);
        cmd.Parameters.AddNullable("@Error", error);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task AddSchemaChangesAsync(Guid dataSourceId, Guid syncLogId, IReadOnlyList<SchemaChangeEvent> changes, CancellationToken ct = default)
    {
        if (changes.Count == 0) return;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        foreach (var change in changes)
        {
            await using var cmd = new SqlCommand("""
                INSERT INTO dq.SchemaChangeEvent
                    (SchemaChangeId, DataSourceId, SyncLogId, ChangeType, SchemaName, ObjectName, ColumnName, OldValue, NewValue)
                VALUES
                    (@Id, @DataSourceId, @SyncLogId, @ChangeType, @SchemaName, @ObjectName, @ColumnName, @OldValue, @NewValue);
                """, conn);
            cmd.Parameters.AddWithValue("@Id", change.SchemaChangeId == Guid.Empty ? Guid.NewGuid() : change.SchemaChangeId);
            cmd.Parameters.AddWithValue("@DataSourceId", dataSourceId);
            cmd.Parameters.AddWithValue("@SyncLogId", syncLogId);
            cmd.Parameters.AddWithValue("@ChangeType", change.ChangeType);
            cmd.Parameters.AddWithValue("@SchemaName", change.SchemaName);
            cmd.Parameters.AddWithValue("@ObjectName", change.ObjectName);
            cmd.Parameters.AddNullable("@ColumnName", change.ColumnName);
            cmd.Parameters.AddNullable("@OldValue", change.OldValue);
            cmd.Parameters.AddNullable("@NewValue", change.NewValue);
            await cmd.ExecuteNonQueryAsync(ct);
        }
    }

    public async Task<IReadOnlyList<SchemaChangeEvent>> GetSchemaChangesAsync(Guid dataSourceId, int take = 50, CancellationToken ct = default)
    {
        var list = new List<SchemaChangeEvent>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT TOP (@Take) SchemaChangeId, DataSourceId, SyncLogId, ChangeType, SchemaName, ObjectName,
                   ColumnName, OldValue, NewValue, DetectedUtc
            FROM dq.SchemaChangeEvent WHERE DataSourceId = @Id ORDER BY DetectedUtc DESC;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", dataSourceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new SchemaChangeEvent
            {
                SchemaChangeId = reader.GetGuid("SchemaChangeId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                SyncLogId = reader.IsDBNull(reader.GetOrdinal("SyncLogId")) ? null : reader.GetGuid("SyncLogId"),
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

    public async Task<IReadOnlyList<MetadataSyncLog>> GetSyncLogsAsync(Guid dataSourceId, int take = 20, CancellationToken ct = default)
    {
        var list = new List<MetadataSyncLog>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("""
            SELECT TOP (@Take) SyncLogId, DataSourceId, TriggerType, Status, StartedUtc, CompletedUtc,
                   ObjectsAdded, ObjectsRemoved, ColumnsChanged, ErrorMessage
            FROM dq.MetadataSyncLog WHERE DataSourceId = @Id ORDER BY StartedUtc DESC;
            """, conn);
        cmd.Parameters.AddWithValue("@Id", dataSourceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new MetadataSyncLog
            {
                SyncLogId = reader.GetGuid("SyncLogId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                TriggerType = reader.GetString("TriggerType"),
                Status = reader.GetString("Status"),
                StartedUtc = reader.GetDateTime("StartedUtc"),
                CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
                ObjectsAdded = reader.GetInt32("ObjectsAdded"),
                ObjectsRemoved = reader.GetInt32("ObjectsRemoved"),
                ColumnsChanged = reader.GetInt32("ColumnsChanged"),
                ErrorMessage = reader.GetNullableString("ErrorMessage")
            });
        }
        return list;
    }

    public async Task ArchiveHistoryAsync(int retainDays, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC dq.usp_ArchiveProfilingHistory @RetainDays;", conn);
        cmd.Parameters.AddWithValue("@RetainDays", retainDays);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private async Task<IReadOnlyList<QualityAssessment>> LoadAssessmentsAsync(string sql, Action<SqlCommand> configure, CancellationToken ct)
    {
        var list = new List<QualityAssessment>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        configure(cmd);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new QualityAssessment
            {
                AssessmentId = reader.GetGuid("AssessmentId"),
                DataSourceId = reader.GetGuid("DataSourceId"),
                ProfilingRunId = reader.IsDBNull(reader.GetOrdinal("ProfilingRunId")) ? null : reader.GetGuid("ProfilingRunId"),
                OverallScore = reader.GetDecimal("OverallScore"),
                Grade = reader.GetString("Grade"),
                MissingScore = reader.GetDecimal("MissingScore"),
                DuplicateScore = reader.GetDecimal("DuplicateScore"),
                TypeScore = reader.GetDecimal("TypeScore"),
                ReferentialScore = reader.GetDecimal("ReferentialScore"),
                EmptyTableScore = reader.GetDecimal("EmptyTableScore"),
                FreshnessScore = reader.GetDecimal("FreshnessScore"),
                AssessedUtc = reader.GetDateTime("AssessedUtc"),
                Summary = reader.GetNullableString("Summary")
            });
        }
        await reader.CloseAsync();

        foreach (var assessment in list)
        {
            await using var checkCmd = new SqlCommand("""
                SELECT CheckCode, CheckName, Severity, Passed, AffectedCount, Details
                FROM dq.QualityCheckResult WHERE AssessmentId = @Id;
                """, conn);
            checkCmd.Parameters.AddWithValue("@Id", assessment.AssessmentId);
            await using var checkReader = await checkCmd.ExecuteReaderAsync(ct);
            while (await checkReader.ReadAsync(ct))
            {
                assessment.Checks.Add(new QualityCheckResult
                {
                    AssessmentId = assessment.AssessmentId,
                    CheckCode = checkReader.GetString("CheckCode"),
                    CheckName = checkReader.GetString("CheckName"),
                    Severity = checkReader.GetString("Severity"),
                    Passed = checkReader.GetBoolean("Passed"),
                    AffectedCount = checkReader.GetInt64("AffectedCount"),
                    Details = checkReader.GetNullableString("Details")
                });
            }
        }
        return list;
    }

    private static ProfilingRun MapRun(SqlDataReader reader) => new()
    {
        ProfilingRunId = reader.GetGuid("ProfilingRunId"),
        DataSourceId = reader.GetGuid("DataSourceId"),
        TriggerType = reader.GetString("TriggerType"),
        Status = reader.GetString("Status"),
        StartedUtc = reader.GetDateTime("StartedUtc"),
        CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
        TablesProfiled = reader.GetInt32("TablesProfiled"),
        ColumnsProfiled = reader.GetInt32("ColumnsProfiled"),
        ErrorMessage = reader.GetNullableString("ErrorMessage")
    };

    private static async Task<IReadOnlyList<TableProfile>> LoadTablesAsync(SqlConnection conn, Guid runId, CancellationToken ct)
    {
        var tables = new List<TableProfile>();
        await using (var cmd = new SqlCommand("""
            SELECT TableProfileId, ProfilingRunId, SchemaName, ObjectName, ObjectType, RowCountValue,
                   DuplicateRowCount, IsEmpty, LastDataChangeUtc
            FROM dq.TableProfile WHERE ProfilingRunId = @RunId;
            """, conn))
        {
            cmd.Parameters.AddWithValue("@RunId", runId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                tables.Add(new TableProfile
                {
                    TableProfileId = reader.GetGuid("TableProfileId"),
                    ProfilingRunId = reader.GetGuid("ProfilingRunId"),
                    SchemaName = reader.GetString("SchemaName"),
                    ObjectName = reader.GetString("ObjectName"),
                    ObjectType = reader.GetString("ObjectType"),
                    RowCountValue = reader.GetInt64("RowCountValue"),
                    DuplicateRowCount = reader.GetInt64("DuplicateRowCount"),
                    IsEmpty = reader.GetBoolean("IsEmpty"),
                    LastDataChangeUtc = reader.GetNullableDateTime("LastDataChangeUtc")
                });
            }
        }

        foreach (var table in tables)
        {
            await using var cmd = new SqlCommand("""
                SELECT ColumnProfileId, TableProfileId, ColumnName, DataType, NullCount, NullPct,
                       DistinctCount, MinValue, MaxValue, SampleInvalidCount
                FROM dq.ColumnProfile WHERE TableProfileId = @Id;
                """, conn);
            cmd.Parameters.AddWithValue("@Id", table.TableProfileId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                table.Columns.Add(new ColumnProfile
                {
                    ColumnProfileId = reader.GetGuid("ColumnProfileId"),
                    TableProfileId = reader.GetGuid("TableProfileId"),
                    ColumnName = reader.GetString("ColumnName"),
                    DataType = reader.GetString("DataType"),
                    NullCount = reader.GetInt64("NullCount"),
                    NullPct = reader.GetDecimal("NullPct"),
                    DistinctCount = reader.GetInt64("DistinctCount"),
                    MinValue = reader.GetNullableString("MinValue"),
                    MaxValue = reader.GetNullableString("MaxValue"),
                    SampleInvalidCount = reader.GetInt64("SampleInvalidCount")
                });
            }
        }
        return tables;
    }
}
