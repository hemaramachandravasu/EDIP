-- ============================================================
-- 36_Procs_Lineage.sql
-- Ensure entity, record relationships, recursive upstream/
-- downstream, impact analysis, version queries, circular
-- detection, platform sync, and lineage analytics.
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER PROCEDURE lineage.usp_EnsureEntity
    @EntityTypeCode   NVARCHAR(32),
    @EntityCode       NVARCHAR(128),
    @DisplayName      NVARCHAR(200),
    @ExternalKey      UNIQUEIDENTIFIER = NULL,
    @WorkspaceId      UNIQUEIDENTIFIER = NULL,
    @DatasetId        UNIQUEIDENTIFIER = NULL,
    @VersionNumber    INT = NULL,
    @MetadataJson     NVARCHAR(MAX) = NULL,
    @EntityId         UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM lineage.EntityType WHERE EntityTypeCode = @EntityTypeCode)
        THROW 50001, 'Unknown lineage entity type.', 1;

    IF @ExternalKey IS NOT NULL
    BEGIN
        SELECT @EntityId = EntityId
        FROM lineage.LineageEntity
        WHERE EntityTypeCode = @EntityTypeCode AND ExternalKey = @ExternalKey;

        IF @EntityId IS NOT NULL
        BEGIN
            UPDATE lineage.LineageEntity
            SET DisplayName = @DisplayName,
                WorkspaceId = COALESCE(@WorkspaceId, WorkspaceId),
                DatasetId = COALESCE(@DatasetId, DatasetId),
                VersionNumber = COALESCE(@VersionNumber, VersionNumber),
                MetadataJson = COALESCE(@MetadataJson, MetadataJson),
                ModifiedUtc = SYSUTCDATETIME(),
                IsActive = 1
            WHERE EntityId = @EntityId;
            RETURN;
        END
    END

    SELECT @EntityId = EntityId
    FROM lineage.LineageEntity
    WHERE EntityTypeCode = @EntityTypeCode
      AND EntityCode = @EntityCode
      AND ((WorkspaceId IS NULL AND @WorkspaceId IS NULL) OR WorkspaceId = @WorkspaceId);

    IF @EntityId IS NOT NULL
    BEGIN
        UPDATE lineage.LineageEntity
        SET DisplayName = @DisplayName,
            ExternalKey = COALESCE(@ExternalKey, ExternalKey),
            DatasetId = COALESCE(@DatasetId, DatasetId),
            VersionNumber = COALESCE(@VersionNumber, VersionNumber),
            MetadataJson = COALESCE(@MetadataJson, MetadataJson),
            ModifiedUtc = SYSUTCDATETIME(),
            IsActive = 1
        WHERE EntityId = @EntityId;
        RETURN;
    END

    SET @EntityId = NEWID();
    INSERT INTO lineage.LineageEntity
        (EntityId, EntityTypeCode, ExternalKey, EntityCode, DisplayName,
         WorkspaceId, DatasetId, VersionNumber, MetadataJson)
    VALUES
        (@EntityId, @EntityTypeCode, @ExternalKey, @EntityCode, @DisplayName,
         @WorkspaceId, @DatasetId, @VersionNumber, @MetadataJson);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_WouldCreateCycle
    @SourceEntityId UNIQUEIDENTIFIER,
    @TargetEntityId UNIQUEIDENTIFIER,
    @MaxDepth       INT = 50,
    @WouldCycle     BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @WouldCycle = 0;

    IF @SourceEntityId = @TargetEntityId
    BEGIN
        SET @WouldCycle = 1;
        RETURN;
    END

    ;WITH walk AS
    (
        SELECT r.TargetEntityId AS EntityId, 1 AS Depth
        FROM lineage.LineageRelationship r
        WHERE r.SourceEntityId = @TargetEntityId AND r.IsActive = 1

        UNION ALL

        SELECT r.TargetEntityId, w.Depth + 1
        FROM walk w
        INNER JOIN lineage.LineageRelationship r
            ON r.SourceEntityId = w.EntityId AND r.IsActive = 1
        WHERE w.Depth < @MaxDepth
          AND w.EntityId <> @SourceEntityId
    )
    SELECT TOP (1) @WouldCycle = 1
    FROM walk
    WHERE EntityId = @SourceEntityId
    OPTION (MAXRECURSION 100);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_AddRelationship
    @SourceEntityId    UNIQUEIDENTIFIER,
    @TargetEntityId    UNIQUEIDENTIFIER,
    @RelationshipType  NVARCHAR(64),
    @WorkspaceId       UNIQUEIDENTIFIER = NULL,
    @SourceVersionId   UNIQUEIDENTIFIER = NULL,
    @TargetVersionId   UNIQUEIDENTIFIER = NULL,
    @ProcessReference  NVARCHAR(64) = NULL,
    @ProcessType       NVARCHAR(32) = NULL,
    @CreatedBy         NVARCHAR(128) = N'system',
    @PreventCycles     BIT = 1,
    @RelationshipId    UNIQUEIDENTIFIER = NULL OUTPUT,
    @StatusCode        NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage     NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Created';
    SET @StatusMessage = N'Relationship created.';

    IF @SourceEntityId = @TargetEntityId
    BEGIN
        SET @StatusCode = N'CycleRejected';
        SET @StatusMessage = N'Source and target cannot be the same entity.';
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM lineage.LineageEntity WHERE EntityId = @SourceEntityId AND IsActive = 1)
       OR NOT EXISTS (SELECT 1 FROM lineage.LineageEntity WHERE EntityId = @TargetEntityId AND IsActive = 1)
    BEGIN
        SET @StatusCode = N'InvalidEntity';
        SET @StatusMessage = N'Source or target entity not found / inactive.';
        RETURN;
    END

    IF @PreventCycles = 1
    BEGIN
        DECLARE @WouldCycle BIT = 0;
        EXEC lineage.usp_WouldCreateCycle
            @SourceEntityId = @SourceEntityId,
            @TargetEntityId = @TargetEntityId,
            @WouldCycle = @WouldCycle OUTPUT;

        IF @WouldCycle = 1
        BEGIN
            SET @StatusCode = N'CycleRejected';
            SET @StatusMessage = N'Adding this relationship would create a circular dependency.';
            RETURN;
        END
    END

    SELECT @RelationshipId = RelationshipId
    FROM lineage.LineageRelationship
    WHERE SourceEntityId = @SourceEntityId
      AND TargetEntityId = @TargetEntityId
      AND RelationshipType = @RelationshipType
      AND ((SourceVersionId IS NULL AND @SourceVersionId IS NULL) OR SourceVersionId = @SourceVersionId)
      AND ((TargetVersionId IS NULL AND @TargetVersionId IS NULL) OR TargetVersionId = @TargetVersionId)
      AND ((ProcessReference IS NULL AND @ProcessReference IS NULL) OR ProcessReference = @ProcessReference)
      AND IsActive = 1;

    IF @RelationshipId IS NOT NULL
    BEGIN
        SET @StatusCode = N'Exists';
        SET @StatusMessage = N'Relationship already exists.';
        RETURN;
    END

    SET @RelationshipId = NEWID();
    INSERT INTO lineage.LineageRelationship
        (RelationshipId, SourceEntityId, TargetEntityId, RelationshipType, WorkspaceId,
         SourceVersionId, TargetVersionId, ProcessReference, ProcessType, CreatedBy)
    VALUES
        (@RelationshipId, @SourceEntityId, @TargetEntityId, @RelationshipType, @WorkspaceId,
         @SourceVersionId, @TargetVersionId, @ProcessReference, @ProcessType, @CreatedBy);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_RegisterDatasetVersion
    @DatasetId         UNIQUEIDENTIFIER,
    @ImportBatchId     UNIQUEIDENTIFIER = NULL,
    @ImportId          UNIQUEIDENTIFIER = NULL,
    @EtlRunId          UNIQUEIDENTIFIER = NULL,
    @ProfileRunId      UNIQUEIDENTIFIER = NULL,
    @DataSourceId      UNIQUEIDENTIFIER = NULL,
    @ProducedBy        NVARCHAR(128) = N'system',
    @Notes             NVARCHAR(1000) = NULL,
    @DatasetVersionId  UNIQUEIDENTIFIER = NULL OUTPUT,
    @VersionNumber     INT = NULL OUTPUT,
    @EntityId          UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @WorkspaceId UNIQUEIDENTIFIER;
    DECLARE @DatasetCode NVARCHAR(64);
    DECLARE @DisplayName NVARCHAR(200);

    SELECT @WorkspaceId = WorkspaceId, @DatasetCode = DatasetCode, @DisplayName = DisplayName
    FROM ingest.Dataset WHERE DatasetId = @DatasetId;

    IF @DatasetCode IS NULL
        THROW 50002, 'Dataset not found.', 1;

    IF @ImportBatchId IS NOT NULL
    BEGIN
        SELECT @DatasetVersionId = DatasetVersionId,
               @VersionNumber = VersionNumber,
               @EntityId = EntityId
        FROM lineage.DatasetVersion
        WHERE DatasetId = @DatasetId AND ImportBatchId = @ImportBatchId;

        IF @DatasetVersionId IS NOT NULL
            RETURN;
    END

    SELECT @VersionNumber = ISNULL(MAX(VersionNumber), 0) + 1
    FROM lineage.DatasetVersion
    WHERE DatasetId = @DatasetId;

    DECLARE @EntityCode NVARCHAR(128) = CONCAT(@DatasetCode, N'.v', @VersionNumber);

    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'DatasetVersion',
        @EntityCode = @EntityCode,
        @DisplayName = @DisplayName,
        @WorkspaceId = @WorkspaceId,
        @DatasetId = @DatasetId,
        @VersionNumber = @VersionNumber,
        @EntityId = @EntityId OUTPUT;

    UPDATE lineage.LineageEntity
    SET DisplayName = CONCAT(@DisplayName, N' v', @VersionNumber),
        VersionNumber = @VersionNumber,
        ModifiedUtc = SYSUTCDATETIME()
    WHERE EntityId = @EntityId;

    SET @DatasetVersionId = NEWID();
    INSERT INTO lineage.DatasetVersion
        (DatasetVersionId, DatasetId, VersionNumber, EntityId, WorkspaceId,
         ImportBatchId, ImportId, EtlRunId, ProfileRunId, DataSourceId, ProducedBy, Notes)
    VALUES
        (@DatasetVersionId, @DatasetId, @VersionNumber, @EntityId, @WorkspaceId,
         @ImportBatchId, @ImportId, @EtlRunId, @ProfileRunId, @DataSourceId, @ProducedBy, @Notes);
END
GO

-- === LINEAGE_PROCS_PART2 ===

CREATE OR ALTER PROCEDURE lineage.usp_RecordImportLineage
    @BatchId            UNIQUEIDENTIFIER,
    @CreatedBy          NVARCHAR(128) = N'system',
    @RelationshipsAdded INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RelationshipsAdded = 0;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @DataSourceId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER, @DatasetCode NVARCHAR(64), @DisplayName NVARCHAR(200);
    DECLARE @Status NVARCHAR(32);

    SELECT @DatasetId = b.DatasetId, @DataSourceId = b.DataSourceId,
           @ImportId = b.ImportId, @Status = b.Status
    FROM ingest.ImportBatch b
    WHERE b.BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50003, 'Import batch not found.', 1;

    SELECT @WorkspaceId = WorkspaceId, @DatasetCode = DatasetCode, @DisplayName = DisplayName
    FROM ingest.Dataset WHERE DatasetId = @DatasetId;

    DECLARE @DsEntityId UNIQUEIDENTIFIER, @ImpEntityId UNIQUEIDENTIFIER, @DsSetEntityId UNIQUEIDENTIFIER;
    DECLARE @VerId UNIQUEIDENTIFIER, @VerNum INT, @VerEntityId UNIQUEIDENTIFIER;
    DECLARE @RelId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);

    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'Dataset', @EntityCode = @DatasetCode, @DisplayName = @DisplayName,
        @ExternalKey = @DatasetId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @DsSetEntityId OUTPUT;

    DECLARE @ImpCode NVARCHAR(128) = CONCAT(N'IMP-', CONVERT(NVARCHAR(36), @BatchId));
    DECLARE @ImpName NVARCHAR(200) = CONCAT(N'Import ', @DatasetCode);
    DECLARE @ProcRef NVARCHAR(64) = CONVERT(NVARCHAR(64), ISNULL(@ImportId, @BatchId));
    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'Import', @EntityCode = @ImpCode,
        @DisplayName = @ImpName,
        @ExternalKey = @BatchId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @ImpEntityId OUTPUT;

    IF @DataSourceId IS NOT NULL
    BEGIN
        DECLARE @SrcCode NVARCHAR(128), @SrcName NVARCHAR(200);
        SELECT @SrcCode = Name, @SrcName = Name
        FROM reg.DataSource WHERE DataSourceId = @DataSourceId AND IsDeleted = 0;

        IF @SrcCode IS NOT NULL
        BEGIN
            EXEC lineage.usp_EnsureEntity
                @EntityTypeCode = N'DataSource', @EntityCode = @SrcCode, @DisplayName = @SrcName,
                @ExternalKey = @DataSourceId, @WorkspaceId = @WorkspaceId,
                @EntityId = @DsEntityId OUTPUT;

            EXEC lineage.usp_AddRelationship
                @SourceEntityId = @DsEntityId, @TargetEntityId = @ImpEntityId,
                @RelationshipType = N'Feeds', @WorkspaceId = @WorkspaceId,
                @ProcessReference = @ProcRef,
                @ProcessType = N'Import', @CreatedBy = @CreatedBy, @PreventCycles = 1,
                @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
            IF @Code = N'Created' SET @RelationshipsAdded += 1;
        END
    END

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @ImpEntityId, @TargetEntityId = @DsSetEntityId,
        @RelationshipType = N'ImportsInto', @WorkspaceId = @WorkspaceId,
        @ProcessReference = @ProcRef,
        @ProcessType = N'Import', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;

    IF @Status IN (N'Completed', N'CompletedWithErrors', N'Validated', N'Loaded')
    BEGIN
        EXEC lineage.usp_RegisterDatasetVersion
            @DatasetId = @DatasetId, @ImportBatchId = @BatchId, @ImportId = @ImportId,
            @DataSourceId = @DataSourceId, @ProducedBy = @CreatedBy,
            @Notes = N'Version from import batch',
            @DatasetVersionId = @VerId OUTPUT, @VersionNumber = @VerNum OUTPUT, @EntityId = @VerEntityId OUTPUT;

        EXEC lineage.usp_AddRelationship
            @SourceEntityId = @ImpEntityId, @TargetEntityId = @VerEntityId,
            @RelationshipType = N'Produces', @WorkspaceId = @WorkspaceId,
            @TargetVersionId = @VerId,
            @ProcessReference = @ProcRef,
            @ProcessType = N'Import', @CreatedBy = @CreatedBy, @PreventCycles = 1,
            @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
        IF @Code = N'Created' SET @RelationshipsAdded += 1;
    END
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_RecordEtlLineage
    @EtlRunId           UNIQUEIDENTIFIER,
    @CreatedBy          NVARCHAR(128) = N'system',
    @RelationshipsAdded INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RelationshipsAdded = 0;

    DECLARE @BatchId UNIQUEIDENTIFIER, @DatasetId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER, @DatasetCode NVARCHAR(64), @DisplayName NVARCHAR(200);

    SELECT @BatchId = r.BatchId
    FROM etl.EtlRun r
    WHERE r.RunId = @EtlRunId;

    IF @BatchId IS NULL
        THROW 50004, 'ETL run not found.', 1;

    SELECT @DatasetId = b.DatasetId, @ImportId = b.ImportId
    FROM ingest.ImportBatch b WHERE b.BatchId = @BatchId;

    SELECT @WorkspaceId = WorkspaceId, @DatasetCode = DatasetCode, @DisplayName = DisplayName
    FROM ingest.Dataset WHERE DatasetId = @DatasetId;

    DECLARE @DsEntityId UNIQUEIDENTIFIER, @XformEntityId UNIQUEIDENTIFIER;
    DECLARE @InVerId UNIQUEIDENTIFIER, @OutVerId UNIQUEIDENTIFIER;
    DECLARE @InVerEntity UNIQUEIDENTIFIER, @OutVerEntity UNIQUEIDENTIFIER;
    DECLARE @VerNum INT, @RelId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);

    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'Dataset', @EntityCode = @DatasetCode, @DisplayName = @DisplayName,
        @ExternalKey = @DatasetId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @DsEntityId OUTPUT;

    DECLARE @XCode NVARCHAR(128) = CONCAT(N'ETL-', CONVERT(NVARCHAR(36), @EtlRunId));
    DECLARE @XName NVARCHAR(200) = CONCAT(N'ETL ', @DatasetCode);
    DECLARE @EtlRef NVARCHAR(64) = CONVERT(NVARCHAR(64), @EtlRunId);
    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'Transformation', @EntityCode = @XCode,
        @DisplayName = @XName,
        @ExternalKey = @EtlRunId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @XformEntityId OUTPUT;

    SELECT TOP (1) @InVerId = DatasetVersionId, @InVerEntity = EntityId
    FROM lineage.DatasetVersion
    WHERE DatasetId = @DatasetId AND ImportBatchId = @BatchId
    ORDER BY VersionNumber DESC;

    IF @InVerId IS NULL
    BEGIN
        EXEC lineage.usp_RegisterDatasetVersion
            @DatasetId = @DatasetId, @ImportBatchId = @BatchId, @ImportId = @ImportId,
            @ProducedBy = @CreatedBy, @Notes = N'Pre-ETL version',
            @DatasetVersionId = @InVerId OUTPUT, @VersionNumber = @VerNum OUTPUT, @EntityId = @InVerEntity OUTPUT;
    END

    EXEC lineage.usp_RegisterDatasetVersion
        @DatasetId = @DatasetId, @ImportId = @ImportId, @EtlRunId = @EtlRunId,
        @ProducedBy = @CreatedBy, @Notes = N'Post-ETL curated version',
        @DatasetVersionId = @OutVerId OUTPUT, @VersionNumber = @VerNum OUTPUT, @EntityId = @OutVerEntity OUTPUT;

    UPDATE lineage.DatasetVersion SET EtlRunId = @EtlRunId WHERE DatasetVersionId = @OutVerId;

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @InVerEntity, @TargetEntityId = @XformEntityId,
        @RelationshipType = N'TransformsTo', @WorkspaceId = @WorkspaceId,
        @SourceVersionId = @InVerId,
        @ProcessReference = @EtlRef,
        @ProcessType = N'Etl', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @XformEntityId, @TargetEntityId = @OutVerEntity,
        @RelationshipType = N'Produces', @WorkspaceId = @WorkspaceId,
        @TargetVersionId = @OutVerId,
        @ProcessReference = @EtlRef,
        @ProcessType = N'Etl', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @InVerEntity, @TargetEntityId = @OutVerEntity,
        @RelationshipType = N'DerivedFrom', @WorkspaceId = @WorkspaceId,
        @SourceVersionId = @InVerId, @TargetVersionId = @OutVerId,
        @ProcessReference = @EtlRef,
        @ProcessType = N'Etl', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_RecordProfileLineage
    @ProfileRunId       UNIQUEIDENTIFIER,
    @CreatedBy          NVARCHAR(128) = N'system',
    @RelationshipsAdded INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RelationshipsAdded = 0;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @BatchId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER, @DatasetCode NVARCHAR(64), @DisplayName NVARCHAR(200);

    SELECT @DatasetId = pr.DatasetId, @BatchId = pr.BatchId, @ImportId = pr.ImportId
    FROM profile.ProfileRun pr
    WHERE pr.ProfileRunId = @ProfileRunId;

    IF @DatasetId IS NULL
        THROW 50005, 'Profile run not found.', 1;

    SELECT @WorkspaceId = WorkspaceId, @DatasetCode = DatasetCode, @DisplayName = DisplayName
    FROM ingest.Dataset WHERE DatasetId = @DatasetId;

    DECLARE @DsEntityId UNIQUEIDENTIFIER, @ProfEntityId UNIQUEIDENTIFIER;
    DECLARE @VerId UNIQUEIDENTIFIER, @VerEntity UNIQUEIDENTIFIER, @VerNum INT;
    DECLARE @RelId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);

    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'Dataset', @EntityCode = @DatasetCode, @DisplayName = @DisplayName,
        @ExternalKey = @DatasetId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @DsEntityId OUTPUT;

    DECLARE @PCode NVARCHAR(128) = CONCAT(N'PROF-', CONVERT(NVARCHAR(36), @ProfileRunId));
    DECLARE @PName NVARCHAR(200) = CONCAT(N'Profile ', @DatasetCode);
    DECLARE @ProfRef NVARCHAR(64) = CONVERT(NVARCHAR(64), @ProfileRunId);
    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'QualityProfileRun', @EntityCode = @PCode,
        @DisplayName = @PName,
        @ExternalKey = @ProfileRunId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @ProfEntityId OUTPUT;

    SELECT TOP (1) @VerId = DatasetVersionId, @VerEntity = EntityId
    FROM lineage.DatasetVersion
    WHERE DatasetId = @DatasetId
      AND (@BatchId IS NULL OR ImportBatchId = @BatchId)
    ORDER BY VersionNumber DESC;

    IF @VerId IS NULL
    BEGIN
        EXEC lineage.usp_RegisterDatasetVersion
            @DatasetId = @DatasetId, @ImportBatchId = @BatchId, @ImportId = @ImportId,
            @ProfileRunId = @ProfileRunId, @ProducedBy = @CreatedBy,
            @Notes = N'Version linked to profile run',
            @DatasetVersionId = @VerId OUTPUT, @VersionNumber = @VerNum OUTPUT, @EntityId = @VerEntity OUTPUT;
    END
    ELSE
        UPDATE lineage.DatasetVersion SET ProfileRunId = @ProfileRunId WHERE DatasetVersionId = @VerId;

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @VerEntity, @TargetEntityId = @ProfEntityId,
        @RelationshipType = N'Profiles', @WorkspaceId = @WorkspaceId,
        @SourceVersionId = @VerId,
        @ProcessReference = @ProfRef,
        @ProcessType = N'Profile', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @DsEntityId, @TargetEntityId = @ProfEntityId,
        @RelationshipType = N'Profiles', @WorkspaceId = @WorkspaceId,
        @ProcessReference = @ProfRef,
        @ProcessType = N'Profile', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_RecordAnalyticsLineage
    @DatasetCode        NVARCHAR(64),
    @AssetCode          NVARCHAR(128),
    @AssetDisplayName   NVARCHAR(200),
    @AssetType          NVARCHAR(32) = N'AnalyticsAsset',
    @CreatedBy          NVARCHAR(128) = N'system',
    @RelationshipsAdded INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @RelationshipsAdded = 0;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER, @DisplayName NVARCHAR(200);
    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId, @DisplayName = DisplayName
    FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;

    IF @DatasetId IS NULL
        THROW 50006, 'Dataset not found.', 1;

    IF @AssetType NOT IN (N'AnalyticsAsset', N'Report')
        SET @AssetType = N'AnalyticsAsset';

    DECLARE @DsEntityId UNIQUEIDENTIFIER, @AssetEntityId UNIQUEIDENTIFIER;
    DECLARE @RelId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);

    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = N'Dataset', @EntityCode = @DatasetCode, @DisplayName = @DisplayName,
        @ExternalKey = @DatasetId, @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @DsEntityId OUTPUT;

    EXEC lineage.usp_EnsureEntity
        @EntityTypeCode = @AssetType, @EntityCode = @AssetCode, @DisplayName = @AssetDisplayName,
        @WorkspaceId = @WorkspaceId, @DatasetId = @DatasetId,
        @EntityId = @AssetEntityId OUTPUT;

    EXEC lineage.usp_AddRelationship
        @SourceEntityId = @DsEntityId, @TargetEntityId = @AssetEntityId,
        @RelationshipType = N'ReportsOn', @WorkspaceId = @WorkspaceId,
        @ProcessType = N'Analytics', @CreatedBy = @CreatedBy, @PreventCycles = 1,
        @RelationshipId = @RelId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created' SET @RelationshipsAdded += 1;
END
GO

-- === LINEAGE_PROCS_PART3 ===

CREATE OR ALTER PROCEDURE lineage.usp_ResolveStartEntity
    @EntityId           UNIQUEIDENTIFIER = NULL,
    @DatasetCode        NVARCHAR(64) = NULL,
    @DatasetVersionId   UNIQUEIDENTIFIER = NULL,
    @VersionNumber      INT = NULL,
    @EntityTypeCode     NVARCHAR(32) = NULL,
    @ResolvedEntityId   UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ResolvedEntityId = NULL;

    IF @EntityId IS NOT NULL
    BEGIN
        SET @ResolvedEntityId = @EntityId;
        RETURN;
    END

    IF @DatasetVersionId IS NOT NULL
    BEGIN
        SELECT @ResolvedEntityId = EntityId FROM lineage.DatasetVersion WHERE DatasetVersionId = @DatasetVersionId;
        RETURN;
    END

    IF @DatasetCode IS NOT NULL AND @VersionNumber IS NOT NULL
    BEGIN
        SELECT @ResolvedEntityId = v.EntityId
        FROM lineage.DatasetVersion v
        INNER JOIN ingest.Dataset d ON d.DatasetId = v.DatasetId
        WHERE d.DatasetCode = @DatasetCode AND v.VersionNumber = @VersionNumber;
        RETURN;
    END

    IF @DatasetCode IS NOT NULL
    BEGIN
        SELECT @ResolvedEntityId = e.EntityId
        FROM lineage.LineageEntity e
        WHERE e.EntityTypeCode = ISNULL(@EntityTypeCode, N'Dataset')
          AND e.EntityCode = @DatasetCode
          AND e.IsActive = 1;
    END
END
GO

-- Upstream: walk Source <- Target (incoming edges to start, then recurse on sources)
CREATE OR ALTER PROCEDURE lineage.usp_GetUpstreamLineage
    @EntityId           UNIQUEIDENTIFIER = NULL,
    @DatasetCode        NVARCHAR(64) = NULL,
    @DatasetVersionId   UNIQUEIDENTIFIER = NULL,
    @VersionNumber      INT = NULL,
    @WorkspaceId        UNIQUEIDENTIFIER = NULL,
    @MaxDepth           INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @MaxDepth IS NULL OR @MaxDepth < 1 SET @MaxDepth = 20;
    IF @MaxDepth > 100 SET @MaxDepth = 100;

    DECLARE @StartId UNIQUEIDENTIFIER;
    EXEC lineage.usp_ResolveStartEntity
        @EntityId=@EntityId, @DatasetCode=@DatasetCode, @DatasetVersionId=@DatasetVersionId,
        @VersionNumber=@VersionNumber, @ResolvedEntityId=@StartId OUTPUT;

    IF @StartId IS NULL
    BEGIN
        SELECT CAST(NULL AS UNIQUEIDENTIFIER) AS EntityId, CAST(NULL AS NVARCHAR(32)) AS EntityTypeCode,
               CAST(NULL AS NVARCHAR(128)) AS EntityCode, CAST(NULL AS NVARCHAR(200)) AS EntityName,
               CAST(NULL AS NVARCHAR(64)) AS RelationshipType, CAST(NULL AS INT) AS Depth,
               CAST(NULL AS INT) AS VersionNumber, CAST(NULL AS UNIQUEIDENTIFIER) AS WorkspaceId,
               CAST(NULL AS UNIQUEIDENTIFIER) AS RelationshipId, CAST(NULL AS UNIQUEIDENTIFIER) AS ViaEntityId
        WHERE 1 = 0;
        RETURN;
    END

    ;WITH cte AS
    (
        SELECT
            r.SourceEntityId AS EntityId,
            r.RelationshipType,
            1 AS Depth,
            r.RelationshipId,
            r.TargetEntityId AS ViaEntityId,
            CAST(CONVERT(NVARCHAR(36), r.TargetEntityId) + N'>' + CONVERT(NVARCHAR(36), r.SourceEntityId) AS NVARCHAR(MAX)) AS PathKey
        FROM lineage.LineageRelationship r
        INNER JOIN lineage.LineageEntity se ON se.EntityId = r.SourceEntityId AND se.IsActive = 1
        WHERE r.TargetEntityId = @StartId
          AND r.IsActive = 1
          AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId
               OR se.WorkspaceId = @WorkspaceId)

        UNION ALL

        SELECT
            r.SourceEntityId,
            r.RelationshipType,
            c.Depth + 1,
            r.RelationshipId,
            r.TargetEntityId,
            CAST(c.PathKey + N'>' + CONVERT(NVARCHAR(36), r.SourceEntityId) AS NVARCHAR(MAX))
        FROM cte c
        INNER JOIN lineage.LineageRelationship r
            ON r.TargetEntityId = c.EntityId AND r.IsActive = 1
        INNER JOIN lineage.LineageEntity se ON se.EntityId = r.SourceEntityId AND se.IsActive = 1
        WHERE c.Depth < @MaxDepth
          AND c.PathKey NOT LIKE N'%' + CONVERT(NVARCHAR(36), r.SourceEntityId) + N'%'
          AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId
               OR se.WorkspaceId = @WorkspaceId)
    )
    SELECT
        e.EntityId,
        e.EntityTypeCode,
        e.EntityCode,
        e.DisplayName AS EntityName,
        c.RelationshipType,
        c.Depth,
        e.VersionNumber,
        COALESCE(e.WorkspaceId, cws.WorkspaceId) AS WorkspaceId,
        c.RelationshipId,
        c.ViaEntityId
    FROM cte c
    INNER JOIN lineage.LineageEntity e ON e.EntityId = c.EntityId
    LEFT JOIN lineage.LineageRelationship cws ON cws.RelationshipId = c.RelationshipId
    WHERE (@WorkspaceId IS NULL OR e.WorkspaceId IS NULL OR e.WorkspaceId = @WorkspaceId)
    ORDER BY c.Depth, e.EntityTypeCode, e.EntityCode
    OPTION (MAXRECURSION 100);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_GetDownstreamLineage
    @EntityId           UNIQUEIDENTIFIER = NULL,
    @DatasetCode        NVARCHAR(64) = NULL,
    @DatasetVersionId   UNIQUEIDENTIFIER = NULL,
    @VersionNumber      INT = NULL,
    @WorkspaceId        UNIQUEIDENTIFIER = NULL,
    @MaxDepth           INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @MaxDepth IS NULL OR @MaxDepth < 1 SET @MaxDepth = 20;
    IF @MaxDepth > 100 SET @MaxDepth = 100;

    DECLARE @StartId UNIQUEIDENTIFIER;
    EXEC lineage.usp_ResolveStartEntity
        @EntityId=@EntityId, @DatasetCode=@DatasetCode, @DatasetVersionId=@DatasetVersionId,
        @VersionNumber=@VersionNumber, @ResolvedEntityId=@StartId OUTPUT;

    IF @StartId IS NULL
    BEGIN
        SELECT CAST(NULL AS UNIQUEIDENTIFIER) AS EntityId WHERE 1 = 0;
        RETURN;
    END

    ;WITH cte AS
    (
        SELECT
            r.TargetEntityId AS EntityId,
            r.RelationshipType,
            1 AS Depth,
            r.RelationshipId,
            r.SourceEntityId AS ViaEntityId,
            CAST(CONVERT(NVARCHAR(36), r.SourceEntityId) + N'>' + CONVERT(NVARCHAR(36), r.TargetEntityId) AS NVARCHAR(MAX)) AS PathKey
        FROM lineage.LineageRelationship r
        INNER JOIN lineage.LineageEntity te ON te.EntityId = r.TargetEntityId AND te.IsActive = 1
        WHERE r.SourceEntityId = @StartId
          AND r.IsActive = 1
          AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId
               OR te.WorkspaceId = @WorkspaceId)

        UNION ALL

        SELECT
            r.TargetEntityId,
            r.RelationshipType,
            c.Depth + 1,
            r.RelationshipId,
            r.SourceEntityId,
            CAST(c.PathKey + N'>' + CONVERT(NVARCHAR(36), r.TargetEntityId) AS NVARCHAR(MAX))
        FROM cte c
        INNER JOIN lineage.LineageRelationship r
            ON r.SourceEntityId = c.EntityId AND r.IsActive = 1
        INNER JOIN lineage.LineageEntity te ON te.EntityId = r.TargetEntityId AND te.IsActive = 1
        WHERE c.Depth < @MaxDepth
          AND c.PathKey NOT LIKE N'%' + CONVERT(NVARCHAR(36), r.TargetEntityId) + N'%'
          AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId
               OR te.WorkspaceId = @WorkspaceId)
    )
    SELECT
        e.EntityId,
        e.EntityTypeCode,
        e.EntityCode,
        e.DisplayName AS EntityName,
        c.RelationshipType,
        c.Depth,
        e.VersionNumber,
        e.WorkspaceId,
        c.RelationshipId,
        c.ViaEntityId
    FROM cte c
    INNER JOIN lineage.LineageEntity e ON e.EntityId = c.EntityId
    WHERE (@WorkspaceId IS NULL OR e.WorkspaceId IS NULL OR e.WorkspaceId = @WorkspaceId)
    ORDER BY c.Depth, e.EntityTypeCode, e.EntityCode
    OPTION (MAXRECURSION 100);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_ImpactAnalysis
    @EntityId           UNIQUEIDENTIFIER = NULL,
    @DatasetCode        NVARCHAR(64) = NULL,
    @DatasetVersionId   UNIQUEIDENTIFIER = NULL,
    @VersionNumber      INT = NULL,
    @ChangeType         NVARCHAR(32) = N'Dataset', -- Dataset | DatasetVersion | DataSource | Transformation
    @WorkspaceId        UNIQUEIDENTIFIER = NULL,
    @MaxDepth           INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    -- Impact = downstream dependents (same traversal) with change context
    EXEC lineage.usp_GetDownstreamLineage
        @EntityId = @EntityId,
        @DatasetCode = @DatasetCode,
        @DatasetVersionId = @DatasetVersionId,
        @VersionNumber = @VersionNumber,
        @WorkspaceId = @WorkspaceId,
        @MaxDepth = @MaxDepth;
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_GetVersionLineage
    @DatasetCode        NVARCHAR(64),
    @VersionNumber      INT = NULL,
    @DatasetVersionId   UNIQUEIDENTIFIER = NULL,
    @WorkspaceId        UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        v.DatasetVersionId,
        d.DatasetCode,
        d.DisplayName AS DatasetName,
        v.VersionNumber,
        v.EntityId,
        v.WorkspaceId,
        v.ImportBatchId,
        v.ImportId,
        v.EtlRunId,
        v.ProfileRunId,
        v.DataSourceId,
        ds.Name AS DataSourceCode,
        v.ProducedUtc,
        v.ProducedBy,
        v.Notes
    FROM lineage.DatasetVersion v
    INNER JOIN ingest.Dataset d ON d.DatasetId = v.DatasetId
    LEFT JOIN reg.DataSource ds ON ds.DataSourceId = v.DataSourceId
    WHERE d.DatasetCode = @DatasetCode
      AND (@VersionNumber IS NULL OR v.VersionNumber = @VersionNumber)
      AND (@DatasetVersionId IS NULL OR v.DatasetVersionId = @DatasetVersionId)
      AND (@WorkspaceId IS NULL OR v.WorkspaceId IS NULL OR v.WorkspaceId = @WorkspaceId)
    ORDER BY v.VersionNumber DESC;

    -- Immediate edges for the selected version(s)
    SELECT
        e.EntityId,
        e.EntityTypeCode,
        e.EntityCode,
        e.DisplayName AS EntityName,
        r.RelationshipType,
        CASE WHEN r.TargetEntityId = v.EntityId THEN N'Upstream' ELSE N'Downstream' END AS Direction,
        e.VersionNumber,
        e.WorkspaceId,
        r.ProcessType,
        r.ProcessReference,
        v.VersionNumber AS SubjectVersionNumber
    FROM lineage.DatasetVersion v
    INNER JOIN ingest.Dataset d ON d.DatasetId = v.DatasetId
    INNER JOIN lineage.LineageRelationship r
        ON r.IsActive = 1 AND (r.SourceEntityId = v.EntityId OR r.TargetEntityId = v.EntityId)
    INNER JOIN lineage.LineageEntity e
        ON e.EntityId = CASE WHEN r.SourceEntityId = v.EntityId THEN r.TargetEntityId ELSE r.SourceEntityId END
    WHERE d.DatasetCode = @DatasetCode
      AND (@VersionNumber IS NULL OR v.VersionNumber = @VersionNumber)
      AND (@DatasetVersionId IS NULL OR v.DatasetVersionId = @DatasetVersionId)
      AND (@WorkspaceId IS NULL OR v.WorkspaceId IS NULL OR v.WorkspaceId = @WorkspaceId)
    ORDER BY v.VersionNumber DESC, Direction, e.EntityTypeCode;
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_DetectCircularDependencies
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @MaxDepth    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @MaxDepth IS NULL OR @MaxDepth < 1 SET @MaxDepth = 50;
    IF @MaxDepth > 100 SET @MaxDepth = 100;

    ;WITH paths AS
    (
        SELECT
            r.SourceEntityId AS StartId,
            r.TargetEntityId AS EntityId,
            1 AS Depth,
            CAST(CONVERT(NVARCHAR(36), r.SourceEntityId) + N'>' + CONVERT(NVARCHAR(36), r.TargetEntityId) AS NVARCHAR(MAX)) AS PathKey,
            r.RelationshipId AS FirstRelationshipId
        FROM lineage.LineageRelationship r
        WHERE r.IsActive = 1
          AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)

        UNION ALL

        SELECT
            p.StartId,
            r.TargetEntityId,
            p.Depth + 1,
            CAST(p.PathKey + N'>' + CONVERT(NVARCHAR(36), r.TargetEntityId) AS NVARCHAR(MAX)),
            p.FirstRelationshipId
        FROM paths p
        INNER JOIN lineage.LineageRelationship r
            ON r.SourceEntityId = p.EntityId AND r.IsActive = 1
        WHERE p.Depth < @MaxDepth
          AND p.EntityId <> p.StartId
          AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
          AND p.PathKey NOT LIKE N'%' + CONVERT(NVARCHAR(36), r.TargetEntityId) + N'%'
    )
    SELECT DISTINCT
        p.StartId AS CycleStartEntityId,
        s.EntityTypeCode AS CycleStartType,
        s.EntityCode AS CycleStartCode,
        s.DisplayName AS CycleStartName,
        p.Depth AS CycleLength,
        p.PathKey AS CyclePath,
        p.FirstRelationshipId
    FROM paths p
    INNER JOIN lineage.LineageEntity s ON s.EntityId = p.StartId
    WHERE p.EntityId = p.StartId
    ORDER BY CycleLength, CycleStartCode
    OPTION (MAXRECURSION 100);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_SyncPlatformLineage
    @CreatedBy NVARCHAR(128) = N'sync',
    @MaxBatches INT = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LogId BIGINT;
    INSERT INTO lineage.LineageCaptureLog (CaptureType, Status, StartedUtc)
    VALUES (N'SyncPlatformLineage', N'Partial', SYSUTCDATETIME());
    SET @LogId = SCOPE_IDENTITY();

    DECLARE @Rels INT = 0, @EntBefore INT, @EntAfter INT, @Added INT;
    SELECT @EntBefore = COUNT(*) FROM lineage.LineageEntity;

    BEGIN TRY
        DECLARE @BatchId UNIQUEIDENTIFIER;
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT TOP (@MaxBatches) BatchId
            FROM ingest.ImportBatch
            ORDER BY ImportUtc DESC;
        OPEN c;
        FETCH NEXT FROM c INTO @BatchId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Added = 0;
            EXEC lineage.usp_RecordImportLineage @BatchId = @BatchId, @CreatedBy = @CreatedBy, @RelationshipsAdded = @Added OUTPUT;
            SET @Rels += ISNULL(@Added, 0);
            FETCH NEXT FROM c INTO @BatchId;
        END
        CLOSE c; DEALLOCATE c;

        DECLARE @RunId UNIQUEIDENTIFIER;
        DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR
            SELECT TOP (@MaxBatches) RunId FROM etl.EtlRun ORDER BY StartedUtc DESC;
        OPEN c2;
        FETCH NEXT FROM c2 INTO @RunId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Added = 0;
            BEGIN TRY
                EXEC lineage.usp_RecordEtlLineage @EtlRunId = @RunId, @CreatedBy = @CreatedBy, @RelationshipsAdded = @Added OUTPUT;
                SET @Rels += ISNULL(@Added, 0);
            END TRY
            BEGIN CATCH
                -- skip orphaned runs
            END CATCH
            FETCH NEXT FROM c2 INTO @RunId;
        END
        CLOSE c2; DEALLOCATE c2;

        DECLARE @ProfId UNIQUEIDENTIFIER;
        DECLARE c3 CURSOR LOCAL FAST_FORWARD FOR
            SELECT TOP (@MaxBatches) ProfileRunId FROM profile.ProfileRun ORDER BY StartedUtc DESC;
        OPEN c3;
        FETCH NEXT FROM c3 INTO @ProfId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @Added = 0;
            BEGIN TRY
                EXEC lineage.usp_RecordProfileLineage @ProfileRunId = @ProfId, @CreatedBy = @CreatedBy, @RelationshipsAdded = @Added OUTPUT;
                SET @Rels += ISNULL(@Added, 0);
            END TRY
            BEGIN CATCH
            END CATCH
            FETCH NEXT FROM c3 INTO @ProfId;
        END
        CLOSE c3; DEALLOCATE c3;

        -- Seed analytics / report assets for CUSTOMER
        SET @Added = 0;
        EXEC lineage.usp_RecordAnalyticsLineage
            @DatasetCode = N'CUSTOMER',
            @AssetCode = N'DASHBOARD_KPI',
            @AssetDisplayName = N'Dashboard KPI Cards',
            @AssetType = N'AnalyticsAsset',
            @CreatedBy = @CreatedBy,
            @RelationshipsAdded = @Added OUTPUT;
        SET @Rels += ISNULL(@Added, 0);

        SET @Added = 0;
        EXEC lineage.usp_RecordAnalyticsLineage
            @DatasetCode = N'CUSTOMER',
            @AssetCode = N'rpt.usp_DatasetQualitySummary',
            @AssetDisplayName = N'Dataset Quality Summary Report',
            @AssetType = N'Report',
            @CreatedBy = @CreatedBy,
            @RelationshipsAdded = @Added OUTPUT;
        SET @Rels += ISNULL(@Added, 0);

        SELECT @EntAfter = COUNT(*) FROM lineage.LineageEntity;

        UPDATE lineage.LineageCaptureLog
        SET Status = N'Succeeded',
            RelationshipsAdded = @Rels,
            EntitiesAdded = @EntAfter - @EntBefore,
            CompletedUtc = SYSUTCDATETIME(),
            Message = CONCAT(N'Synced relationships=', @Rels, N'; entitiesDelta=', @EntAfter - @EntBefore)
        WHERE CaptureLogId = @LogId;

        SELECT @LogId AS CaptureLogId, @Rels AS RelationshipsAdded, (@EntAfter - @EntBefore) AS EntitiesAdded, N'Succeeded' AS Status;
    END TRY
    BEGIN CATCH
        UPDATE lineage.LineageCaptureLog
        SET Status = N'Failed', CompletedUtc = SYSUTCDATETIME(), Message = ERROR_MESSAGE()
        WHERE CaptureLogId = @LogId;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_ArchiveLineageHistory
    @RetainDays INT = 365
AS
BEGIN
    SET NOCOUNT ON;
    IF @RetainDays < 30 SET @RetainDays = 30;

    -- Soft-deactivate very old inactive capture noise only; relationships are historical and retained.
    DELETE FROM lineage.LineageCaptureLog
    WHERE StartedUtc < DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    SELECT @@ROWCOUNT AS CaptureLogsDeleted;
END
GO

-- ---------------- Analytics / dashboard feeds ----------------

CREATE OR ALTER PROCEDURE rpt.usp_LineageMostConnected
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Take INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    IF @Take IS NULL OR @Take < 1 SET @Take = 20;

    ;WITH deg AS
    (
        SELECT e.EntityId,
               SUM(CASE WHEN r.SourceEntityId = e.EntityId OR r.TargetEntityId = e.EntityId THEN 1 ELSE 0 END) AS Degree
        FROM lineage.LineageEntity e
        LEFT JOIN lineage.LineageRelationship r
            ON r.IsActive = 1 AND (r.SourceEntityId = e.EntityId OR r.TargetEntityId = e.EntityId)
           AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
        WHERE e.IsActive = 1
          AND (@WorkspaceId IS NULL OR e.WorkspaceId IS NULL OR e.WorkspaceId = @WorkspaceId)
        GROUP BY e.EntityId
    )
    SELECT TOP (@Take)
        e.EntityId, e.EntityTypeCode, e.EntityCode, e.DisplayName AS EntityName,
        e.WorkspaceId, e.VersionNumber, d.Degree AS ConnectionCount
    FROM deg d
    INNER JOIN lineage.LineageEntity e ON e.EntityId = d.EntityId
    ORDER BY d.Degree DESC, e.EntityCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LineageHighestDependencies
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Take INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    -- Dependencies = upstream count (incoming)
    SELECT TOP (@Take)
        e.EntityId, e.EntityTypeCode, e.EntityCode, e.DisplayName AS EntityName,
        e.WorkspaceId, COUNT(*) AS DependencyCount
    FROM lineage.LineageEntity e
    INNER JOIN lineage.LineageRelationship r ON r.TargetEntityId = e.EntityId AND r.IsActive = 1
    WHERE e.IsActive = 1
      AND (@WorkspaceId IS NULL OR e.WorkspaceId IS NULL OR e.WorkspaceId = @WorkspaceId)
      AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
    GROUP BY e.EntityId, e.EntityTypeCode, e.EntityCode, e.DisplayName, e.WorkspaceId
    ORDER BY DependencyCount DESC, e.EntityCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LineageHighestDependents
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Take INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Take)
        e.EntityId, e.EntityTypeCode, e.EntityCode, e.DisplayName AS EntityName,
        e.WorkspaceId, COUNT(*) AS DependentCount
    FROM lineage.LineageEntity e
    INNER JOIN lineage.LineageRelationship r ON r.SourceEntityId = e.EntityId AND r.IsActive = 1
    WHERE e.IsActive = 1
      AND (@WorkspaceId IS NULL OR e.WorkspaceId IS NULL OR e.WorkspaceId = @WorkspaceId)
      AND (@WorkspaceId IS NULL OR r.WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
    GROUP BY e.EntityId, e.EntityTypeCode, e.EntityCode, e.DisplayName, e.WorkspaceId
    ORDER BY DependentCount DESC, e.EntityCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LineageRelationshipCounts
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        RelationshipType,
        ProcessType,
        COUNT(*) AS RelationshipCount
    FROM lineage.LineageRelationship
    WHERE IsActive = 1
      AND (@WorkspaceId IS NULL OR WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
    GROUP BY RelationshipType, ProcessType
    ORDER BY RelationshipCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LineageSourceToDatasetCounts
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        src.EntityCode AS SourceCode,
        src.DisplayName AS SourceName,
        ds.EntityCode AS DatasetCode,
        ds.DisplayName AS DatasetName,
        COUNT(*) AS PathCount
    FROM lineage.LineageRelationship r1
    INNER JOIN lineage.LineageEntity src ON src.EntityId = r1.SourceEntityId AND src.EntityTypeCode = N'DataSource'
    INNER JOIN lineage.LineageRelationship r2 ON r2.SourceEntityId = r1.TargetEntityId AND r2.IsActive = 1
    INNER JOIN lineage.LineageEntity ds ON ds.EntityId = r2.TargetEntityId AND ds.EntityTypeCode = N'Dataset'
    WHERE r1.IsActive = 1
      AND (@WorkspaceId IS NULL OR ds.WorkspaceId IS NULL OR ds.WorkspaceId = @WorkspaceId)
    GROUP BY src.EntityCode, src.DisplayName, ds.EntityCode, ds.DisplayName
    ORDER BY PathCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LineageDatasetToReport
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ds.EntityCode AS DatasetCode,
        ds.DisplayName AS DatasetName,
        rep.EntityTypeCode AS AssetType,
        rep.EntityCode AS AssetCode,
        rep.DisplayName AS AssetName,
        r.RelationshipType,
        r.CreatedUtc
    FROM lineage.LineageRelationship r
    INNER JOIN lineage.LineageEntity ds ON ds.EntityId = r.SourceEntityId AND ds.EntityTypeCode = N'Dataset'
    INNER JOIN lineage.LineageEntity rep ON rep.EntityId = r.TargetEntityId AND rep.EntityTypeCode IN (N'Report', N'AnalyticsAsset')
    WHERE r.IsActive = 1
      AND (@WorkspaceId IS NULL OR ds.WorkspaceId IS NULL OR ds.WorkspaceId = @WorkspaceId)
    ORDER BY ds.EntityCode, rep.EntityCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LineageDependencyDepth
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @MaxDepth INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    -- Max outbound depth per dataset entity
    ;WITH roots AS
    (
        SELECT EntityId FROM lineage.LineageEntity
        WHERE EntityTypeCode = N'Dataset' AND IsActive = 1
          AND (@WorkspaceId IS NULL OR WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
    ),
    walk AS
    (
        SELECT r.EntityId AS RootId, r.EntityId AS EntityId, 0 AS Depth,
               CAST(CONVERT(NVARCHAR(36), r.EntityId) AS NVARCHAR(MAX)) AS PathKey
        FROM roots r

        UNION ALL

        SELECT w.RootId, rel.TargetEntityId, w.Depth + 1,
               CAST(w.PathKey + N'>' + CONVERT(NVARCHAR(36), rel.TargetEntityId) AS NVARCHAR(MAX))
        FROM walk w
        INNER JOIN lineage.LineageRelationship rel ON rel.SourceEntityId = w.EntityId AND rel.IsActive = 1
        WHERE w.Depth < @MaxDepth
          AND w.PathKey NOT LIKE N'%' + CONVERT(NVARCHAR(36), rel.TargetEntityId) + N'%'
    )
    SELECT
        e.EntityCode AS DatasetCode,
        e.DisplayName AS DatasetName,
        e.WorkspaceId,
        MAX(w.Depth) AS MaxDownstreamDepth,
        COUNT(DISTINCT CASE WHEN w.Depth > 0 THEN w.EntityId END) AS DownstreamEntityCount
    FROM walk w
    INNER JOIN lineage.LineageEntity e ON e.EntityId = w.RootId
    GROUP BY e.EntityCode, e.DisplayName, e.WorkspaceId
    ORDER BY MaxDownstreamDepth DESC, DatasetCode
    OPTION (MAXRECURSION 100);
END
GO

CREATE OR ALTER PROCEDURE lineage.usp_GetEntity
    @EntityId UNIQUEIDENTIFIER = NULL,
    @EntityCode NVARCHAR(128) = NULL,
    @EntityTypeCode NVARCHAR(32) = NULL,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (50)
        e.EntityId, e.EntityTypeCode, e.EntityCode, e.DisplayName AS EntityName,
        e.ExternalKey, e.WorkspaceId, e.DatasetId, e.VersionNumber, e.IsActive,
        e.CreatedUtc, e.ModifiedUtc
    FROM lineage.LineageEntity e
    WHERE (@EntityId IS NULL OR e.EntityId = @EntityId)
      AND (@EntityCode IS NULL OR e.EntityCode = @EntityCode)
      AND (@EntityTypeCode IS NULL OR e.EntityTypeCode = @EntityTypeCode)
      AND (@WorkspaceId IS NULL OR e.WorkspaceId IS NULL OR e.WorkspaceId = @WorkspaceId)
    ORDER BY e.EntityTypeCode, e.EntityCode;
END
GO

PRINT 'Lineage procedures created.';
GO
