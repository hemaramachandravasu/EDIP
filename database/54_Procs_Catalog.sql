-- ============================================================
-- 54_Procs_Catalog.sql
-- Data Catalog, Discovery & Metadata Search
--   * cat.fn_DatasetDiscovery   access-aware discoverable set
--   * cat.fn_CatalogSearch      composable filters + relevance
--   * cat.usp_SearchCatalog     search / filter / sort / page (offset + keyset)
--   * cat.usp_GetDatasetDetail  consolidated detail (fixed result sets)
--   * tag procedures, catalog summary reports
-- All queries are static, parameterized T-SQL (no dynamic SQL).
-- ============================================================
USE EDIP;
GO

-- ============================================================
-- Access-aware discovery
-- A dataset is discoverable when the user is:
--   platform admin | dataset owner | dataset steward      (always)
--   holder of an active, unexpired access grant or share  (any workspace)
--   active member of the dataset workspace whose role rank
--   meets cat.DiscoveryPolicy for the dataset classification
-- Non-current datasets (inactive, DatasetStatus Inactive/Archived,
-- governance Archived) are visible only to admin/owner/steward and
-- only when @IncludeInactive = 1.
-- EffectiveAccessLevel is the DATA access level (mirrors
-- gov.usp_EvaluateDatasetAccess + active shares); NULL means the
-- user can see the metadata but must request access.
-- Two branches selected by @IsPlatformAdmin (constant-folded under
-- OPTION (RECOMPILE), a startup filter otherwise):
--   platform admin -> every dataset, no per-row access evaluation
--   everyone else  -> candidates gathered per access path first so
--                     large catalogs only evaluate reachable datasets
-- Internal contract: callers resolve the ACTIVE user once and pass
-- gov.AppUser.IsPlatformAdmin; passing 0 for an admin only narrows
-- the result to the admin's non-admin access.
-- ============================================================
CREATE OR ALTER FUNCTION cat.fn_DatasetDiscovery
(
    @UserId          UNIQUEIDENTIFIER,
    @IsPlatformAdmin BIT,
    @IncludeInactive BIT
)
RETURNS TABLE
AS
RETURN
WITH mem AS (
    SELECT wm.WorkspaceId, wm.RoleCode,
           CASE wm.RoleCode WHEN N'Viewer' THEN 1 WHEN N'Analyst' THEN 2 WHEN N'DataSteward' THEN 3
                            WHEN N'DataOwner' THEN 4 WHEN N'WorkspaceAdmin' THEN 5 ELSE 0 END AS RoleRank
    FROM gov.WorkspaceMember wm
    WHERE wm.UserId = @UserId AND wm.IsActive = 1
),
grants AS (
    SELECT ga.DatasetId, MAX(al.RankOrder) AS GrantRank
    FROM gov.DatasetAccessGrant ga
    INNER JOIN gov.AccessLevel al ON al.AccessLevelCode = ga.AccessLevelCode
    WHERE ga.UserId = @UserId AND ga.IsActive = 1
      AND (ga.ExpiresUtc IS NULL OR ga.ExpiresUtc > SYSUTCDATETIME())
    GROUP BY ga.DatasetId
),
shares AS (
    SELECT s.DatasetId, MAX(al.RankOrder) AS ShareRank
    FROM share.DatasetShare s
    INNER JOIN gov.AccessLevel al ON al.AccessLevelCode = s.AccessLevelCode
    WHERE s.RecipientUserId = @UserId AND s.Status = N'Active'
      AND (s.ExpiresUtc IS NULL OR s.ExpiresUtc > SYSUTCDATETIME())
    GROUP BY s.DatasetId
),
cand AS (
    SELECT d.DatasetId FROM ingest.Dataset d INNER JOIN mem m ON m.WorkspaceId = d.WorkspaceId
    UNION
    SELECT g.DatasetId FROM gov.DatasetGovernance g INNER JOIN mem m ON m.WorkspaceId = g.WorkspaceId
    UNION
    SELECT DatasetId FROM grants
    UNION
    SELECT DatasetId FROM shares
    UNION
    SELECT DatasetId FROM gov.DatasetGovernance WHERE OwnerUserId = @UserId
    UNION
    SELECT DatasetId FROM gov.DatasetGovernance WHERE StewardUserId = @UserId
),
facts AS (
    SELECT d.DatasetId,
           COALESCE(g.WorkspaceId, d.WorkspaceId)                  AS WorkspaceId,
           COALESCE(g.ClassificationCode, N'Internal')             AS ClassificationCode,
           ISNULL(c.SensitivityRank, 2)                            AS SensitivityRank,
           COALESCE(g.GovernanceStatusCode, N'Draft')              AS GovernanceStatusCode,
           COALESCE(g.CertificationStatusCode, N'NotCertified')    AS CertificationStatusCode,
           g.OwnerUserId, g.StewardUserId,
           CASE WHEN d.IsActive = 1
                 AND d.DatasetStatus NOT IN (N'Inactive', N'Archived')
                 AND COALESCE(g.GovernanceStatusCode, N'Draft') <> N'Archived'
                THEN 1 ELSE 0 END                                  AS IsCurrent,
           CASE WHEN g.OwnerUserId = @UserId THEN N'DatasetOwner'
                WHEN g.StewardUserId = @UserId THEN N'DatasetSteward' END AS PrivilegedSource,
           m.RoleCode                                              AS WorkspaceRole,
           ISNULL(m.RoleRank, 0)                                   AS RoleRank,
           CASE p.MinWorkspaceRoleCode WHEN N'Viewer' THEN 1 WHEN N'Analyst' THEN 2 WHEN N'DataSteward' THEN 3
                                       WHEN N'DataOwner' THEN 4 WHEN N'WorkspaceAdmin' THEN 5 ELSE 99 END AS PolicyRank,
           gr.GrantRank, sh.ShareRank
    FROM cand
    INNER JOIN ingest.Dataset d ON d.DatasetId = cand.DatasetId
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    LEFT JOIN gov.Classification c ON c.ClassificationCode = COALESCE(g.ClassificationCode, N'Internal')
    LEFT JOIN cat.DiscoveryPolicy p ON p.ClassificationCode = COALESCE(g.ClassificationCode, N'Internal')
    LEFT JOIN mem m ON m.WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId)
    LEFT JOIN grants gr ON gr.DatasetId = d.DatasetId
    LEFT JOIN shares sh ON sh.DatasetId = d.DatasetId
),
decided AS (
    SELECT f.*,
           CASE WHEN f.PrivilegedSource IS NOT NULL THEN f.PrivilegedSource
                WHEN f.IsCurrent = 0 THEN NULL
                WHEN f.GrantRank IS NOT NULL AND f.GrantRank >= ISNULL(f.ShareRank, 0) THEN N'AccessGrant'
                WHEN f.ShareRank IS NOT NULL THEN N'DatasetShare'
                WHEN f.RoleRank > 0 AND f.RoleRank >= f.PolicyRank THEN N'WorkspaceRole'
           END AS AccessSource,
           CASE WHEN f.PrivilegedSource IS NOT NULL THEN 3
                WHEN f.IsCurrent = 0 THEN 0
                ELSE GREATEST(ISNULL(f.GrantRank, 0), ISNULL(f.ShareRank, 0),
                     CASE WHEN f.SensitivityRank <= 2 AND f.RoleRank >= 4 THEN 3      -- WorkspaceAdmin / DataOwner
                          WHEN f.SensitivityRank <= 2 AND f.RoleRank IN (2, 3) THEN 1  -- Analyst / DataSteward
                          WHEN f.SensitivityRank = 1 AND f.RoleRank = 1 THEN 1         -- Viewer on Public
                          ELSE 0 END)
           END AS DataRank
    FROM facts f
),
adm AS (
    SELECT d.DatasetId,
           COALESCE(g.WorkspaceId, d.WorkspaceId)                  AS WorkspaceId,
           COALESCE(g.ClassificationCode, N'Internal')             AS ClassificationCode,
           ISNULL(c.SensitivityRank, 2)                            AS SensitivityRank,
           COALESCE(g.GovernanceStatusCode, N'Draft')              AS GovernanceStatusCode,
           COALESCE(g.CertificationStatusCode, N'NotCertified')    AS CertificationStatusCode,
           g.OwnerUserId, g.StewardUserId,
           CASE WHEN d.IsActive = 1
                 AND d.DatasetStatus NOT IN (N'Inactive', N'Archived')
                 AND COALESCE(g.GovernanceStatusCode, N'Draft') <> N'Archived'
                THEN 1 ELSE 0 END                                  AS IsCurrent,
           m.RoleCode                                              AS WorkspaceRole
    FROM ingest.Dataset d
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    LEFT JOIN gov.Classification c ON c.ClassificationCode = COALESCE(g.ClassificationCode, N'Internal')
    LEFT JOIN mem m ON m.WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId)
)
SELECT DatasetId, WorkspaceId, ClassificationCode, SensitivityRank, GovernanceStatusCode,
       CertificationStatusCode, OwnerUserId, StewardUserId,
       CAST(IsCurrent AS BIT) AS IsCurrent,
       WorkspaceRole, N'PlatformAdmin' AS AccessSource,
       N'Admin' AS EffectiveAccessLevel,
       CAST(1 AS BIT) AS CanReadData,
       CAST(0 AS BIT) AS CanRequestAccess
FROM adm
WHERE @IsPlatformAdmin = 1
  AND (IsCurrent = 1 OR @IncludeInactive = 1)
UNION ALL
SELECT DatasetId, WorkspaceId, ClassificationCode, SensitivityRank, GovernanceStatusCode,
       CertificationStatusCode, OwnerUserId, StewardUserId,
       CAST(IsCurrent AS BIT) AS IsCurrent,
       WorkspaceRole, AccessSource,
       CASE DataRank WHEN 3 THEN N'Admin' WHEN 2 THEN N'Write' WHEN 1 THEN N'Read' END AS EffectiveAccessLevel,
       CAST(CASE WHEN DataRank > 0 THEN 1 ELSE 0 END AS BIT) AS CanReadData,
       CAST(CASE WHEN DataRank = 0 AND IsCurrent = 1 THEN 1 ELSE 0 END AS BIT) AS CanRequestAccess
FROM decided
WHERE ISNULL(@IsPlatformAdmin, 0) = 0
  AND AccessSource IS NOT NULL
  AND (IsCurrent = 1 OR @IncludeInactive = 1);
GO

-- ============================================================
-- Composable catalog filter + deterministic relevance.
-- Every filter is optional (NULL = not applied). Callers should run
-- statements over this function with OPTION (RECOMPILE) so unused
-- filters and APPLY branches are removed from the plan.
-- Relevance tiers (best match wins, +1 per additional matching field):
--   name exact 1000 / prefix 900 / contains 800
--   code exact  700 / prefix 650 / contains 600
--   tag  exact  500 / contains 450
--   description 300, category 200, owner/steward 150, source type 100
-- ============================================================
CREATE OR ALTER FUNCTION cat.fn_CatalogSearch
(
    @UserId                  UNIQUEIDENTIFIER,
    @IsPlatformAdmin         BIT,
    @IncludeInactive         BIT,
    @Term                    NVARCHAR(200),   -- trimmed search text (NULL = no search)
    @Contains                NVARCHAR(210),   -- '%escaped%'
    @Prefix                  NVARCHAR(210),   -- 'escaped%'
    @WorkspaceId             UNIQUEIDENTIFIER,
    @Category                NVARCHAR(64),
    @ClassificationCode      NVARCHAR(32),
    @GovernanceStatusCode    NVARCHAR(32),
    @DatasetStatus           NVARCHAR(16),
    @CertificationStatusCode NVARCHAR(32),
    @OwnerUserId             UNIQUEIDENTIFIER,
    @OwnerName               NVARCHAR(128),   -- legacy text owner (ingest.Dataset.OwnerName)
    @StewardUserId           UNIQUEIDENTIFIER,
    @SourceTypeCode          NVARCHAR(32),
    @MinQualityScore         DECIMAL(5,2),
    @MaxQualityScore         DECIMAL(5,2),
    @CreatedFrom             DATETIME2(3),
    @CreatedTo               DATETIME2(3),
    @UpdatedFrom             DATETIME2(3),
    @UpdatedTo               DATETIME2(3),
    @TagList                 NVARCHAR(1000),  -- normalized 'a,b,c'
    @TagCount                INT,
    @TagMatchAll             BIT,
    @NeedLastImport          BIT
)
RETURNS TABLE
AS
RETURN
WITH li AS (            -- latest successful import per dataset (IX_ImportBatch_Analytics)
    SELECT x.DatasetId, x.ImportUtc AS LastImportUtc
    FROM (SELECT b.DatasetId, b.ImportUtc,
                 ROW_NUMBER() OVER (PARTITION BY b.DatasetId ORDER BY b.ImportUtc DESC) AS rn
          FROM ingest.ImportBatch b
          WHERE @NeedLastImport = 1
            AND b.Status IN (N'Completed', N'CompletedWithErrors')) x
    WHERE x.rn = 1
),
src AS (                -- latest registered source per dataset (IX_ImportBatch_Dataset_Source)
    SELECT x.DatasetId, st.TypeCode, st.DisplayName
    FROM (SELECT b.DatasetId, b.DataSourceId,
                 ROW_NUMBER() OVER (PARTITION BY b.DatasetId ORDER BY b.ImportUtc DESC) AS rn
          FROM ingest.ImportBatch b
          WHERE (@Term IS NOT NULL OR @SourceTypeCode IS NOT NULL)
            AND b.DataSourceId IS NOT NULL) x
    INNER JOIN reg.DataSource ds ON ds.DataSourceId = x.DataSourceId
    INNER JOIN reg.DataSourceType st ON st.DataSourceTypeId = ds.DataSourceTypeId
    WHERE x.rn = 1
),
tg AS (                 -- tag relevance, driven from the (small) tag dictionary
    SELECT dt.DatasetId, MAX(CASE WHEN t.TagName = @Term THEN 500 ELSE 450 END) AS TagScore
    FROM cat.Tag t
    INNER JOIN cat.DatasetTag dt ON dt.TagId = t.TagId
    WHERE @Term IS NOT NULL AND t.IsActive = 1
      AND t.TagName LIKE @Contains
    GROUP BY dt.DatasetId
),
tf AS (                 -- tag filter (Any / All)
    SELECT dt.DatasetId, COUNT(*) AS MatchedTags
    FROM cat.Tag t
    INNER JOIN cat.DatasetTag dt ON dt.TagId = t.TagId
    WHERE ISNULL(@TagCount, 0) > 0 AND t.IsActive = 1
      AND t.TagName IN (SELECT value FROM STRING_SPLIT(@TagList, N','))
    GROUP BY dt.DatasetId
),
pu AS (                 -- users whose name matches the search text
    SELECT UserId
    FROM gov.AppUser
    WHERE @Term IS NOT NULL
      AND (DisplayName COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains
        OR UserName COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains)
)
SELECT a.DatasetId, d.DisplayName, d.DatasetCode, d.CreatedUtc, d.ModifiedUtc,
       a.WorkspaceId, a.ClassificationCode, a.SensitivityRank, a.GovernanceStatusCode,
       ISNULL(gs.SortOrder, 0) AS GovernanceSortOrder, a.CertificationStatusCode,
       a.OwnerUserId, a.StewardUserId, a.IsCurrent,
       a.AccessSource, a.EffectiveAccessLevel, a.CanReadData, a.CanRequestAccess,
       dp.LatestOverallScore AS QualityScore,
       li.LastImportUtc,
       CASE WHEN @Term IS NULL OR sc.Best = 0 THEN 0 ELSE sc.Best + sc.Matched END AS RelevanceScore
FROM cat.fn_DatasetDiscovery(@UserId, @IsPlatformAdmin, @IncludeInactive) a
INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
LEFT JOIN gov.GovernanceStatus gs ON gs.StatusCode = a.GovernanceStatusCode
LEFT JOIN profile.DatasetProfile dp ON dp.DatasetId = a.DatasetId
LEFT JOIN li ON li.DatasetId = a.DatasetId
LEFT JOIN src ON src.DatasetId = a.DatasetId
LEFT JOIN tg ON tg.DatasetId = a.DatasetId
LEFT JOIN tf ON tf.DatasetId = a.DatasetId
LEFT JOIN pu po ON po.UserId = a.OwnerUserId
LEFT JOIN pu ps ON ps.UserId = a.StewardUserId
CROSS APPLY (
    SELECT CASE WHEN @Term IS NOT NULL
                 AND (po.UserId IS NOT NULL OR ps.UserId IS NOT NULL
                   OR d.OwnerName COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains)
                THEN 150 ELSE 0 END AS PeopleScore
) pe
CROSS APPLY (
    SELECT
        CASE WHEN @Term IS NULL THEN 0
             WHEN d.DisplayName COLLATE SQL_Latin1_General_CP1_CI_AS = @Term THEN 1000
             WHEN d.DisplayName COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Prefix THEN 900
             WHEN d.DisplayName COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains THEN 800 ELSE 0 END AS NameScore,
        CASE WHEN @Term IS NULL THEN 0
             WHEN d.DatasetCode COLLATE SQL_Latin1_General_CP1_CI_AS = @Term THEN 700
             WHEN d.DatasetCode COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Prefix THEN 650
             WHEN d.DatasetCode COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains THEN 600 ELSE 0 END AS CodeScore,
        ISNULL(tg.TagScore, 0) AS TagScore,
        CASE WHEN @Term IS NOT NULL AND d.Description COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains THEN 300 ELSE 0 END AS DescScore,
        CASE WHEN @Term IS NOT NULL AND d.Category COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains THEN 200 ELSE 0 END AS CategoryScore,
        pe.PeopleScore,
        CASE WHEN @Term IS NOT NULL
              AND (src.TypeCode COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains
                OR src.DisplayName COLLATE SQL_Latin1_General_CP1_CI_AS LIKE @Contains) THEN 100 ELSE 0 END AS SourceScore
) f
CROSS APPLY (
    SELECT GREATEST(f.NameScore, f.CodeScore, f.TagScore, f.DescScore, f.CategoryScore, f.PeopleScore, f.SourceScore) AS Best,
           IIF(f.NameScore > 0, 1, 0) + IIF(f.CodeScore > 0, 1, 0) + IIF(f.TagScore > 0, 1, 0)
         + IIF(f.DescScore > 0, 1, 0) + IIF(f.CategoryScore > 0, 1, 0) + IIF(f.PeopleScore > 0, 1, 0)
         + IIF(f.SourceScore > 0, 1, 0) - 1 AS Matched
) sc
WHERE (@Term IS NULL OR sc.Best > 0)
  AND (@WorkspaceId IS NULL OR a.WorkspaceId = @WorkspaceId)
  AND (@Category IS NULL OR d.Category = @Category)
  AND (@ClassificationCode IS NULL OR a.ClassificationCode = @ClassificationCode)
  AND (@GovernanceStatusCode IS NULL OR a.GovernanceStatusCode = @GovernanceStatusCode)
  AND (@DatasetStatus IS NULL OR d.DatasetStatus = @DatasetStatus)
  AND (@CertificationStatusCode IS NULL OR a.CertificationStatusCode = @CertificationStatusCode)
  AND (@OwnerUserId IS NULL OR a.OwnerUserId = @OwnerUserId)
  AND (@OwnerName IS NULL OR d.OwnerName = @OwnerName)
  AND (@StewardUserId IS NULL OR a.StewardUserId = @StewardUserId)
  AND (@SourceTypeCode IS NULL OR src.TypeCode = @SourceTypeCode)
  AND (@MinQualityScore IS NULL OR dp.LatestOverallScore >= @MinQualityScore)
  AND (@MaxQualityScore IS NULL OR dp.LatestOverallScore <= @MaxQualityScore)
  AND (@CreatedFrom IS NULL OR d.CreatedUtc >= @CreatedFrom)
  AND (@CreatedTo IS NULL OR d.CreatedUtc < @CreatedTo)
  AND (@UpdatedFrom IS NULL OR d.ModifiedUtc >= @UpdatedFrom)
  AND (@UpdatedTo IS NULL OR d.ModifiedUtc < @UpdatedTo)
  AND (ISNULL(@TagCount, 0) = 0
       OR (tf.DatasetId IS NOT NULL AND (@TagMatchAll = 0 OR tf.MatchedTags = @TagCount)));
GO

-- ============================================================
-- Normalizes a comma-separated tag list: trimmed, lower-case,
-- distinct, sorted. Used by search and tag maintenance.
-- ============================================================
CREATE OR ALTER FUNCTION cat.fn_ParseTagList (@Tags NVARCHAR(1000))
RETURNS TABLE
AS
RETURN
SELECT DISTINCT LOWER(LTRIM(RTRIM(value))) AS TagName
FROM STRING_SPLIT(ISNULL(@Tags, N''), N',')
WHERE LTRIM(RTRIM(value)) <> N'';
GO

-- ============================================================
-- Catalog search / browse
-- Paging: OFFSET (PageNumber) for every sort; KEYSET (AfterValue +
-- AfterDatasetId) for Name, Code, CreatedDate, UpdatedDate.
-- One result set (catalog rows, only when StatusCode = 'OK');
-- paging metadata is returned in OUTPUT parameters.
-- ============================================================
CREATE OR ALTER PROCEDURE cat.usp_SearchCatalog
    @UserName                NVARCHAR(128),
    @SearchText              NVARCHAR(200) = NULL,
    @WorkspaceCode           NVARCHAR(64)  = NULL,
    @Category                NVARCHAR(64)  = NULL,
    @ClassificationCode      NVARCHAR(32)  = NULL,
    @GovernanceStatusCode    NVARCHAR(32)  = NULL,
    @DatasetStatus           NVARCHAR(16)  = NULL,
    @CertificationStatusCode NVARCHAR(32)  = NULL,
    @OwnerUserName           NVARCHAR(128) = NULL,
    @StewardUserName         NVARCHAR(128) = NULL,
    @SourceTypeCode          NVARCHAR(32)  = NULL,
    @MinQualityScore         DECIMAL(5,2)  = NULL,
    @MaxQualityScore         DECIMAL(5,2)  = NULL,
    @CreatedFrom             DATETIME2(3)  = NULL,
    @CreatedTo               DATETIME2(3)  = NULL,
    @UpdatedFrom             DATETIME2(3)  = NULL,
    @UpdatedTo               DATETIME2(3)  = NULL,
    @Tags                    NVARCHAR(1000) = NULL,  -- comma-separated
    @TagMatch                NVARCHAR(8)   = N'Any', -- Any | All
    @IncludeInactive         BIT           = 0,
    @SortBy                  NVARCHAR(32)  = NULL,   -- default: Relevance when searching, else Name
    @SortDirection           NVARCHAR(4)   = NULL,   -- ASC | DESC (default per sort)
    @PageNumber              INT           = 1,
    @PageSize                INT           = 25,     -- 1..200
    @AfterValue              NVARCHAR(200) = NULL,   -- keyset: sort value of the last row
    @AfterDatasetId          UNIQUEIDENTIFIER = NULL,-- keyset: DatasetId of the last row
    @IncludeTotalCount       BIT           = 1,
    @TotalCount              INT           = NULL OUTPUT,  -- NULL when not requested
    @HasMore                 BIT           = NULL OUTPUT,
    @NextAfterValue          NVARCHAR(200) = NULL OUTPUT,  -- keyset-capable sorts only
    @NextAfterDatasetId      UNIQUEIDENTIFIER = NULL OUTPUT,
    @AppliedSortBy           NVARCHAR(32)  = NULL OUTPUT,
    @AppliedSortDirection    NVARCHAR(4)   = NULL OUTPUT,
    @StatusCode              NVARCHAR(32)  = NULL OUTPUT,
    @StatusMessage           NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @StatusCode = NULL; SET @StatusMessage = NULL;
    SET @TotalCount = NULL; SET @HasMore = NULL; SET @NextAfterValue = NULL; SET @NextAfterDatasetId = NULL;
    SET @AppliedSortBy = NULL; SET @AppliedSortDirection = NULL;

    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END

    -- ---------------- search text ----------------
    DECLARE @Term NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@SearchText)), N'');
    DECLARE @Escaped NVARCHAR(210) =
        REPLACE(REPLACE(REPLACE(@Term, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]');
    DECLARE @Contains NVARCHAR(210) = CASE WHEN @Term IS NULL THEN NULL ELSE N'%' + @Escaped + N'%' END;
    DECLARE @Prefix NVARCHAR(210) = CASE WHEN @Term IS NULL THEN NULL ELSE @Escaped + N'%' END;

    -- ---------------- sort ----------------
    DECLARE @SortKey NVARCHAR(32), @DefaultDir NVARCHAR(4), @KeysetCapable BIT;
    SELECT @SortKey = s.SortKey, @DefaultDir = s.DefaultDir, @KeysetCapable = s.KeysetCapable
    FROM (VALUES
        (N'Relevance',        N'DESC', 0),
        (N'Name',             N'ASC',  1),
        (N'Code',             N'ASC',  1),
        (N'CreatedDate',      N'DESC', 1),
        (N'UpdatedDate',      N'DESC', 1),
        (N'QualityScore',     N'DESC', 0),
        (N'LastImportDate',   N'DESC', 0),
        (N'Classification',   N'ASC',  0),
        (N'GovernanceStatus', N'ASC',  0)
    ) s (SortKey, DefaultDir, KeysetCapable)
    WHERE s.SortKey = COALESCE(NULLIF(LTRIM(RTRIM(@SortBy)), N''), CASE WHEN @Term IS NULL THEN N'Name' ELSE N'Relevance' END);

    IF @SortKey IS NULL
    BEGIN
        SET @StatusCode = N'InvalidSort';
        SET @StatusMessage = N'SortBy must be one of Relevance, Name, Code, CreatedDate, UpdatedDate, QualityScore, LastImportDate, Classification, GovernanceStatus.';
        RETURN;
    END
    IF @SortKey = N'Relevance' AND @Term IS NULL
    BEGIN SET @StatusCode = N'InvalidSort'; SET @StatusMessage = N'Relevance sort requires search text.'; RETURN; END

    DECLARE @Dir NVARCHAR(4) = UPPER(COALESCE(NULLIF(LTRIM(RTRIM(@SortDirection)), N''), @DefaultDir));
    IF @Dir NOT IN (N'ASC', N'DESC')
    BEGIN SET @StatusCode = N'InvalidSort'; SET @StatusMessage = N'SortDirection must be ASC or DESC.'; RETURN; END
    IF @SortKey = N'Relevance' SET @Dir = N'DESC';
    DECLARE @Asc BIT = IIF(@Dir = N'ASC', 1, 0);

    -- ---------------- paging ----------------
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 25;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    DECLARE @UseKeyset BIT = IIF(@AfterDatasetId IS NOT NULL, 1, 0);
    DECLARE @AfterText NVARCHAR(200) = NULL, @AfterDate DATETIME2(3) = NULL;
    IF @UseKeyset = 1
    BEGIN
        IF @KeysetCapable = 0
        BEGIN SET @StatusCode = N'InvalidPaging'; SET @StatusMessage = N'Keyset paging supports Name, Code, CreatedDate and UpdatedDate sorts only.'; RETURN; END
        IF @PageNumber > 1
        BEGIN SET @StatusCode = N'InvalidPaging'; SET @StatusMessage = N'Use either PageNumber or AfterValue/AfterDatasetId, not both.'; RETURN; END
        IF @AfterValue IS NULL
        BEGIN SET @StatusCode = N'InvalidPaging'; SET @StatusMessage = N'AfterValue is required with AfterDatasetId.'; RETURN; END
        IF @SortKey IN (N'CreatedDate', N'UpdatedDate')
        BEGIN
            SET @AfterDate = TRY_CONVERT(DATETIME2(3), @AfterValue, 126);
            IF @AfterDate IS NULL
            BEGIN SET @StatusCode = N'InvalidPaging'; SET @StatusMessage = N'AfterValue must be an ISO-8601 date for date sorts.'; RETURN; END
        END
        ELSE SET @AfterText = @AfterValue;
    END
    DECLARE @Offset INT = IIF(@UseKeyset = 1, 0, (@PageNumber - 1) * @PageSize);

    -- ---------------- filters ----------------
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = NULL, @OwnerUserId UNIQUEIDENTIFIER = NULL,
            @OwnerName NVARCHAR(128) = NULL, @StewardUserId UNIQUEIDENTIFIER = NULL;

    IF @WorkspaceCode IS NOT NULL
    BEGIN
        SELECT @WorkspaceId = WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode;
        IF @WorkspaceId IS NULL
        BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Unknown workspace code.'; RETURN; END
    END
    IF @ClassificationCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gov.Classification WHERE ClassificationCode = @ClassificationCode)
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Unknown classification.'; RETURN; END
    IF @GovernanceStatusCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gov.GovernanceStatus WHERE StatusCode = @GovernanceStatusCode)
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Unknown governance status.'; RETURN; END
    IF @CertificationStatusCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gov.CertificationStatus WHERE StatusCode = @CertificationStatusCode)
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Unknown certification status.'; RETURN; END
    IF @DatasetStatus IS NOT NULL AND @DatasetStatus NOT IN (N'Active', N'Inactive', N'Draft', N'Archived', N'Deprecated')
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'DatasetStatus must be Active, Inactive, Draft, Archived or Deprecated.'; RETURN; END
    IF @SourceTypeCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM reg.DataSourceType WHERE TypeCode = @SourceTypeCode)
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Unknown source type.'; RETURN; END
    IF @OwnerUserName IS NOT NULL
    BEGIN
        SELECT @OwnerUserId = UserId FROM gov.AppUser WHERE UserName = @OwnerUserName;
        IF @OwnerUserId IS NULL SET @OwnerName = @OwnerUserName;   -- legacy text owner
    END
    IF @StewardUserName IS NOT NULL
    BEGIN
        SELECT @StewardUserId = UserId FROM gov.AppUser WHERE UserName = @StewardUserName;
        IF @StewardUserId IS NULL
        BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Unknown steward user.'; RETURN; END
    END
    IF (@MinQualityScore IS NOT NULL AND (@MinQualityScore < 0 OR @MinQualityScore > 100))
       OR (@MaxQualityScore IS NOT NULL AND (@MaxQualityScore < 0 OR @MaxQualityScore > 100))
       OR (@MinQualityScore > @MaxQualityScore)
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Quality score range must be within 0-100 and min <= max.'; RETURN; END
    IF @CreatedFrom > @CreatedTo OR @UpdatedFrom > @UpdatedTo
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'Date range start must be before its end.'; RETURN; END

    DECLARE @TagMatchAll BIT =
        CASE UPPER(ISNULL(@TagMatch, N'ANY')) WHEN N'ANY' THEN 0 WHEN N'ALL' THEN 1 END;
    IF @TagMatchAll IS NULL
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'TagMatch must be Any or All.'; RETURN; END

    DECLARE @TagList NVARCHAR(1000) = NULL, @TagCount INT = 0;
    SELECT @TagList = STRING_AGG(TagName, N',') WITHIN GROUP (ORDER BY TagName), @TagCount = COUNT(*)
    FROM cat.fn_ParseTagList(@Tags);
    IF @TagCount > 10
    BEGIN SET @StatusCode = N'InvalidFilter'; SET @StatusMessage = N'At most 10 tags can be filtered.'; RETURN; END

    -- Archived / inactive filters imply including non-current datasets
    IF @DatasetStatus IN (N'Inactive', N'Archived') OR @GovernanceStatusCode = N'Archived'
        SET @IncludeInactive = 1;

    DECLARE @NeedLastImport BIT = IIF(@SortKey = N'LastImportDate', 1, 0);

    -- ---------------- total ----------------
    IF @IncludeTotalCount = 1
        SELECT @TotalCount = COUNT(*)
        FROM cat.fn_CatalogSearch(@UserId, @IsAdmin, @IncludeInactive, @Term, @Contains, @Prefix, @WorkspaceId, @Category,
             @ClassificationCode, @GovernanceStatusCode, @DatasetStatus, @CertificationStatusCode, @OwnerUserId,
             @OwnerName, @StewardUserId, @SourceTypeCode, @MinQualityScore, @MaxQualityScore, @CreatedFrom,
             @CreatedTo, @UpdatedFrom, @UpdatedTo, @TagList, @TagCount, @TagMatchAll, 0) s
        OPTION (RECOMPILE);

    -- ---------------- page (keys only, PageSize + 1 to detect more) ----------------
    DECLARE @Page TABLE
    (
        RowNum INT IDENTITY(1,1) PRIMARY KEY,
        DatasetId UNIQUEIDENTIFIER NOT NULL,
        DisplayName NVARCHAR(200) NOT NULL,
        DatasetCode NVARCHAR(64) NOT NULL,
        CreatedUtc DATETIME2(3) NOT NULL,
        ModifiedUtc DATETIME2(3) NOT NULL,
        WorkspaceId UNIQUEIDENTIFIER NULL,
        ClassificationCode NVARCHAR(32) NOT NULL,
        GovernanceStatusCode NVARCHAR(32) NOT NULL,
        CertificationStatusCode NVARCHAR(32) NOT NULL,
        OwnerUserId UNIQUEIDENTIFIER NULL,
        StewardUserId UNIQUEIDENTIFIER NULL,
        AccessSource NVARCHAR(32) NOT NULL,
        EffectiveAccessLevel NVARCHAR(32) NULL,
        CanReadData BIT NOT NULL,
        CanRequestAccess BIT NOT NULL,
        QualityScore DECIMAL(5,2) NULL,
        RelevanceScore INT NOT NULL
    );

    DECLARE @Take INT = @PageSize + 1;

    INSERT INTO @Page (DatasetId, DisplayName, DatasetCode, CreatedUtc, ModifiedUtc, WorkspaceId, ClassificationCode,
                       GovernanceStatusCode, CertificationStatusCode, OwnerUserId, StewardUserId, AccessSource,
                       EffectiveAccessLevel, CanReadData, CanRequestAccess, QualityScore, RelevanceScore)
    SELECT s.DatasetId, s.DisplayName, s.DatasetCode, s.CreatedUtc, s.ModifiedUtc, s.WorkspaceId, s.ClassificationCode,
           s.GovernanceStatusCode, s.CertificationStatusCode, s.OwnerUserId, s.StewardUserId, s.AccessSource,
           s.EffectiveAccessLevel, s.CanReadData, s.CanRequestAccess, s.QualityScore, s.RelevanceScore
    FROM cat.fn_CatalogSearch(@UserId, @IsAdmin, @IncludeInactive, @Term, @Contains, @Prefix, @WorkspaceId, @Category,
         @ClassificationCode, @GovernanceStatusCode, @DatasetStatus, @CertificationStatusCode, @OwnerUserId,
         @OwnerName, @StewardUserId, @SourceTypeCode, @MinQualityScore, @MaxQualityScore, @CreatedFrom,
         @CreatedTo, @UpdatedFrom, @UpdatedTo, @TagList, @TagCount, @TagMatchAll, @NeedLastImport) s
    WHERE @UseKeyset = 0
       OR (@SortKey = N'Name' AND @Asc = 1 AND (s.DisplayName > @AfterText OR (s.DisplayName = @AfterText AND s.DatasetId > @AfterDatasetId)))
       OR (@SortKey = N'Name' AND @Asc = 0 AND (s.DisplayName < @AfterText OR (s.DisplayName = @AfterText AND s.DatasetId < @AfterDatasetId)))
       OR (@SortKey = N'Code' AND @Asc = 1 AND (s.DatasetCode > @AfterText OR (s.DatasetCode = @AfterText AND s.DatasetId > @AfterDatasetId)))
       OR (@SortKey = N'Code' AND @Asc = 0 AND (s.DatasetCode < @AfterText OR (s.DatasetCode = @AfterText AND s.DatasetId < @AfterDatasetId)))
       OR (@SortKey = N'CreatedDate' AND @Asc = 1 AND (s.CreatedUtc > @AfterDate OR (s.CreatedUtc = @AfterDate AND s.DatasetId > @AfterDatasetId)))
       OR (@SortKey = N'CreatedDate' AND @Asc = 0 AND (s.CreatedUtc < @AfterDate OR (s.CreatedUtc = @AfterDate AND s.DatasetId < @AfterDatasetId)))
       OR (@SortKey = N'UpdatedDate' AND @Asc = 1 AND (s.ModifiedUtc > @AfterDate OR (s.ModifiedUtc = @AfterDate AND s.DatasetId > @AfterDatasetId)))
       OR (@SortKey = N'UpdatedDate' AND @Asc = 0 AND (s.ModifiedUtc < @AfterDate OR (s.ModifiedUtc = @AfterDate AND s.DatasetId < @AfterDatasetId)))
    ORDER BY
        CASE WHEN @SortKey = N'Relevance' THEN s.RelevanceScore END DESC,
        CASE WHEN @SortKey = N'Name' AND @Asc = 1 THEN s.DisplayName END ASC,
        CASE WHEN @SortKey = N'Name' AND @Asc = 0 THEN s.DisplayName END DESC,
        CASE WHEN @SortKey = N'Code' AND @Asc = 1 THEN s.DatasetCode END ASC,
        CASE WHEN @SortKey = N'Code' AND @Asc = 0 THEN s.DatasetCode END DESC,
        CASE WHEN @SortKey = N'CreatedDate' AND @Asc = 1 THEN s.CreatedUtc END ASC,
        CASE WHEN @SortKey = N'CreatedDate' AND @Asc = 0 THEN s.CreatedUtc END DESC,
        CASE WHEN @SortKey = N'UpdatedDate' AND @Asc = 1 THEN s.ModifiedUtc END ASC,
        CASE WHEN @SortKey = N'UpdatedDate' AND @Asc = 0 THEN s.ModifiedUtc END DESC,
        CASE WHEN @SortKey = N'QualityScore' AND @Asc = 1 THEN s.QualityScore END ASC,
        CASE WHEN @SortKey = N'QualityScore' AND @Asc = 0 THEN s.QualityScore END DESC,
        CASE WHEN @SortKey = N'LastImportDate' AND @Asc = 1 THEN s.LastImportUtc END ASC,
        CASE WHEN @SortKey = N'LastImportDate' AND @Asc = 0 THEN s.LastImportUtc END DESC,
        CASE WHEN @SortKey = N'Classification' AND @Asc = 1 THEN s.SensitivityRank END ASC,
        CASE WHEN @SortKey = N'Classification' AND @Asc = 0 THEN s.SensitivityRank END DESC,
        CASE WHEN @SortKey = N'GovernanceStatus' AND @Asc = 1 THEN s.GovernanceSortOrder END ASC,
        CASE WHEN @SortKey = N'GovernanceStatus' AND @Asc = 0 THEN s.GovernanceSortOrder END DESC,
        -- deterministic tie-breakers (keyset sorts tie-break on DatasetId only, in sort direction)
        CASE WHEN @KeysetCapable = 0 THEN s.DisplayName END ASC,
        CASE WHEN @KeysetCapable = 0 OR @Asc = 1 THEN s.DatasetId END ASC,
        CASE WHEN @KeysetCapable = 1 AND @Asc = 0 THEN s.DatasetId END DESC
    OFFSET @Offset ROWS FETCH NEXT @Take ROWS ONLY
    OPTION (RECOMPILE);

    DECLARE @Fetched INT = (SELECT COUNT(*) FROM @Page);
    SET @HasMore = IIF(@Fetched > @PageSize, 1, 0);
    DELETE FROM @Page WHERE RowNum > @PageSize;

    IF @KeysetCapable = 1 AND @HasMore = 1
        SELECT TOP (1) @NextAfterDatasetId = DatasetId,
               @NextAfterValue = CASE @SortKey
                                     WHEN N'Name' THEN DisplayName
                                     WHEN N'Code' THEN DatasetCode
                                     WHEN N'CreatedDate' THEN CONVERT(NVARCHAR(30), CreatedUtc, 126)
                                     WHEN N'UpdatedDate' THEN CONVERT(NVARCHAR(30), ModifiedUtc, 126) END
        FROM @Page ORDER BY RowNum DESC;

    SET @AppliedSortBy = @SortKey;
    SET @AppliedSortDirection = @Dir;
    SET @StatusCode = N'OK';
    SET @StatusMessage = CONCAT(IIF(@HasMore = 1, @PageSize, @Fetched), N' dataset(s) returned (',
                                IIF(@UseKeyset = 1, N'keyset', N'offset'), N' paging).');

    -- ---------------- catalog rows (enriched for the page only) ----------------
    SELECT p.DatasetId, p.DatasetCode, p.DisplayName AS DatasetName, d.Description,
           p.WorkspaceId, w.WorkspaceCode, w.DisplayName AS WorkspaceName, d.Category,
           ou.UserName AS OwnerUserName, COALESCE(ou.DisplayName, d.OwnerName) AS OwnerDisplayName,
           su.UserName AS StewardUserName, su.DisplayName AS StewardDisplayName,
           src.TypeCode AS SourceTypeCode, src.DisplayName AS SourceTypeName,
           p.ClassificationCode, p.GovernanceStatusCode, d.DatasetStatus, p.CertificationStatusCode,
           ver.VersionNumber AS CurrentVersion, p.CreatedUtc, p.ModifiedUtc AS UpdatedUtc,
           p.QualityScore, li.LastImportUtc, tg.Tags,
           p.RelevanceScore, p.AccessSource, p.EffectiveAccessLevel, p.CanReadData, p.CanRequestAccess
    FROM @Page p
    INNER JOIN ingest.Dataset d ON d.DatasetId = p.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = p.WorkspaceId
    LEFT JOIN gov.AppUser ou ON ou.UserId = p.OwnerUserId
    LEFT JOIN gov.AppUser su ON su.UserId = p.StewardUserId
    OUTER APPLY (SELECT TOP (1) v.VersionNumber FROM lineage.DatasetVersion v
                 WHERE v.DatasetId = p.DatasetId ORDER BY v.VersionNumber DESC) ver
    OUTER APPLY (SELECT TOP (1) b.ImportUtc AS LastImportUtc FROM ingest.ImportBatch b
                 WHERE b.DatasetId = p.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')
                 ORDER BY b.ImportUtc DESC) li
    OUTER APPLY (SELECT TOP (1) st.TypeCode, st.DisplayName FROM ingest.ImportBatch b
                 INNER JOIN reg.DataSource ds ON ds.DataSourceId = b.DataSourceId
                 INNER JOIN reg.DataSourceType st ON st.DataSourceTypeId = ds.DataSourceTypeId
                 WHERE b.DatasetId = p.DatasetId AND b.DataSourceId IS NOT NULL
                 ORDER BY b.ImportUtc DESC) src
    OUTER APPLY (SELECT STRING_AGG(t.TagName, N',') WITHIN GROUP (ORDER BY t.TagName) AS Tags
                 FROM cat.DatasetTag dt WITH (FORCESEEK (PK_CatDatasetTag (DatasetId)))
                 INNER JOIN cat.Tag t ON t.TagId = dt.TagId AND t.IsActive = 1
                 WHERE dt.DatasetId = p.DatasetId) tg
    ORDER BY p.RowNum;
END
GO

-- ============================================================
-- Consolidated dataset detail. Undiscoverable and missing datasets
-- both return NotFound so existence is not revealed.
-- Result sets (only when StatusCode = 'OK'), always in this order:
--   1 summary  2 tags  3 recent imports  4 lineage summary
--   5 lineage neighbours  6 version history*  7 certification history*
--   (* empty unless @IncludeHistory = 1)
-- ============================================================
CREATE OR ALTER PROCEDURE cat.usp_GetDatasetDetail
    @DatasetCode          NVARCHAR(64),
    @UserName             NVARCHAR(128),
    @RecentImportCount    INT = 5,    -- 0..50
    @LineageNeighborLimit INT = 20,   -- 0..100
    @IncludeHistory       BIT = 0,
    @HistoryCount         INT = 10,   -- 1..100
    @StatusCode           NVARCHAR(32)  = NULL OUTPUT,
    @StatusMessage        NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @StatusCode = NULL; SET @StatusMessage = NULL;

    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END

    SET @RecentImportCount = CASE WHEN @RecentImportCount IS NULL OR @RecentImportCount < 0 THEN 5
                                  WHEN @RecentImportCount > 50 THEN 50 ELSE @RecentImportCount END;
    SET @LineageNeighborLimit = CASE WHEN @LineageNeighborLimit IS NULL OR @LineageNeighborLimit < 0 THEN 20
                                     WHEN @LineageNeighborLimit > 100 THEN 100 ELSE @LineageNeighborLimit END;
    SET @HistoryCount = CASE WHEN @HistoryCount IS NULL OR @HistoryCount < 1 THEN 10
                             WHEN @HistoryCount > 100 THEN 100 ELSE @HistoryCount END;

    DECLARE @DatasetId UNIQUEIDENTIFIER = (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = @DatasetCode);

    DECLARE @Access TABLE
    (
        WorkspaceId UNIQUEIDENTIFIER NULL, ClassificationCode NVARCHAR(32), GovernanceStatusCode NVARCHAR(32),
        CertificationStatusCode NVARCHAR(32), OwnerUserId UNIQUEIDENTIFIER NULL, StewardUserId UNIQUEIDENTIFIER NULL,
        IsCurrent BIT, WorkspaceRole NVARCHAR(32) NULL, AccessSource NVARCHAR(32), EffectiveAccessLevel NVARCHAR(32) NULL,
        CanReadData BIT, CanRequestAccess BIT
    );
    INSERT INTO @Access
    SELECT a.WorkspaceId, a.ClassificationCode, a.GovernanceStatusCode, a.CertificationStatusCode, a.OwnerUserId,
           a.StewardUserId, a.IsCurrent, a.WorkspaceRole, a.AccessSource, a.EffectiveAccessLevel, a.CanReadData, a.CanRequestAccess
    FROM cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 1) a
    WHERE a.DatasetId = @DatasetId;

    IF @DatasetId IS NULL OR NOT EXISTS (SELECT 1 FROM @Access)
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Dataset not found.'; RETURN; END

    DECLARE @IsPrivileged BIT =
        IIF(EXISTS (SELECT 1 FROM @Access WHERE AccessSource IN (N'PlatformAdmin', N'DatasetOwner', N'DatasetSteward')), 1, 0);

    SET @StatusCode = N'OK';
    SET @StatusMessage = N'Dataset detail returned.';

    -- 1. Summary -------------------------------------------------
    SELECT d.DatasetId, d.DatasetCode, d.DisplayName AS DatasetName, d.Description, d.Category, d.DatasetStatus,
           a.IsCurrent, a.WorkspaceId, w.WorkspaceCode, w.DisplayName AS WorkspaceName,
           d.CreatedUtc, d.ModifiedUtc AS UpdatedUtc,
           -- governance
           a.ClassificationCode, c.DisplayName AS ClassificationName, c.SensitivityRank,
           a.GovernanceStatusCode, a.CertificationStatusCode,
           g.CertifiedUtc, g.CertificationExpiryUtc, g.ReviewDueUtc,
           ou.UserName AS OwnerUserName, COALESCE(ou.DisplayName, d.OwnerName) AS OwnerDisplayName, ou.Email AS OwnerEmail,
           su.UserName AS StewardUserName, su.DisplayName AS StewardDisplayName, su.Email AS StewardEmail,
           -- version
           ver.VersionNumber AS CurrentVersion, ver.ProducedUtc AS CurrentVersionProducedUtc, ver.VersionCount,
           -- source
           src.TypeCode AS SourceTypeCode, src.DisplayName AS SourceTypeName, src.DataSourceName,
           -- quality
           dp.LatestOverallScore AS QualityScore, pr.Grade AS QualityGrade, dp.LatestThresholdResult AS QualityThresholdResult,
           pr.CompletedUtc AS LastProfiledUtc, pr.CompletenessPct, pr.ValidityPct, pr.UniquenessPct, pr.ConsistencyPct,
           pr.IssueCount AS QualityIssueCount,
           -- imports
           imp.LastImportUtc, imp.LastImportStatus, imp.LastImportRecords, ic.ImportCount, ic.FailedImportCount30d,
           -- access (for the requesting user)
           a.AccessSource, a.EffectiveAccessLevel, a.CanReadData, a.CanRequestAccess, a.WorkspaceRole,
           CAST(IIF(EXISTS (SELECT 1 FROM gov.AccessRequest r
                            WHERE r.DatasetId = d.DatasetId AND r.RequestingUserId = @UserId AND r.Status = N'Pending'), 1, 0) AS BIT)
               AS HasPendingAccessRequest,
           -- dataset-wide access counts are only shown to admins/owners/stewards
           CASE WHEN @IsPrivileged = 1 THEN (SELECT COUNT(*) FROM gov.DatasetAccessGrant ga
                                             WHERE ga.DatasetId = d.DatasetId AND ga.IsActive = 1
                                               AND (ga.ExpiresUtc IS NULL OR ga.ExpiresUtc > SYSUTCDATETIME())) END AS ActiveGrantCount,
           CASE WHEN @IsPrivileged = 1 THEN (SELECT COUNT(*) FROM share.DatasetShare s
                                             WHERE s.DatasetId = d.DatasetId AND s.Status = N'Active'
                                               AND (s.ExpiresUtc IS NULL OR s.ExpiresUtc > SYSUTCDATETIME())) END AS ActiveShareCount,
           CASE WHEN @IsPrivileged = 1 THEN (SELECT COUNT(*) FROM gov.AccessRequest r
                                             WHERE r.DatasetId = d.DatasetId AND r.Status = N'Pending') END AS PendingAccessRequestCount
    FROM ingest.Dataset d
    CROSS JOIN @Access a
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    LEFT JOIN gov.Classification c ON c.ClassificationCode = a.ClassificationCode
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = a.WorkspaceId
    LEFT JOIN gov.AppUser ou ON ou.UserId = a.OwnerUserId
    LEFT JOIN gov.AppUser su ON su.UserId = a.StewardUserId
    LEFT JOIN profile.DatasetProfile dp ON dp.DatasetId = d.DatasetId
    LEFT JOIN profile.ProfileRun pr ON pr.ProfileRunId = dp.LatestProfileRunId
    OUTER APPLY (SELECT TOP (1) v.VersionNumber, v.ProducedUtc,
                        (SELECT COUNT(*) FROM lineage.DatasetVersion v2 WHERE v2.DatasetId = d.DatasetId) AS VersionCount
                 FROM lineage.DatasetVersion v WHERE v.DatasetId = d.DatasetId ORDER BY v.VersionNumber DESC) ver
    OUTER APPLY (SELECT TOP (1) st.TypeCode, st.DisplayName, ds.Name AS DataSourceName
                 FROM ingest.ImportBatch b
                 INNER JOIN reg.DataSource ds ON ds.DataSourceId = b.DataSourceId
                 INNER JOIN reg.DataSourceType st ON st.DataSourceTypeId = ds.DataSourceTypeId
                 WHERE b.DatasetId = d.DatasetId AND b.DataSourceId IS NOT NULL
                 ORDER BY b.ImportUtc DESC) src
    OUTER APPLY (SELECT TOP (1) b.ImportUtc AS LastImportUtc, b.Status AS LastImportStatus, b.TotalRecords AS LastImportRecords
                 FROM ingest.ImportBatch b
                 WHERE b.DatasetId = d.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')
                 ORDER BY b.ImportUtc DESC) imp
    OUTER APPLY (SELECT COUNT(*) AS ImportCount,
                        SUM(CASE WHEN b.Status = N'Failed' AND b.ImportUtc >= DATEADD(DAY, -30, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS FailedImportCount30d
                 FROM ingest.ImportBatch b WHERE b.DatasetId = d.DatasetId) ic
    WHERE d.DatasetId = @DatasetId;

    -- 2. Tags ----------------------------------------------------
    SELECT t.TagName, t.Description, dt.TaggedUtc, tu.UserName AS TaggedByUserName
    FROM cat.DatasetTag dt
    INNER JOIN cat.Tag t ON t.TagId = dt.TagId AND t.IsActive = 1
    LEFT JOIN gov.AppUser tu ON tu.UserId = dt.TaggedByUserId
    WHERE dt.DatasetId = @DatasetId
    ORDER BY t.TagName;

    -- 3. Recent imports (latest N only) ---------------------------
    SELECT TOP (@RecentImportCount)
           b.BatchId, b.ImportUtc, b.Status, b.TotalRecords, b.ValidRecords, b.RejectedRecords, b.ErrorCount,
           b.CompletedUtc, ds.Name AS DataSourceName, st.TypeCode AS SourceTypeCode
    FROM ingest.ImportBatch b
    LEFT JOIN reg.DataSource ds ON ds.DataSourceId = b.DataSourceId
    LEFT JOIN reg.DataSourceType st ON st.DataSourceTypeId = ds.DataSourceTypeId
    WHERE b.DatasetId = @DatasetId
    ORDER BY b.ImportUtc DESC, b.BatchId;

    -- 4/5. Lineage: the dataset's pipeline entities form the core;
    -- edges from non-core entities are upstream, edges to non-core
    -- entities (reports, analytics assets, other datasets) downstream.
    DECLARE @Core TABLE (EntityId UNIQUEIDENTIFIER PRIMARY KEY);
    INSERT INTO @Core (EntityId)
    SELECT e.EntityId FROM lineage.LineageEntity e
    WHERE e.DatasetId = @DatasetId
      AND e.EntityTypeCode IN (N'Dataset', N'DatasetVersion', N'Import', N'Transformation', N'QualityProfileRun');

    DECLARE @Edges TABLE
    (
        Direction NVARCHAR(10), RelationshipType NVARCHAR(64), NeighborEntityId UNIQUEIDENTIFIER, CreatedUtc DATETIME2(3)
    );
    INSERT INTO @Edges (Direction, RelationshipType, NeighborEntityId, CreatedUtc)
    SELECT N'Upstream', r.RelationshipType, r.SourceEntityId, r.CreatedUtc
    FROM lineage.LineageRelationship r
    INNER JOIN @Core c ON c.EntityId = r.TargetEntityId
    WHERE r.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM @Core c2 WHERE c2.EntityId = r.SourceEntityId)
    UNION ALL
    SELECT N'Downstream', r.RelationshipType, r.TargetEntityId, r.CreatedUtc
    FROM lineage.LineageRelationship r
    INNER JOIN @Core c ON c.EntityId = r.SourceEntityId
    WHERE r.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM @Core c2 WHERE c2.EntityId = r.TargetEntityId);

    SELECT (SELECT COUNT(*) FROM @Core) AS PipelineEntityCount,
           COUNT(DISTINCT CASE WHEN x.Direction = N'Upstream' THEN x.NeighborEntityId END) AS UpstreamEntityCount,
           COUNT(DISTINCT CASE WHEN x.Direction = N'Downstream' THEN x.NeighborEntityId END) AS DownstreamEntityCount,
           COUNT(DISTINCT CASE WHEN x.Direction = N'Upstream' AND e.EntityTypeCode = N'DataSource' THEN x.NeighborEntityId END) AS UpstreamSourceCount,
           COUNT(DISTINCT CASE WHEN e.EntityTypeCode = N'Dataset' AND x.Direction = N'Upstream' THEN x.NeighborEntityId END) AS UpstreamDatasetCount,
           COUNT(DISTINCT CASE WHEN e.EntityTypeCode = N'Dataset' AND x.Direction = N'Downstream' THEN x.NeighborEntityId END) AS DownstreamDatasetCount,
           COUNT(DISTINCT CASE WHEN e.EntityTypeCode IN (N'Report', N'AnalyticsAsset') THEN x.NeighborEntityId END) AS ConsumerAssetCount,
           MAX(x.CreatedUtc) AS LastLineageUtc
    FROM @Edges x
    LEFT JOIN lineage.LineageEntity e ON e.EntityId = x.NeighborEntityId;

    SELECT TOP (@LineageNeighborLimit)
           x.Direction, x.RelationshipType, e.EntityTypeCode, e.EntityCode, e.DisplayName,
           nd.DatasetCode AS NeighborDatasetCode, COUNT(*) AS EdgeCount, MAX(x.CreatedUtc) AS LastSeenUtc
    FROM @Edges x
    INNER JOIN lineage.LineageEntity e ON e.EntityId = x.NeighborEntityId
    LEFT JOIN ingest.Dataset nd ON nd.DatasetId = e.DatasetId AND e.DatasetId <> @DatasetId
    GROUP BY x.Direction, x.RelationshipType, e.EntityTypeCode, e.EntityCode, e.DisplayName, nd.DatasetCode
    ORDER BY x.Direction DESC, MAX(x.CreatedUtc) DESC, e.EntityCode;

    -- 6. Version history (opt-in) ---------------------------------
    SELECT TOP (@HistoryCount)
           v.DatasetVersionId, v.VersionNumber, v.ProducedUtc, v.ProducedBy, v.ImportBatchId, v.EtlRunId, v.ProfileRunId, v.Notes
    FROM lineage.DatasetVersion v
    WHERE @IncludeHistory = 1 AND v.DatasetId = @DatasetId
    ORDER BY v.VersionNumber DESC;

    -- 7. Certification history (opt-in) ---------------------------
    SELECT TOP (@HistoryCount)
           h.HistoryId, h.ActionUtc, h.PreviousGovStatus, h.NewGovStatus, h.PreviousCertStatus, h.NewCertStatus,
           au.UserName AS ActionedByUserName, h.Comments
    FROM gov.CertificationHistory h
    LEFT JOIN gov.AppUser au ON au.UserId = h.ActionedByUserId
    WHERE @IncludeHistory = 1 AND h.DatasetId = @DatasetId
    ORDER BY h.ActionUtc DESC, h.HistoryId DESC;
END
GO

-- ============================================================
-- Tags
-- ============================================================

-- Tags with the number of datasets the user can discover
CREATE OR ALTER PROCEDURE cat.usp_GetTags
    @UserName      NVARCHAR(128),
    @Search        NVARCHAR(64) = NULL,
    @IncludeUnused BIT = 0,
    @StatusCode    NVARCHAR(32)  = NULL OUTPUT,
    @StatusMessage NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END

    DECLARE @Pattern NVARCHAR(80) = N'%' + REPLACE(REPLACE(REPLACE(LOWER(LTRIM(RTRIM(@Search))), N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%';

    SET @StatusCode = N'OK'; SET @StatusMessage = N'Tags returned.';

    SELECT t.TagId, t.TagName, t.Description, COUNT(a.DatasetId) AS DatasetCount
    FROM cat.Tag t
    LEFT JOIN cat.DatasetTag dt ON dt.TagId = t.TagId
    LEFT JOIN cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a ON a.DatasetId = dt.DatasetId
    WHERE t.IsActive = 1
      AND (@Search IS NULL OR t.TagName LIKE @Pattern)
    GROUP BY t.TagId, t.TagName, t.Description
    HAVING @IncludeUnused = 1 OR COUNT(a.DatasetId) > 0
    ORDER BY COUNT(a.DatasetId) DESC, t.TagName;
END
GO

-- Adds tags to a dataset (creates missing tags). Same managers as sharing.
CREATE OR ALTER PROCEDURE cat.usp_AddDatasetTags
    @DatasetCode   NVARCHAR(64),
    @Tags          NVARCHAR(1000),
    @UserName      NVARCHAR(128),
    @StatusCode    NVARCHAR(32)  = NULL OUTPUT,
    @StatusMessage NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @DatasetId = d.DatasetId, @WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId)
    FROM ingest.Dataset d LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    WHERE d.DatasetCode = @DatasetCode;
    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'InvalidDataset'; SET @StatusMessage = N'Dataset not found.'; RETURN; END

    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM share.fn_CanManageDatasetShares(@DatasetId, @UserId) WHERE CanManage = 1)
    BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Only platform admins, dataset owners/stewards, or workspace admins/owners/stewards can tag this dataset.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM cat.fn_ParseTagList(@Tags))
    BEGIN SET @StatusCode = N'InvalidTag'; SET @StatusMessage = N'At least one tag is required.'; RETURN; END
    IF (SELECT COUNT(*) FROM cat.fn_ParseTagList(@Tags)) > 20
       OR EXISTS (SELECT 1 FROM cat.fn_ParseTagList(@Tags) WHERE LEN(TagName) > 64 OR TagName LIKE N'%[^a-z0-9._-]%')
    BEGIN SET @StatusCode = N'InvalidTag'; SET @StatusMessage = N'Up to 20 tags; each 1-64 characters of a-z, 0-9, dot, underscore or hyphen.'; RETURN; END

    DECLARE @New TABLE (TagName NVARCHAR(64) PRIMARY KEY);
    INSERT INTO @New (TagName) SELECT TagName FROM cat.fn_ParseTagList(@Tags);

    DECLARE @Added TABLE (TagId INT);

    BEGIN TRANSACTION;

    INSERT INTO cat.Tag (TagName, CreatedByUserId)
    SELECT n.TagName, @UserId FROM @New n
    WHERE NOT EXISTS (SELECT 1 FROM cat.Tag t WITH (UPDLOCK, HOLDLOCK) WHERE t.TagName = n.TagName);

    UPDATE t SET IsActive = 1 FROM cat.Tag t INNER JOIN @New n ON n.TagName = t.TagName WHERE t.IsActive = 0;

    INSERT INTO cat.DatasetTag (DatasetId, TagId, TaggedByUserId)
    OUTPUT inserted.TagId INTO @Added (TagId)
    SELECT @DatasetId, t.TagId, @UserId
    FROM @New n INNER JOIN cat.Tag t ON t.TagName = n.TagName
    WHERE NOT EXISTS (SELECT 1 FROM cat.DatasetTag dt WHERE dt.DatasetId = @DatasetId AND dt.TagId = t.TagId);

    IF EXISTS (SELECT 1 FROM @Added)
    BEGIN
        DECLARE @Details NVARCHAR(MAX) =
            (SELECT (SELECT STRING_AGG(t.TagName, N',') WITHIN GROUP (ORDER BY t.TagName)
                     FROM @Added x INNER JOIN cat.Tag t ON t.TagId = x.TagId) AS tags
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC gov.usp_WriteAudit @EventType = N'DatasetTagged', @DatasetId = @DatasetId, @ActorUserId = @UserId,
             @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;
    END

    COMMIT TRANSACTION;

    IF EXISTS (SELECT 1 FROM @Added)
    BEGIN SET @StatusCode = N'Tagged'; SET @StatusMessage = CONCAT((SELECT COUNT(*) FROM @Added), N' tag(s) added.'); END
    ELSE
    BEGIN SET @StatusCode = N'NoChange'; SET @StatusMessage = N'Dataset already has these tags.'; END

    SELECT t.TagName FROM cat.DatasetTag dt INNER JOIN cat.Tag t ON t.TagId = dt.TagId
    WHERE dt.DatasetId = @DatasetId ORDER BY t.TagName;
END
GO

CREATE OR ALTER PROCEDURE cat.usp_RemoveDatasetTags
    @DatasetCode   NVARCHAR(64),
    @Tags          NVARCHAR(1000),
    @UserName      NVARCHAR(128),
    @StatusCode    NVARCHAR(32)  = NULL OUTPUT,
    @StatusMessage NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @DatasetId = d.DatasetId, @WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId)
    FROM ingest.Dataset d LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    WHERE d.DatasetCode = @DatasetCode;
    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'InvalidDataset'; SET @StatusMessage = N'Dataset not found.'; RETURN; END

    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM share.fn_CanManageDatasetShares(@DatasetId, @UserId) WHERE CanManage = 1)
    BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Only platform admins, dataset owners/stewards, or workspace admins/owners/stewards can untag this dataset.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM cat.fn_ParseTagList(@Tags))
    BEGIN SET @StatusCode = N'InvalidTag'; SET @StatusMessage = N'At least one tag is required.'; RETURN; END

    DECLARE @Removed TABLE (TagName NVARCHAR(64));

    BEGIN TRANSACTION;

    DELETE dt
    OUTPUT t.TagName INTO @Removed (TagName)
    FROM cat.DatasetTag dt
    INNER JOIN cat.Tag t ON t.TagId = dt.TagId
    INNER JOIN cat.fn_ParseTagList(@Tags) p ON p.TagName = t.TagName
    WHERE dt.DatasetId = @DatasetId;

    IF EXISTS (SELECT 1 FROM @Removed)
    BEGIN
        DECLARE @Details NVARCHAR(MAX) =
            (SELECT (SELECT STRING_AGG(TagName, N',') FROM @Removed) AS tags FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC gov.usp_WriteAudit @EventType = N'DatasetUntagged', @DatasetId = @DatasetId, @ActorUserId = @UserId,
             @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;
    END

    COMMIT TRANSACTION;

    IF EXISTS (SELECT 1 FROM @Removed)
    BEGIN SET @StatusCode = N'Untagged'; SET @StatusMessage = CONCAT((SELECT COUNT(*) FROM @Removed), N' tag(s) removed.'); END
    ELSE
    BEGIN SET @StatusCode = N'NoChange'; SET @StatusMessage = N'Dataset did not have these tags.'; END

    SELECT t.TagName FROM cat.DatasetTag dt INNER JOIN cat.Tag t ON t.TagId = dt.TagId
    WHERE dt.DatasetId = @DatasetId ORDER BY t.TagName;
END
GO

-- ============================================================
-- Catalog summary reports (access-aware).
-- @UserName is required; unknown/inactive users get zero counts /
-- empty lists. @WorkspaceCode optionally scopes to one workspace.
-- ============================================================
CREATE OR ALTER PROCEDURE rpt.usp_CatalogSummary
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);
    DECLARE @Since7 DATETIME2(3) = DATEADD(DAY, -7, SYSUTCDATETIME());

    SELECT COUNT(*)                                                           AS TotalDiscoverable,
           ISNULL(SUM(IIF(a.CanReadData = 1, 1, 0)), 0)                       AS ReadableCount,
           ISNULL(SUM(IIF(a.CanReadData = 0, 1, 0)), 0)                       AS MetadataOnlyCount,
           ISNULL(SUM(IIF(a.CertificationStatusCode = N'Certified', 1, 0)), 0) AS CertifiedCount,
           ISNULL(SUM(IIF(a.CertificationStatusCode <> N'Certified', 1, 0)), 0) AS UncertifiedCount,
           ISNULL(SUM(IIF(dp.LatestOverallScore IS NOT NULL, 1, 0)), 0)        AS ProfiledCount,
           CAST(AVG(dp.LatestOverallScore) AS DECIMAL(5,2))                    AS AvgQualityScore,
           ISNULL(SUM(tg.IsTagged), 0)                                         AS TaggedCount,
           COUNT(DISTINCT a.WorkspaceId)                                       AS WorkspaceCount,
           ISNULL(SUM(IIF(d.ModifiedUtc >= @Since7, 1, 0)), 0)                 AS UpdatedLast7Days,
           ISNULL(SUM(IIF(li.LastImportUtc >= @Since7, 1, 0)), 0)              AS ImportedLast7Days,
           ISNULL(SUM(IIF(d.DatasetStatus = N'Deprecated', 1, 0)), 0)          AS DeprecatedCount
    FROM cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
    INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
    LEFT JOIN profile.DatasetProfile dp ON dp.DatasetId = a.DatasetId
    OUTER APPLY (SELECT TOP (1) b.ImportUtc AS LastImportUtc FROM ingest.ImportBatch b
                 WHERE b.DatasetId = a.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')
                 ORDER BY b.ImportUtc DESC) li
    OUTER APPLY (SELECT TOP (1) 1 AS IsTagged FROM cat.DatasetTag dt WHERE dt.DatasetId = a.DatasetId) tg
    WHERE (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_CatalogByClassification
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);

    SELECT c.ClassificationCode AS [Key], c.DisplayName AS Name, c.SensitivityRank AS SortOrder,
           COUNT(a.DatasetId) AS DatasetCount
    FROM gov.Classification c
    LEFT JOIN cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
           ON a.ClassificationCode = c.ClassificationCode
          AND (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    WHERE c.IsActive = 1
    GROUP BY c.ClassificationCode, c.DisplayName, c.SensitivityRank
    ORDER BY c.SensitivityRank
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_CatalogByGovernanceStatus
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);

    SELECT s.StatusCode AS [Key], s.DisplayName AS Name, s.SortOrder,
           COUNT(a.DatasetId) AS DatasetCount
    FROM gov.GovernanceStatus s
    LEFT JOIN cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
           ON a.GovernanceStatusCode = s.StatusCode
          AND (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    WHERE s.IsActive = 1
    GROUP BY s.StatusCode, s.DisplayName, s.SortOrder
    ORDER BY s.SortOrder
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_CatalogByCategory
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);

    SELECT d.Category AS [Key], d.Category AS Name,
           ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, d.Category) AS SortOrder,
           COUNT(*) AS DatasetCount,
           SUM(IIF(a.CertificationStatusCode = N'Certified', 1, 0)) AS CertifiedCount,
           CAST(AVG(dp.LatestOverallScore) AS DECIMAL(5,2)) AS AvgQualityScore
    FROM cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
    INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
    LEFT JOIN profile.DatasetProfile dp ON dp.DatasetId = a.DatasetId
    WHERE (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    GROUP BY d.Category
    ORDER BY DatasetCount DESC, d.Category
    OPTION (RECOMPILE);
END
GO

-- Certified vs uncertified, broken down by certification status
CREATE OR ALTER PROCEDURE rpt.usp_CatalogCertification
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);

    SELECT CASE WHEN s.StatusCode = N'Certified' THEN N'Certified' ELSE N'Uncertified' END AS CertificationGroup,
           s.StatusCode AS [Key], s.DisplayName AS Name,
           COUNT(a.DatasetId) AS DatasetCount,
           CAST(100.0 * COUNT(a.DatasetId) / NULLIF(SUM(COUNT(a.DatasetId)) OVER (), 0) AS DECIMAL(5,2)) AS Pct
    FROM gov.CertificationStatus s
    LEFT JOIN cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
           ON a.CertificationStatusCode = s.StatusCode
          AND (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    WHERE s.IsActive = 1
    GROUP BY s.StatusCode, s.DisplayName
    ORDER BY CASE WHEN s.StatusCode = N'Certified' THEN 0 ELSE 1 END, s.StatusCode
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_CatalogQualityDistribution
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);

    WITH buckets AS (
        SELECT * FROM (VALUES
            (1, N'Excellent',   CAST(90 AS DECIMAL(5,2)), CAST(100 AS DECIMAL(5,2))),
            (2, N'Good',        CAST(75 AS DECIMAL(5,2)), CAST(89.99 AS DECIMAL(5,2))),
            (3, N'Fair',        CAST(50 AS DECIMAL(5,2)), CAST(74.99 AS DECIMAL(5,2))),
            (4, N'Poor',        CAST(0 AS DECIMAL(5,2)),  CAST(49.99 AS DECIMAL(5,2))),
            (5, N'NotProfiled', NULL, NULL)
        ) b (SortOrder, Bucket, MinScore, MaxScore)
    ),
    scored AS (
        SELECT CASE WHEN dp.LatestOverallScore IS NULL THEN N'NotProfiled'
                    WHEN dp.LatestOverallScore >= 90 THEN N'Excellent'
                    WHEN dp.LatestOverallScore >= 75 THEN N'Good'
                    WHEN dp.LatestOverallScore >= 50 THEN N'Fair'
                    ELSE N'Poor' END AS Bucket
        FROM cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
        LEFT JOIN profile.DatasetProfile dp ON dp.DatasetId = a.DatasetId
        WHERE (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    )
    SELECT b.Bucket, b.MinScore, b.MaxScore, b.SortOrder, COUNT(s.Bucket) AS DatasetCount
    FROM buckets b
    LEFT JOIN scored s ON s.Bucket = b.Bucket
    GROUP BY b.Bucket, b.MinScore, b.MaxScore, b.SortOrder
    ORDER BY b.SortOrder
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_CatalogRecentlyUpdated
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL,
    @Days          INT = 30,
    @Top           INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);
    IF @Days IS NULL OR @Days < 1 SET @Days = 30;
    IF @Top IS NULL OR @Top < 1 SET @Top = 10;
    IF @Top > 100 SET @Top = 100;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());

    SELECT TOP (@Top)
           d.DatasetCode, d.DisplayName AS DatasetName, w.WorkspaceCode, d.Category,
           a.ClassificationCode, a.GovernanceStatusCode, a.CertificationStatusCode,
           d.ModifiedUtc AS UpdatedUtc, a.AccessSource, a.CanReadData
    FROM cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
    INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = a.WorkspaceId
    WHERE d.ModifiedUtc >= @Since
      AND (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    ORDER BY d.ModifiedUtc DESC, d.DatasetId
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_CatalogRecentlyImported
    @UserName      NVARCHAR(128),
    @WorkspaceCode NVARCHAR(64) = NULL,
    @Days          INT = 30,
    @Top           INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT = 0;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    DECLARE @WorkspaceId UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = @WorkspaceCode);
    IF @Days IS NULL OR @Days < 1 SET @Days = 30;
    IF @Top IS NULL OR @Top < 1 SET @Top = 10;
    IF @Top > 100 SET @Top = 100;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());

    SELECT TOP (@Top)
           d.DatasetCode, d.DisplayName AS DatasetName, w.WorkspaceCode, d.Category,
           li.ImportUtc AS LastImportUtc, li.Status AS LastImportStatus, li.TotalRecords AS LastImportRecords,
           st.TypeCode AS SourceTypeCode, a.AccessSource, a.CanReadData
    FROM cat.fn_DatasetDiscovery(@UserId, @IsAdmin, 0) a
    INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = a.WorkspaceId
    CROSS APPLY (SELECT TOP (1) b.ImportUtc, b.Status, b.TotalRecords, b.DataSourceId
                 FROM ingest.ImportBatch b
                 WHERE b.DatasetId = a.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')
                 ORDER BY b.ImportUtc DESC) li
    LEFT JOIN reg.DataSource ds ON ds.DataSourceId = li.DataSourceId
    LEFT JOIN reg.DataSourceType st ON st.DataSourceTypeId = ds.DataSourceTypeId
    WHERE li.ImportUtc >= @Since
      AND (@WorkspaceCode IS NULL OR a.WorkspaceId = @WorkspaceId)
    ORDER BY li.ImportUtc DESC, d.DatasetId
    OPTION (RECOMPILE);
END
GO

PRINT 'Catalog procedures ready.';
GO
