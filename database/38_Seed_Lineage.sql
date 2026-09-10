-- ============================================================
-- 38_Seed_Lineage.sql
-- Demo multi-hop lineage graph, sync from platform history,
-- circular-detection sample, scheduled jobs.
-- ============================================================
USE EDIP;
GO

DECLARE @WsId UNIQUEIDENTIFIER =
    (SELECT TOP (1) WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = N'WS-SALES');
IF @WsId IS NULL
    SELECT TOP (1) @WsId = WorkspaceId FROM analytics.Workspace ORDER BY WorkspaceCode;
DECLARE @SampleCsv UNIQUEIDENTIFIER =
    (SELECT TOP (1) DataSourceId FROM reg.DataSource WHERE IsDeleted = 0 ORDER BY CreatedUtc);

-- Ensure CUSTOMER dataset entity + analytics assets via sync
EXEC lineage.usp_SyncPlatformLineage @CreatedBy = N'seed', @MaxBatches = 50;

-- Multi-level demo graph for upstream/downstream/impact tests
DECLARE @SrcA UNIQUEIDENTIFIER, @DsA UNIQUEIDENTIFIER, @DsB UNIQUEIDENTIFIER, @DsC UNIQUEIDENTIFIER, @RepX UNIQUEIDENTIFIER;
DECLARE @RelId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);

EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'DataSource', @EntityCode=N'DEMO_SOURCE_A', @DisplayName=N'Demo Source A',
    @WorkspaceId=@WsId, @EntityId=@SrcA OUTPUT;
EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'Dataset', @EntityCode=N'DEMO_DATASET_A', @DisplayName=N'Demo Dataset A',
    @WorkspaceId=@WsId, @EntityId=@DsA OUTPUT;
EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'Dataset', @EntityCode=N'DEMO_DATASET_B', @DisplayName=N'Demo Dataset B',
    @WorkspaceId=@WsId, @EntityId=@DsB OUTPUT;
EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'Dataset', @EntityCode=N'DEMO_DATASET_C', @DisplayName=N'Demo Dataset C',
    @WorkspaceId=@WsId, @EntityId=@DsC OUTPUT;
EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'Report', @EntityCode=N'DEMO_REPORT_X', @DisplayName=N'Demo Report X',
    @WorkspaceId=@WsId, @EntityId=@RepX OUTPUT;

-- Ensure demo chain edges (idempotent Created/Exists)
SET @RelId = NULL; SET @Code = NULL; SET @Msg = NULL;
EXEC lineage.usp_AddRelationship @SourceEntityId=@SrcA, @TargetEntityId=@DsA, @RelationshipType=N'Feeds',
    @WorkspaceId=@WsId, @ProcessType=N'Manual', @CreatedBy=N'seed', @ProcessReference=N'demo-seed-1',
    @RelationshipId=@RelId OUTPUT, @StatusCode=@Code OUTPUT, @StatusMessage=@Msg OUTPUT;
SET @RelId = NULL; SET @Code = NULL; SET @Msg = NULL;
EXEC lineage.usp_AddRelationship @SourceEntityId=@DsA, @TargetEntityId=@DsB, @RelationshipType=N'DerivedFrom',
    @WorkspaceId=@WsId, @ProcessType=N'Manual', @CreatedBy=N'seed', @ProcessReference=N'demo-seed-2',
    @RelationshipId=@RelId OUTPUT, @StatusCode=@Code OUTPUT, @StatusMessage=@Msg OUTPUT;
SET @RelId = NULL; SET @Code = NULL; SET @Msg = NULL;
EXEC lineage.usp_AddRelationship @SourceEntityId=@DsB, @TargetEntityId=@DsC, @RelationshipType=N'DerivedFrom',
    @WorkspaceId=@WsId, @ProcessType=N'Manual', @CreatedBy=N'seed', @ProcessReference=N'demo-seed-3',
    @RelationshipId=@RelId OUTPUT, @StatusCode=@Code OUTPUT, @StatusMessage=@Msg OUTPUT;
SET @RelId = NULL; SET @Code = NULL; SET @Msg = NULL;
EXEC lineage.usp_AddRelationship @SourceEntityId=@DsC, @TargetEntityId=@RepX, @RelationshipType=N'ReportsOn',
    @WorkspaceId=@WsId, @ProcessType=N'Manual', @CreatedBy=N'seed', @ProcessReference=N'demo-seed-4',
    @RelationshipId=@RelId OUTPUT, @StatusCode=@Code OUTPUT, @StatusMessage=@Msg OUTPUT;

-- Attempt circular edge C -> A (should be rejected)
SET @RelId = NULL; SET @Code = NULL; SET @Msg = NULL;
EXEC lineage.usp_AddRelationship @SourceEntityId=@DsC, @TargetEntityId=@DsA, @RelationshipType=N'DependsOn',
    @WorkspaceId=@WsId, @ProcessType=N'Manual', @CreatedBy=N'seed', @PreventCycles=1, @ProcessReference=N'demo-cycle',
    @RelationshipId=@RelId OUTPUT, @StatusCode=@Code OUTPUT, @StatusMessage=@Msg OUTPUT;

PRINT CONCAT('Circular insert status (expected CycleRejected): ', ISNULL(@Code,N'?'), ' - ', ISNULL(@Msg,N''));

DECLARE @WsOther UNIQUEIDENTIFIER =
    (SELECT TOP (1) WorkspaceId FROM analytics.Workspace WHERE WorkspaceId <> @WsId ORDER BY WorkspaceCode);

IF @WsOther IS NOT NULL
BEGIN
    DECLARE @OtherDs UNIQUEIDENTIFIER, @OtherRep UNIQUEIDENTIFIER;
    EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'Dataset', @EntityCode=N'OTHER_WS_DATASET', @DisplayName=N'Other Workspace Dataset',
        @WorkspaceId=@WsOther, @EntityId=@OtherDs OUTPUT;
    EXEC lineage.usp_EnsureEntity @EntityTypeCode=N'Report', @EntityCode=N'OTHER_WS_REPORT', @DisplayName=N'Other Workspace Report',
        @WorkspaceId=@WsOther, @EntityId=@OtherRep OUTPUT;
    EXEC lineage.usp_AddRelationship @SourceEntityId=@OtherDs, @TargetEntityId=@OtherRep, @RelationshipType=N'ReportsOn',
        @WorkspaceId=@WsOther, @ProcessType=N'Manual', @CreatedBy=N'seed',
        @RelationshipId=@RelId OUTPUT, @StatusCode=@Code OUTPUT, @StatusMessage=@Msg OUTPUT;
END

IF @SampleCsv IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobName = N'Sync Platform Lineage')
    BEGIN
        DECLARE @JobId UNIQUEIDENTIFIER = NEWID();
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@JobId, N'Sync Platform Lineage',
                N'Rebuild lineage edges from recent imports, ETL runs, and profile runs.',
                @SampleCsv, N'SyncPlatformLineage', 1, 2, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @JobId, N'Hourly', 60, DATEADD(MINUTE, 15, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobName = N'Archive Lineage History')
    BEGIN
        DECLARE @JobId2 UNIQUEIDENTIFIER = NEWID();
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@JobId2, N'Archive Lineage History',
                N'Purge old lineage capture logs (relationships retained).',
                @SampleCsv, N'ArchiveLineageHistory', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @JobId2, N'Daily', 1440, DATEADD(DAY, 1, SYSUTCDATETIME()), 1);
    END
END
GO

PRINT 'Lineage seed complete.';
GO
