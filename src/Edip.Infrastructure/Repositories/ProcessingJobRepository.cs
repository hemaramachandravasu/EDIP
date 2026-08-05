using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class ProcessingJobRepository(ISqlConnectionFactory connectionFactory) : IProcessingJobRepository
{
    public async Task<IReadOnlyList<ProcessingJob>> GetAllAsync(CancellationToken ct = default)
    {
        const string sql = """
            SELECT j.JobId, j.JobName, j.Description, j.DataSourceId, j.JobType, j.IsEnabled,
                   j.MaxRetries, j.RetryDelaySeconds, j.CreatedUtc, j.ModifiedUtc,
                   s.ScheduleId, s.FrequencyCode, s.IntervalMinutes, s.CronExpression,
                   s.NextRunUtc, s.LastRunUtc, s.IsActive
            FROM jobs.ProcessingJob j
            LEFT JOIN jobs.JobSchedule s ON s.JobId = j.JobId
            ORDER BY j.JobName;
            """;
        return await ReadJobsAsync(sql, null, ct);
    }

    public async Task<ProcessingJob?> GetByIdAsync(Guid jobId, CancellationToken ct = default)
    {
        const string sql = """
            SELECT j.JobId, j.JobName, j.Description, j.DataSourceId, j.JobType, j.IsEnabled,
                   j.MaxRetries, j.RetryDelaySeconds, j.CreatedUtc, j.ModifiedUtc,
                   s.ScheduleId, s.FrequencyCode, s.IntervalMinutes, s.CronExpression,
                   s.NextRunUtc, s.LastRunUtc, s.IsActive
            FROM jobs.ProcessingJob j
            LEFT JOIN jobs.JobSchedule s ON s.JobId = j.JobId
            WHERE j.JobId = @JobId;
            """;
        var jobs = await ReadJobsAsync(sql, cmd => cmd.Parameters.AddWithValue("@JobId", jobId), ct);
        return jobs.FirstOrDefault();
    }

    public async Task<Guid> CreateAsync(ProcessingJob job, CancellationToken ct = default)
    {
        var jobId = job.JobId == Guid.Empty ? Guid.NewGuid() : job.JobId;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        await using (var cmd = new SqlCommand("""
            INSERT INTO jobs.ProcessingJob
                (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
            VALUES
                (@JobId, @JobName, @Description, @DataSourceId, @JobType, @IsEnabled, @MaxRetries, @RetryDelaySeconds);
            """, conn, tx))
        {
            cmd.Parameters.AddWithValue("@JobId", jobId);
            cmd.Parameters.AddWithValue("@JobName", job.JobName);
            cmd.Parameters.AddNullable("@Description", job.Description);
            cmd.Parameters.AddWithValue("@DataSourceId", job.DataSourceId);
            cmd.Parameters.AddWithValue("@JobType", job.JobType.ToString());
            cmd.Parameters.AddWithValue("@IsEnabled", job.IsEnabled);
            cmd.Parameters.AddWithValue("@MaxRetries", job.MaxRetries);
            cmd.Parameters.AddWithValue("@RetryDelaySeconds", job.RetryDelaySeconds);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        if (job.Schedule is not null)
        {
            var scheduleId = job.Schedule.ScheduleId == Guid.Empty ? Guid.NewGuid() : job.Schedule.ScheduleId;
            var nextRun = job.Schedule.NextRunUtc ?? DateTime.UtcNow.AddMinutes(job.Schedule.IntervalMinutes);
            await using var cmd = new SqlCommand("""
                INSERT INTO jobs.JobSchedule
                    (ScheduleId, JobId, FrequencyCode, IntervalMinutes, CronExpression, NextRunUtc, IsActive)
                VALUES
                    (@ScheduleId, @JobId, @FrequencyCode, @IntervalMinutes, @CronExpression, @NextRunUtc, @IsActive);
                """, conn, tx);
            cmd.Parameters.AddWithValue("@ScheduleId", scheduleId);
            cmd.Parameters.AddWithValue("@JobId", jobId);
            cmd.Parameters.AddWithValue("@FrequencyCode", job.Schedule.FrequencyCode);
            cmd.Parameters.AddWithValue("@IntervalMinutes", job.Schedule.IntervalMinutes);
            cmd.Parameters.AddNullable("@CronExpression", job.Schedule.CronExpression);
            cmd.Parameters.AddWithValue("@NextRunUtc", nextRun);
            cmd.Parameters.AddWithValue("@IsActive", job.Schedule.IsActive);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
        return jobId;
    }

    public async Task UpdateAsync(ProcessingJob job, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var tx = conn.BeginTransaction();

        await using (var cmd = new SqlCommand("""
            UPDATE jobs.ProcessingJob
            SET JobName = @JobName, Description = @Description, IsEnabled = @IsEnabled,
                MaxRetries = @MaxRetries, RetryDelaySeconds = @RetryDelaySeconds, ModifiedUtc = SYSUTCDATETIME()
            WHERE JobId = @JobId;
            """, conn, tx))
        {
            cmd.Parameters.AddWithValue("@JobId", job.JobId);
            cmd.Parameters.AddWithValue("@JobName", job.JobName);
            cmd.Parameters.AddNullable("@Description", job.Description);
            cmd.Parameters.AddWithValue("@IsEnabled", job.IsEnabled);
            cmd.Parameters.AddWithValue("@MaxRetries", job.MaxRetries);
            cmd.Parameters.AddWithValue("@RetryDelaySeconds", job.RetryDelaySeconds);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        if (job.Schedule is not null)
        {
            await using var cmd = new SqlCommand("""
                MERGE jobs.JobSchedule AS t
                USING (SELECT @JobId AS JobId) AS s ON t.JobId = s.JobId
                WHEN MATCHED THEN UPDATE SET
                    FrequencyCode = @FrequencyCode, IntervalMinutes = @IntervalMinutes,
                    CronExpression = @CronExpression, IsActive = @IsActive,
                    NextRunUtc = COALESCE(t.NextRunUtc, SYSUTCDATETIME())
                WHEN NOT MATCHED THEN INSERT
                    (ScheduleId, JobId, FrequencyCode, IntervalMinutes, CronExpression, NextRunUtc, IsActive)
                VALUES
                    (NEWID(), @JobId, @FrequencyCode, @IntervalMinutes, @CronExpression, SYSUTCDATETIME(), @IsActive);
                """, conn, tx);
            cmd.Parameters.AddWithValue("@JobId", job.JobId);
            cmd.Parameters.AddWithValue("@FrequencyCode", job.Schedule.FrequencyCode);
            cmd.Parameters.AddWithValue("@IntervalMinutes", job.Schedule.IntervalMinutes);
            cmd.Parameters.AddNullable("@CronExpression", job.Schedule.CronExpression);
            cmd.Parameters.AddWithValue("@IsActive", job.Schedule.IsActive);
            await cmd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);
    }

    public async Task<IReadOnlyList<ProcessingJob>> GetDueJobsAsync(DateTime asOfUtc, CancellationToken ct = default)
    {
        const string sql = """
            SELECT j.JobId, j.JobName, j.Description, j.DataSourceId, j.JobType, j.IsEnabled,
                   j.MaxRetries, j.RetryDelaySeconds, j.CreatedUtc, j.ModifiedUtc,
                   s.ScheduleId, s.FrequencyCode, s.IntervalMinutes, s.CronExpression,
                   s.NextRunUtc, s.LastRunUtc, s.IsActive
            FROM jobs.ProcessingJob j
            INNER JOIN jobs.JobSchedule s ON s.JobId = j.JobId
            WHERE j.IsEnabled = 1 AND s.IsActive = 1
              AND s.NextRunUtc IS NOT NULL AND s.NextRunUtc <= @AsOfUtc;
            """;
        return await ReadJobsAsync(sql, cmd => cmd.Parameters.AddWithValue("@AsOfUtc", asOfUtc), ct);
    }

    public async Task UpdateScheduleAfterRunAsync(Guid jobId, DateTime lastRunUtc, DateTime nextRunUtc, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand("EXEC jobs.usp_MarkJobScheduleRun @JobId, @LastRunUtc, @NextRunUtc;", conn);
        cmd.Parameters.AddWithValue("@JobId", jobId);
        cmd.Parameters.AddWithValue("@LastRunUtc", lastRunUtc);
        cmd.Parameters.AddWithValue("@NextRunUtc", nextRunUtc);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<Guid> CreateExecutionAsync(JobExecution execution, CancellationToken ct = default)
    {
        var id = execution.ExecutionId == Guid.Empty ? Guid.NewGuid() : execution.ExecutionId;
        const string sql = """
            INSERT INTO jobs.JobExecution
                (ExecutionId, JobId, TriggerType, Status, StartedUtc, CompletedUtc, ErrorMessage, AttemptNumber)
            VALUES
                (@ExecutionId, @JobId, @TriggerType, @Status, @StartedUtc, @CompletedUtc, @ErrorMessage, @AttemptNumber);
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@ExecutionId", id);
        cmd.Parameters.AddWithValue("@JobId", execution.JobId);
        cmd.Parameters.AddWithValue("@TriggerType", execution.TriggerType.ToString());
        cmd.Parameters.AddWithValue("@Status", execution.Status.ToString());
        cmd.Parameters.AddWithValue("@StartedUtc", execution.StartedUtc);
        cmd.Parameters.AddNullable("@CompletedUtc", execution.CompletedUtc);
        cmd.Parameters.AddNullable("@ErrorMessage", execution.ErrorMessage);
        cmd.Parameters.AddWithValue("@AttemptNumber", execution.AttemptNumber);
        await cmd.ExecuteNonQueryAsync(ct);
        return id;
    }

    public async Task UpdateExecutionAsync(JobExecution execution, CancellationToken ct = default)
    {
        const string sql = """
            UPDATE jobs.JobExecution
            SET Status = @Status, CompletedUtc = @CompletedUtc, ErrorMessage = @ErrorMessage, AttemptNumber = @AttemptNumber
            WHERE ExecutionId = @ExecutionId;
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@ExecutionId", execution.ExecutionId);
        cmd.Parameters.AddWithValue("@Status", execution.Status.ToString());
        cmd.Parameters.AddNullable("@CompletedUtc", execution.CompletedUtc);
        cmd.Parameters.AddNullable("@ErrorMessage", execution.ErrorMessage);
        cmd.Parameters.AddWithValue("@AttemptNumber", execution.AttemptNumber);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task AddExecutionLogAsync(Guid executionId, string level, string message, CancellationToken ct = default)
    {
        const string sql = """
            INSERT INTO jobs.JobExecutionLog (ExecutionId, Level, Message)
            VALUES (@ExecutionId, @Level, @Message);
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@ExecutionId", executionId);
        cmd.Parameters.AddWithValue("@Level", level);
        cmd.Parameters.AddWithValue("@Message", message);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IReadOnlyList<JobExecution>> GetExecutionsAsync(Guid jobId, int take = 50, CancellationToken ct = default)
    {
        const string sql = """
            SELECT TOP (@Take) ExecutionId, JobId, TriggerType, Status, StartedUtc, CompletedUtc, ErrorMessage, AttemptNumber
            FROM jobs.JobExecution
            WHERE JobId = @JobId
            ORDER BY StartedUtc DESC;
            """;
        var list = new List<JobExecution>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@JobId", jobId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapExecution(reader));
        return list;
    }

    public async Task AddRetryAttemptAsync(JobRetryAttempt attempt, CancellationToken ct = default)
    {
        const string sql = """
            INSERT INTO jobs.JobRetryAttempt
                (ExecutionId, JobId, AttemptNumber, ScheduledUtc, ExecutedUtc, Outcome, ErrorMessage)
            VALUES
                (@ExecutionId, @JobId, @AttemptNumber, @ScheduledUtc, @ExecutedUtc, @Outcome, @ErrorMessage);
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@ExecutionId", attempt.ExecutionId);
        cmd.Parameters.AddWithValue("@JobId", attempt.JobId);
        cmd.Parameters.AddWithValue("@AttemptNumber", attempt.AttemptNumber);
        cmd.Parameters.AddWithValue("@ScheduledUtc", attempt.ScheduledUtc);
        cmd.Parameters.AddNullable("@ExecutedUtc", attempt.ExecutedUtc);
        cmd.Parameters.AddWithValue("@Outcome", attempt.Outcome);
        cmd.Parameters.AddNullable("@ErrorMessage", attempt.ErrorMessage);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<JobExecution?> GetExecutionByIdAsync(Guid executionId, CancellationToken ct = default)
    {
        const string sql = """
            SELECT ExecutionId, JobId, TriggerType, Status, StartedUtc, CompletedUtc, ErrorMessage, AttemptNumber
            FROM jobs.JobExecution WHERE ExecutionId = @ExecutionId;
            """;
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@ExecutionId", executionId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return null;
        return MapExecution(reader);
    }

    private async Task<IReadOnlyList<ProcessingJob>> ReadJobsAsync(string sql, Action<SqlCommand>? configure, CancellationToken ct)
    {
        var list = new List<ProcessingJob>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        configure?.Invoke(cmd);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapJob(reader));
        return list;
    }

    private static ProcessingJob MapJob(SqlDataReader reader)
    {
        var job = new ProcessingJob
        {
            JobId = reader.GetGuid("JobId"),
            JobName = reader.GetString("JobName"),
            Description = reader.GetNullableString("Description"),
            DataSourceId = reader.GetGuid("DataSourceId"),
            JobType = Enum.Parse<ProcessingJobType>(reader.GetString("JobType")),
            IsEnabled = reader.GetBoolean("IsEnabled"),
            MaxRetries = reader.GetInt32("MaxRetries"),
            RetryDelaySeconds = reader.GetInt32("RetryDelaySeconds"),
            CreatedUtc = reader.GetDateTime("CreatedUtc"),
            ModifiedUtc = reader.GetDateTime("ModifiedUtc")
        };

        if (!reader.IsDBNull(reader.GetOrdinal("ScheduleId")))
        {
            job.Schedule = new JobSchedule
            {
                ScheduleId = reader.GetGuid("ScheduleId"),
                JobId = job.JobId,
                FrequencyCode = reader.GetString("FrequencyCode"),
                IntervalMinutes = reader.GetInt32("IntervalMinutes"),
                CronExpression = reader.GetNullableString("CronExpression"),
                NextRunUtc = reader.GetNullableDateTime("NextRunUtc"),
                LastRunUtc = reader.GetNullableDateTime("LastRunUtc"),
                IsActive = reader.GetBoolean("IsActive")
            };
        }

        return job;
    }

    private static JobExecution MapExecution(SqlDataReader reader) => new()
    {
        ExecutionId = reader.GetGuid("ExecutionId"),
        JobId = reader.GetGuid("JobId"),
        TriggerType = Enum.Parse<JobTriggerType>(reader.GetString("TriggerType")),
        Status = Enum.Parse<JobExecutionStatus>(reader.GetString("Status")),
        StartedUtc = reader.GetDateTime("StartedUtc"),
        CompletedUtc = reader.GetNullableDateTime("CompletedUtc"),
        ErrorMessage = reader.GetNullableString("ErrorMessage"),
        AttemptNumber = reader.GetInt32("AttemptNumber")
    };
}
