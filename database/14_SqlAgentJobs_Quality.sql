-- ============================================================
-- 14_SqlAgentJobs_Quality.sql
-- Additional Agent jobs for profiling / sync / archive
-- Update @WorkerPath before running.
-- ============================================================
USE msdb;
GO

DECLARE @WorkerPath NVARCHAR(500) = N'C:\Edip\Edip.Worker\Edip.Worker.exe';

DECLARE @Jobs TABLE (JobName SYSNAME, Args NVARCHAR(200), ScheduleName SYSNAME, IntervalMinutes INT);
INSERT INTO @Jobs VALUES
    (N'EDIP_ScheduledProfiling', N'--due', N'EDIP_DQ_Every15Min', 15),
    (N'EDIP_ArchiveProfilingHistory', N'--jobId 22222222-2222-2222-2222-222222222222', N'EDIP_DQ_DailyArchive', 1440);

DECLARE @JobName SYSNAME, @Args NVARCHAR(200), @ScheduleName SYSNAME, @Interval INT;
DECLARE @StepCommand NVARCHAR(1000), @JobId UNIQUEIDENTIFIER;

DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT JobName, Args, ScheduleName, IntervalMinutes FROM @Jobs;
OPEN c;
FETCH NEXT FROM c INTO @JobName, @Args, @ScheduleName, @Interval;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
        EXEC msdb.dbo.sp_delete_job @job_name = @JobName;

    SET @StepCommand = N'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ''' + @WorkerPath + ''' ' + @Args + '"';
    SET @JobId = NULL;

    EXEC msdb.dbo.sp_add_job
        @job_name = @JobName,
        @enabled = 1,
        @description = N'EDIP data quality automation',
        @owner_login_name = N'sa',
        @job_id = @JobId OUTPUT;

    EXEC msdb.dbo.sp_add_jobstep
        @job_id = @JobId,
        @step_name = N'Run Edip.Worker',
        @subsystem = N'CmdExec',
        @command = @StepCommand,
        @on_success_action = 1,
        @on_fail_action = 2;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = @ScheduleName)
    BEGIN
        EXEC msdb.dbo.sp_add_schedule
            @schedule_name = @ScheduleName,
            @freq_type = 4,
            @freq_interval = 1,
            @freq_subday_type = 4,
            @freq_subday_interval = CASE WHEN @Interval < 1440 THEN @Interval ELSE 60 END,
            @active_start_time = 10000;
    END

    EXEC msdb.dbo.sp_attach_schedule @job_name = @JobName, @schedule_name = @ScheduleName;
    EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName, @server_name = N'(LOCAL)';

    FETCH NEXT FROM c INTO @JobName, @Args, @ScheduleName, @Interval;
END
CLOSE c; DEALLOCATE c;

PRINT 'EDIP quality Agent jobs created. Primary due-job polling remains EDIP_ProcessDueJobs.';
GO
