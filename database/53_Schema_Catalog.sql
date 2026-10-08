-- ============================================================
-- 53_Schema_Catalog.sql
-- Data Catalog, Discovery & Metadata Search
-- Reuses ingest.Dataset / gov.DatasetGovernance / analytics.Workspace /
-- gov.AppUser / profile.DatasetProfile / lineage.* / ingest.ImportBatch.
-- Adds only: the platform tag structure (no tag table existed),
-- the discovery policy, and indexes proven necessary in
-- 58_Perf_Catalog.sql (see docs/18-SQL-Data-Catalog-Discovery.md).
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'cat')
    EXEC(N'CREATE SCHEMA cat AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Tags (single platform tag structure)
-- Names are stored lower-case; commas are not allowed because tag
-- filters are passed as comma-separated lists.
-- ------------------------------------------------------------
IF OBJECT_ID(N'cat.Tag', N'U') IS NULL
BEGIN
    CREATE TABLE cat.Tag
    (
        TagId           INT              NOT NULL IDENTITY(1,1) CONSTRAINT PK_CatTag PRIMARY KEY,
        TagName         NVARCHAR(64)     NOT NULL,
        Description     NVARCHAR(500)    NULL,
        IsActive        BIT              NOT NULL CONSTRAINT DF_CatTag_Active DEFAULT (1),
        CreatedByUserId UNIQUEIDENTIFIER NULL,
        CreatedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_CatTag_Created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_CatTag_CreatedBy FOREIGN KEY (CreatedByUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT CK_CatTag_Name CHECK (
            LEN(TagName) > 0
            AND TagName = LOWER(TagName) COLLATE Latin1_General_CS_AS
            AND CHARINDEX(N',', TagName) = 0
            AND TagName = LTRIM(RTRIM(TagName)))
    );

    CREATE UNIQUE INDEX UX_CatTag_Name ON cat.Tag (TagName) INCLUDE (IsActive);
END
GO

IF OBJECT_ID(N'cat.DatasetTag', N'U') IS NULL
BEGIN
    CREATE TABLE cat.DatasetTag
    (
        DatasetId      UNIQUEIDENTIFIER NOT NULL,
        TagId          INT              NOT NULL,
        TaggedByUserId UNIQUEIDENTIFIER NULL,
        TaggedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_CatDatasetTag_Tagged DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_CatDatasetTag PRIMARY KEY (DatasetId, TagId),
        CONSTRAINT FK_CatDatasetTag_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_CatDatasetTag_Tag FOREIGN KEY (TagId) REFERENCES cat.Tag (TagId),
        CONSTRAINT FK_CatDatasetTag_User FOREIGN KEY (TaggedByUserId) REFERENCES gov.AppUser (UserId)
    );

    -- Tag → datasets (tag filter / tag counts); PK serves dataset → tags
    CREATE INDEX IX_CatDatasetTag_Tag ON cat.DatasetTag (TagId, DatasetId);
END
GO

-- ------------------------------------------------------------
-- Discovery policy: minimum workspace role that may DISCOVER
-- (see metadata of) a dataset of a classification through
-- workspace membership alone. Grants, shares, ownership,
-- stewardship and platform admin always allow discovery.
-- ------------------------------------------------------------
IF OBJECT_ID(N'cat.DiscoveryPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE cat.DiscoveryPolicy
    (
        ClassificationCode   NVARCHAR(32)  NOT NULL CONSTRAINT PK_CatDiscoveryPolicy PRIMARY KEY,
        MinWorkspaceRoleCode NVARCHAR(32)  NOT NULL,
        Description          NVARCHAR(500) NULL,
        ModifiedUtc          DATETIME2(3)  NOT NULL CONSTRAINT DF_CatDiscoveryPolicy_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_CatDiscoveryPolicy_Class FOREIGN KEY (ClassificationCode) REFERENCES gov.Classification (ClassificationCode),
        CONSTRAINT FK_CatDiscoveryPolicy_Role FOREIGN KEY (MinWorkspaceRoleCode) REFERENCES gov.Role (RoleCode)
    );
END
GO

MERGE cat.DiscoveryPolicy AS t
USING (VALUES
    (N'Public',       N'Viewer',    N'Any workspace member'),
    (N'Internal',     N'Viewer',    N'Any workspace member'),
    (N'Confidential', N'Analyst',   N'Analyst and above; viewers need a grant or share'),
    (N'Restricted',   N'DataOwner', N'Workspace data owners / admins; others need a grant or share')
) AS s (ClassificationCode, MinWorkspaceRoleCode, Description)
ON t.ClassificationCode = s.ClassificationCode
WHEN NOT MATCHED THEN
    INSERT (ClassificationCode, MinWorkspaceRoleCode, Description)
    VALUES (s.ClassificationCode, s.MinWorkspaceRoleCode, s.Description);
GO

-- ------------------------------------------------------------
-- Indexes on existing tables (only where the catalog needs them)
-- Existing indexes reused as-is: UX_Dataset_Code, IX_Dataset_Analytics,
-- IX_Dataset_Created/Modified, IX_DG_*, IX_ImportBatch_Analytics,
-- UX_DatasetVersion_Dataset_Number, IX_WsMember_User,
-- IX_AccessGrant_User_Active, IX_Share_Recipient_Auth.
-- A covering (DisplayName, DatasetId) index on ingest.Dataset was
-- benchmarked (58_Perf_Catalog.sql) and rejected: no gain on page 1,
-- ~12% on keyset pages, not worth the write cost.
-- ------------------------------------------------------------

-- Source type = source of the latest import that has a registered
-- data source. Few batches carry a DataSourceId, so this filtered
-- index is small; search / source-type filters scan it instead of
-- the clustered batch history (measured ~12-15% fewer reads).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ImportBatch_Dataset_Source' AND object_id = OBJECT_ID(N'ingest.ImportBatch'))
    CREATE INDEX IX_ImportBatch_Dataset_Source
        ON ingest.ImportBatch (DatasetId, ImportUtc DESC)
        INCLUDE (DataSourceId)
        WHERE DataSourceId IS NOT NULL;
GO

PRINT 'Catalog schema ready.';
GO
