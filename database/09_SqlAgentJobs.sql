-- ============================================================
-- 09_SqlAgentJobs.sql
-- Creates SQL Server Agent job that invokes Edip.Worker --due
-- Update @WorkerPath before running in your environment.
-- Requires SQL Server Agent service to be running.
-- ============================================================
USE msdb;
GO

DECLARE @WorkerPath NVARCHAR(500) = N'C:\Edip\Edip.Worker\Edip.Worker.exe';
DECLARE @JobName SYSNAME = N'EDIP_ProcessDueJobs';
DECLARE @StepCommand NVARCHAR(1000);

SET @StepCommand = N'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ''' + @WorkerPath + ''' --due"';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName;
END
GO

-- Recreate variables after GO
DECLARE @WorkerPath NVARCHAR(500) = N'C:\Edip\Edip.Worker\Edip.Worker.exe';
DECLARE @JobName SYSNAME = N'EDIP_ProcessDueJobs';
DECLARE @StepCommand NVARCHAR(1000) =
    N'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& ''' + @WorkerPath + ''' --due"';
DECLARE @JobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = @JobName,
    @enabled = 1,
    @description = N'EDIP: process due data-processing jobs via Edip.Worker',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Run Edip.Worker --due',
    @subsystem = N'CmdExec',
    @command = @StepCommand,
    @retry_attempts = 1,
    @retry_interval = 1,
    @on_success_action = 1,
    @on_fail_action = 2;

EXEC msdb.dbo.sp_add_schedule
    @schedule_name = N'EDIP_Every5Minutes',
    @freq_type = 4,          -- daily
    @freq_interval = 1,
    @freq_subday_type = 4,   -- minutes
    @freq_subday_interval = 5,
    @active_start_time = 0;

EXEC msdb.dbo.sp_attach_schedule
    @job_name = @JobName,
    @schedule_name = N'EDIP_Every5Minutes';

EXEC msdb.dbo.sp_add_jobserver
    @job_name = @JobName,
    @server_name = N'(LOCAL)';

PRINT 'SQL Server Agent job EDIP_ProcessDueJobs created (every 5 minutes).';
PRINT 'Update Worker path in this script if your publish folder differs.';
GO
