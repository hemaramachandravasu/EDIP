-- ============================================================
-- 42_Procs_Governance.sql
-- Governance upsert, certification, access requests, policy
-- evaluation, reporting, expiry, and audit helpers.
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER PROCEDURE gov.usp_WriteAudit
    @EventType        NVARCHAR(64),
    @DatasetId        UNIQUEIDENTIFIER = NULL,
    @UserId           UNIQUEIDENTIFIER = NULL,
    @ActorUserId      UNIQUEIDENTIFIER = NULL,
    @WorkspaceId      UNIQUEIDENTIFIER = NULL,
    @AccessRequestId  UNIQUEIDENTIFIER = NULL,
    @DetailsJson      NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO gov.GovernanceAuditEvent
        (EventType, DatasetId, UserId, ActorUserId, WorkspaceId, AccessRequestId, DetailsJson)
    VALUES
        (@EventType, @DatasetId, @UserId, @ActorUserId, @WorkspaceId, @AccessRequestId, @DetailsJson);
END
GO

CREATE OR ALTER PROCEDURE gov.usp_EnsureDatasetGovernance
    @DatasetId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @DatasetId)
        THROW 51001, 'Dataset not found.', 1;

    IF NOT EXISTS (SELECT 1 FROM gov.DatasetGovernance WHERE DatasetId = @DatasetId)
    BEGIN
        INSERT INTO gov.DatasetGovernance (DatasetId, WorkspaceId, ClassificationCode, GovernanceStatusCode, CertificationStatusCode)
        SELECT d.DatasetId, d.WorkspaceId, N'Internal', N'Draft', N'NotCertified'
        FROM ingest.Dataset d
        WHERE d.DatasetId = @DatasetId;
    END
    ELSE
    BEGIN
        -- Keep workspace pointer aligned with dataset catalog
        UPDATE g
        SET WorkspaceId = d.WorkspaceId,
            ModifiedUtc = SYSUTCDATETIME()
        FROM gov.DatasetGovernance g
        INNER JOIN ingest.Dataset d ON d.DatasetId = g.DatasetId
        WHERE g.DatasetId = @DatasetId
          AND ((g.WorkspaceId IS NULL AND d.WorkspaceId IS NOT NULL)
            OR (g.WorkspaceId IS NOT NULL AND d.WorkspaceId IS NULL)
            OR g.WorkspaceId <> d.WorkspaceId);
    END
END
GO

CREATE OR ALTER PROCEDURE gov.usp_UpsertDatasetGovernance
    @DatasetCode            NVARCHAR(64),
    @ClassificationCode     NVARCHAR(32) = NULL,
    @GovernanceStatusCode   NVARCHAR(32) = NULL,
    @OwnerUserName          NVARCHAR(128) = NULL,
    @StewardUserName        NVARCHAR(128) = NULL,
    @ReviewDueUtc           DATETIME2(3) = NULL,
    @Notes                  NVARCHAR(2000) = NULL,
    @ActorUserName          NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId
    FROM ingest.Dataset WHERE DatasetCode = @DatasetCode AND IsActive = 1;

    IF @DatasetId IS NULL
        THROW 51001, 'Dataset not found.', 1;

    EXEC gov.usp_EnsureDatasetGovernance @DatasetId = @DatasetId;

    DECLARE @OwnerId UNIQUEIDENTIFIER, @StewardId UNIQUEIDENTIFIER, @ActorId UNIQUEIDENTIFIER;
    IF @OwnerUserName IS NOT NULL
        SELECT @OwnerId = UserId FROM gov.AppUser WHERE UserName = @OwnerUserName AND IsActive = 1;
    IF @StewardUserName IS NOT NULL
        SELECT @StewardId = UserId FROM gov.AppUser WHERE UserName = @StewardUserName AND IsActive = 1;
    IF @ActorUserName IS NOT NULL
        SELECT @ActorId = UserId FROM gov.AppUser WHERE UserName = @ActorUserName AND IsActive = 1;

    IF @OwnerUserName IS NOT NULL AND @OwnerId IS NULL
        THROW 51002, 'Owner user not found.', 1;
    IF @StewardUserName IS NOT NULL AND @StewardId IS NULL
        THROW 51003, 'Steward user not found.', 1;

    IF @ClassificationCode IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM gov.Classification WHERE ClassificationCode = @ClassificationCode AND IsActive = 1)
        THROW 51004, 'Invalid classification.', 1;

    IF @GovernanceStatusCode IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM gov.GovernanceStatus WHERE StatusCode = @GovernanceStatusCode AND IsActive = 1)
        THROW 51005, 'Invalid governance status.', 1;

    -- Cross-workspace ownership check: owner/steward must be workspace members (unless platform admin)
    IF @WorkspaceId IS NOT NULL AND @OwnerId IS NOT NULL
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM gov.AppUser u WHERE u.UserId = @OwnerId AND u.IsPlatformAdmin = 1)
           AND NOT EXISTS (
            SELECT 1 FROM gov.WorkspaceMember m
            WHERE m.WorkspaceId = @WorkspaceId AND m.UserId = @OwnerId AND m.IsActive = 1)
            THROW 51006, 'Owner is not a member of the dataset workspace.', 1;
    END
    IF @WorkspaceId IS NOT NULL AND @StewardId IS NOT NULL
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM gov.AppUser u WHERE u.UserId = @StewardId AND u.IsPlatformAdmin = 1)
           AND NOT EXISTS (
            SELECT 1 FROM gov.WorkspaceMember m
            WHERE m.WorkspaceId = @WorkspaceId AND m.UserId = @StewardId AND m.IsActive = 1)
            THROW 51007, 'Steward is not a member of the dataset workspace.', 1;
    END

    DECLARE @OldClass NVARCHAR(32), @OldGov NVARCHAR(32), @OldOwner UNIQUEIDENTIFIER, @OldSteward UNIQUEIDENTIFIER;
    SELECT @OldClass = ClassificationCode, @OldGov = GovernanceStatusCode,
           @OldOwner = OwnerUserId, @OldSteward = StewardUserId
    FROM gov.DatasetGovernance WHERE DatasetId = @DatasetId;

    UPDATE gov.DatasetGovernance
    SET ClassificationCode = COALESCE(@ClassificationCode, ClassificationCode),
        GovernanceStatusCode = COALESCE(@GovernanceStatusCode, GovernanceStatusCode),
        OwnerUserId = CASE WHEN @OwnerUserName IS NULL THEN OwnerUserId ELSE @OwnerId END,
        StewardUserId = CASE WHEN @StewardUserName IS NULL THEN StewardUserId ELSE @StewardId END,
        ReviewDueUtc = COALESCE(@ReviewDueUtc, ReviewDueUtc),
        Notes = COALESCE(@Notes, Notes),
        WorkspaceId = @WorkspaceId,
        ModifiedUtc = SYSUTCDATETIME()
    WHERE DatasetId = @DatasetId;

    -- Sync free-text OwnerName on catalog for analytics compatibility
    IF @OwnerId IS NOT NULL
        UPDATE ingest.Dataset
        SET OwnerName = (SELECT DisplayName FROM gov.AppUser WHERE UserId = @OwnerId),
            ModifiedUtc = SYSUTCDATETIME()
        WHERE DatasetId = @DatasetId;

    IF @ClassificationCode IS NOT NULL AND @ClassificationCode <> @OldClass
    BEGIN
        DECLARE @ClassAudit NVARCHAR(500) =
            CONCAT(N'{"from":"', ISNULL(@OldClass, N''), N'","to":"', @ClassificationCode, N'"}');
        EXEC gov.usp_WriteAudit @EventType = N'ClassificationChanged', @DatasetId = @DatasetId,
            @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId,
            @DetailsJson = @ClassAudit;
    END

    IF (@OwnerId IS NOT NULL AND (@OldOwner IS NULL OR @OwnerId <> @OldOwner))
        OR (@StewardId IS NOT NULL AND (@OldSteward IS NULL OR @StewardId <> @OldSteward))
        EXEC gov.usp_WriteAudit @EventType = N'OwnershipChanged', @DatasetId = @DatasetId,
            @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId,
            @DetailsJson = N'{"action":"owner_or_steward_updated"}';

    IF @GovernanceStatusCode IS NOT NULL AND @GovernanceStatusCode <> @OldGov
    BEGIN
        DECLARE @GovAudit NVARCHAR(500) =
            CONCAT(N'{"from":"', ISNULL(@OldGov, N''), N'","to":"', @GovernanceStatusCode, N'"}');
        EXEC gov.usp_WriteAudit @EventType = N'GovernanceStatusChanged', @DatasetId = @DatasetId,
            @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId,
            @DetailsJson = @GovAudit;
    END

    SELECT g.DatasetId, d.DatasetCode, d.DisplayName AS DatasetName, g.WorkspaceId,
           g.ClassificationCode, g.GovernanceStatusCode, g.CertificationStatusCode,
           ou.UserName AS OwnerUserName, su.UserName AS StewardUserName,
           g.ReviewDueUtc, g.CertifiedUtc, g.CertificationExpiryUtc, g.Notes,
           g.CreatedUtc, g.ModifiedUtc
    FROM gov.DatasetGovernance g
    INNER JOIN ingest.Dataset d ON d.DatasetId = g.DatasetId
    LEFT JOIN gov.AppUser ou ON ou.UserId = g.OwnerUserId
    LEFT JOIN gov.AppUser su ON su.UserId = g.StewardUserId
    WHERE g.DatasetId = @DatasetId;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_GetDatasetGovernance
    @DatasetCode NVARCHAR(64) = NULL,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT g.DatasetId, d.DatasetCode, d.DisplayName AS DatasetName, g.WorkspaceId,
           w.WorkspaceCode, g.ClassificationCode, c.DisplayName AS ClassificationName,
           g.GovernanceStatusCode, g.CertificationStatusCode,
           ou.UserName AS OwnerUserName, ou.DisplayName AS OwnerDisplayName,
           su.UserName AS StewardUserName, su.DisplayName AS StewardDisplayName,
           g.ReviewDueUtc, g.CertifiedUtc, g.CertificationExpiryUtc, g.Notes,
           g.CreatedUtc, g.ModifiedUtc
    FROM gov.DatasetGovernance g
    INNER JOIN ingest.Dataset d ON d.DatasetId = g.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = g.WorkspaceId
    LEFT JOIN gov.Classification c ON c.ClassificationCode = g.ClassificationCode
    LEFT JOIN gov.AppUser ou ON ou.UserId = g.OwnerUserId
    LEFT JOIN gov.AppUser su ON su.UserId = g.StewardUserId
    WHERE (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
      AND (@WorkspaceId IS NULL OR g.WorkspaceId = @WorkspaceId OR g.WorkspaceId IS NULL)
    ORDER BY d.DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_CertifyDataset
    @DatasetCode              NVARCHAR(64),
    @ActorUserName            NVARCHAR(128),
    @CertificationExpiryUtc   DATETIME2(3) = NULL,
    @ReviewDueUtc             DATETIME2(3) = NULL,
    @Comments                 NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId
    FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;

    IF @DatasetId IS NULL THROW 51001, 'Dataset not found.', 1;

    DECLARE @ActorId UNIQUEIDENTIFIER;
    SELECT @ActorId = UserId FROM gov.AppUser WHERE UserName = @ActorUserName AND IsActive = 1;
    IF @ActorId IS NULL THROW 51008, 'Actor user not found.', 1;

    EXEC gov.usp_EnsureDatasetGovernance @DatasetId = @DatasetId;

    DECLARE @PrevGov NVARCHAR(32), @PrevCert NVARCHAR(32);
    SELECT @PrevGov = GovernanceStatusCode, @PrevCert = CertificationStatusCode
    FROM gov.DatasetGovernance WHERE DatasetId = @DatasetId;

    IF @CertificationExpiryUtc IS NULL
        SET @CertificationExpiryUtc = DATEADD(DAY, 365, SYSUTCDATETIME());
    IF @ReviewDueUtc IS NULL
        SET @ReviewDueUtc = @CertificationExpiryUtc;

    UPDATE gov.DatasetGovernance
    SET GovernanceStatusCode = N'Certified',
        CertificationStatusCode = N'Certified',
        CertifiedUtc = SYSUTCDATETIME(),
        CertificationExpiryUtc = @CertificationExpiryUtc,
        ReviewDueUtc = @ReviewDueUtc,
        ModifiedUtc = SYSUTCDATETIME()
    WHERE DatasetId = @DatasetId;

    INSERT INTO gov.CertificationHistory
        (DatasetId, PreviousGovStatus, NewGovStatus, PreviousCertStatus, NewCertStatus,
         ActionedByUserId, ReviewDueUtc, CertificationExpiryUtc, Comments)
    VALUES
        (@DatasetId, @PrevGov, N'Certified', @PrevCert, N'Certified',
         @ActorId, @ReviewDueUtc, @CertificationExpiryUtc, @Comments);

    EXEC gov.usp_WriteAudit @EventType = N'CertificationApproved', @DatasetId = @DatasetId,
        @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId,
        @DetailsJson = @Comments;

    EXEC gov.usp_GetDatasetGovernance @DatasetCode = @DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_SubmitForReview
    @DatasetCode   NVARCHAR(64),
    @ActorUserName NVARCHAR(128),
    @ReviewDueUtc  DATETIME2(3) = NULL,
    @Comments      NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER, @ActorId UNIQUEIDENTIFIER;
    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;
    IF @DatasetId IS NULL THROW 51001, 'Dataset not found.', 1;
    SELECT @ActorId = UserId FROM gov.AppUser WHERE UserName = @ActorUserName AND IsActive = 1;
    IF @ActorId IS NULL THROW 51008, 'Actor user not found.', 1;

    EXEC gov.usp_EnsureDatasetGovernance @DatasetId = @DatasetId;

    DECLARE @PrevGov NVARCHAR(32), @PrevCert NVARCHAR(32);
    SELECT @PrevGov = GovernanceStatusCode, @PrevCert = CertificationStatusCode
    FROM gov.DatasetGovernance WHERE DatasetId = @DatasetId;

    UPDATE gov.DatasetGovernance
    SET GovernanceStatusCode = N'UnderReview',
        ReviewDueUtc = COALESCE(@ReviewDueUtc, ReviewDueUtc, DATEADD(DAY, 30, SYSUTCDATETIME())),
        ModifiedUtc = SYSUTCDATETIME()
    WHERE DatasetId = @DatasetId;

    INSERT INTO gov.CertificationHistory
        (DatasetId, PreviousGovStatus, NewGovStatus, PreviousCertStatus, NewCertStatus,
         ActionedByUserId, ReviewDueUtc, Comments)
    VALUES
        (@DatasetId, @PrevGov, N'UnderReview', @PrevCert, @PrevCert, @ActorId, @ReviewDueUtc, @Comments);

    EXEC gov.usp_WriteAudit @EventType = N'SubmittedForReview', @DatasetId = @DatasetId,
        @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Comments;

    EXEC gov.usp_GetDatasetGovernance @DatasetCode = @DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_GetCertificationHistory
    @DatasetCode NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT h.HistoryId, d.DatasetCode, h.PreviousGovStatus, h.NewGovStatus,
           h.PreviousCertStatus, h.NewCertStatus,
           u.UserName AS ActionedByUserName, u.DisplayName AS ActionedByDisplayName,
           h.ActionUtc, h.ReviewDueUtc, h.CertificationExpiryUtc, h.Comments
    FROM gov.CertificationHistory h
    INNER JOIN ingest.Dataset d ON d.DatasetId = h.DatasetId
    LEFT JOIN gov.AppUser u ON u.UserId = h.ActionedByUserId
    WHERE d.DatasetCode = @DatasetCode
    ORDER BY h.ActionUtc DESC, h.HistoryId DESC;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_SubmitAccessRequest
    @DatasetCode            NVARCHAR(64),
    @RequestingUserName     NVARCHAR(128),
    @AccessLevelCode        NVARCHAR(32),
    @BusinessJustification  NVARCHAR(2000),
    @AccessRequestId        UNIQUEIDENTIFIER = NULL OUTPUT,
    @StatusCode             NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage          NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Created';
    SET @StatusMessage = N'Access request submitted.';

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId
    FROM ingest.Dataset WHERE DatasetCode = @DatasetCode AND IsActive = 1;
    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'InvalidDataset'; SET @StatusMessage = N'Dataset not found.'; RETURN; END

    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @RequestingUserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Requesting user not found.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM gov.AccessLevel WHERE AccessLevelCode = @AccessLevelCode AND IsActive = 1)
    BEGIN SET @StatusCode = N'InvalidAccessLevel'; SET @StatusMessage = N'Invalid access level.'; RETURN; END

    IF LEN(LTRIM(RTRIM(ISNULL(@BusinessJustification, N'')))) < 5
    BEGIN SET @StatusCode = N'InvalidJustification'; SET @StatusMessage = N'Business justification is required.'; RETURN; END

    -- Cross-workspace: requester must belong to dataset workspace (or platform admin)
    IF @WorkspaceId IS NOT NULL AND @IsAdmin = 0
       AND NOT EXISTS (
            SELECT 1 FROM gov.WorkspaceMember m
            WHERE m.WorkspaceId = @WorkspaceId AND m.UserId = @UserId AND m.IsActive = 1)
    BEGIN
        SET @StatusCode = N'CrossWorkspaceDenied';
        SET @StatusMessage = N'Requester is not a member of the dataset workspace.';
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM gov.AccessRequest
        WHERE DatasetId = @DatasetId AND RequestingUserId = @UserId
          AND AccessLevelCode = @AccessLevelCode AND Status = N'Pending')
    BEGIN
        SET @StatusCode = N'DuplicatePending';
        SET @StatusMessage = N'A pending request already exists for this dataset and access level.';
        RETURN;
    END

    IF EXISTS (
        SELECT 1 FROM gov.DatasetAccessGrant
        WHERE DatasetId = @DatasetId AND UserId = @UserId
          AND AccessLevelCode = @AccessLevelCode AND IsActive = 1
          AND (ExpiresUtc IS NULL OR ExpiresUtc > SYSUTCDATETIME()))
    BEGIN
        SET @StatusCode = N'AlreadyGranted';
        SET @StatusMessage = N'User already has an active grant at this access level.';
        RETURN;
    END

    SET @AccessRequestId = NEWID();
    INSERT INTO gov.AccessRequest
        (AccessRequestId, DatasetId, RequestingUserId, AccessLevelCode, BusinessJustification, Status, WorkspaceId)
    VALUES
        (@AccessRequestId, @DatasetId, @UserId, @AccessLevelCode, @BusinessJustification, N'Pending', @WorkspaceId);

    EXEC gov.usp_WriteAudit @EventType = N'AccessRequested', @DatasetId = @DatasetId,
        @UserId = @UserId, @ActorUserId = @UserId, @WorkspaceId = @WorkspaceId,
        @AccessRequestId = @AccessRequestId;

    SELECT ar.AccessRequestId, d.DatasetCode, u.UserName AS RequestingUserName,
           ar.AccessLevelCode, ar.BusinessJustification, ar.Status, ar.RequestedUtc,
           ar.ReviewerUserId, ar.ReviewComments, ar.DecisionUtc, ar.WorkspaceId
    FROM gov.AccessRequest ar
    INNER JOIN ingest.Dataset d ON d.DatasetId = ar.DatasetId
    INNER JOIN gov.AppUser u ON u.UserId = ar.RequestingUserId
    WHERE ar.AccessRequestId = @AccessRequestId;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_ApproveAccessRequest
    @AccessRequestId   UNIQUEIDENTIFIER,
    @ReviewerUserName  NVARCHAR(128),
    @ReviewComments    NVARCHAR(2000) = NULL,
    @ExpiresUtc        DATETIME2(3) = NULL,
    @StatusCode        NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage     NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Approved';
    SET @StatusMessage = N'Request approved.';

    DECLARE @Status NVARCHAR(16), @DatasetId UNIQUEIDENTIFIER, @UserId UNIQUEIDENTIFIER,
            @Level NVARCHAR(32), @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @Status = Status, @DatasetId = DatasetId, @UserId = RequestingUserId,
           @Level = AccessLevelCode, @WorkspaceId = WorkspaceId
    FROM gov.AccessRequest WHERE AccessRequestId = @AccessRequestId;

    IF @Status IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Access request not found.'; RETURN; END
    IF @Status <> N'Pending'
    BEGIN SET @StatusCode = N'InvalidTransition'; SET @StatusMessage = N'Only pending requests can be approved.'; RETURN; END

    DECLARE @ReviewerId UNIQUEIDENTIFIER, @IsAdmin BIT;
    SELECT @ReviewerId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @ReviewerUserName AND IsActive = 1;
    IF @ReviewerId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Reviewer not found.'; RETURN; END

    -- Reviewer must be owner/steward/workspace admin/platform admin
    IF @IsAdmin = 0
       AND NOT EXISTS (
            SELECT 1 FROM gov.DatasetGovernance g
            WHERE g.DatasetId = @DatasetId AND (g.OwnerUserId = @ReviewerId OR g.StewardUserId = @ReviewerId))
       AND NOT EXISTS (
            SELECT 1 FROM gov.WorkspaceMember m
            WHERE m.WorkspaceId = @WorkspaceId AND m.UserId = @ReviewerId AND m.IsActive = 1
              AND m.RoleCode IN (N'WorkspaceAdmin', N'DataOwner', N'DataSteward'))
    BEGIN
        SET @StatusCode = N'Unauthorized';
        SET @StatusMessage = N'Reviewer is not authorized to approve this request.';
        RETURN;
    END

    UPDATE gov.AccessRequest
    SET Status = N'Approved',
        ReviewerUserId = @ReviewerId,
        ReviewComments = @ReviewComments,
        DecisionUtc = SYSUTCDATETIME(),
        ModifiedUtc = SYSUTCDATETIME()
    WHERE AccessRequestId = @AccessRequestId;

    -- Deactivate prior active grant at same level if any
    UPDATE gov.DatasetAccessGrant
    SET IsActive = 0, RevokedUtc = SYSUTCDATETIME(), RevokedByUserId = @ReviewerId,
        RevokeReason = N'Superseded by new approval'
    WHERE DatasetId = @DatasetId AND UserId = @UserId AND AccessLevelCode = @Level AND IsActive = 1;

    INSERT INTO gov.DatasetAccessGrant
        (DatasetId, UserId, AccessLevelCode, AccessRequestId, GrantedByUserId, ExpiresUtc, IsActive)
    VALUES
        (@DatasetId, @UserId, @Level, @AccessRequestId, @ReviewerId, @ExpiresUtc, 1);

    EXEC gov.usp_WriteAudit @EventType = N'AccessApproved', @DatasetId = @DatasetId,
        @UserId = @UserId, @ActorUserId = @ReviewerId, @WorkspaceId = @WorkspaceId,
        @AccessRequestId = @AccessRequestId, @DetailsJson = @ReviewComments;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_RejectAccessRequest
    @AccessRequestId   UNIQUEIDENTIFIER,
    @ReviewerUserName  NVARCHAR(128),
    @ReviewComments    NVARCHAR(2000) = NULL,
    @StatusCode        NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage     NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Rejected';
    SET @StatusMessage = N'Request rejected.';

    DECLARE @Status NVARCHAR(16), @DatasetId UNIQUEIDENTIFIER, @UserId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @Status = Status, @DatasetId = DatasetId, @UserId = RequestingUserId, @WorkspaceId = WorkspaceId
    FROM gov.AccessRequest WHERE AccessRequestId = @AccessRequestId;

    IF @Status IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Access request not found.'; RETURN; END
    IF @Status <> N'Pending'
    BEGIN SET @StatusCode = N'InvalidTransition'; SET @StatusMessage = N'Only pending requests can be rejected.'; RETURN; END

    DECLARE @ReviewerId UNIQUEIDENTIFIER;
    SELECT @ReviewerId = UserId FROM gov.AppUser WHERE UserName = @ReviewerUserName AND IsActive = 1;
    IF @ReviewerId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Reviewer not found.'; RETURN; END

    UPDATE gov.AccessRequest
    SET Status = N'Rejected',
        ReviewerUserId = @ReviewerId,
        ReviewComments = @ReviewComments,
        DecisionUtc = SYSUTCDATETIME(),
        ModifiedUtc = SYSUTCDATETIME()
    WHERE AccessRequestId = @AccessRequestId;

    EXEC gov.usp_WriteAudit @EventType = N'AccessRejected', @DatasetId = @DatasetId,
        @UserId = @UserId, @ActorUserId = @ReviewerId, @WorkspaceId = @WorkspaceId,
        @AccessRequestId = @AccessRequestId, @DetailsJson = @ReviewComments;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_RevokeAccess
    @AccessRequestId   UNIQUEIDENTIFIER = NULL,
    @DatasetCode       NVARCHAR(64) = NULL,
    @UserName          NVARCHAR(128) = NULL,
    @AccessLevelCode   NVARCHAR(32) = NULL,
    @ReviewerUserName  NVARCHAR(128),
    @RevokeReason      NVARCHAR(1000) = NULL,
    @StatusCode        NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage     NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Revoked';
    SET @StatusMessage = N'Access revoked.';

    DECLARE @ReviewerId UNIQUEIDENTIFIER;
    SELECT @ReviewerId = UserId FROM gov.AppUser WHERE UserName = @ReviewerUserName AND IsActive = 1;
    IF @ReviewerId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Reviewer not found.'; RETURN; END

    DECLARE @DatasetId UNIQUEIDENTIFIER, @UserId UNIQUEIDENTIFIER, @Level NVARCHAR(32),
            @WorkspaceId UNIQUEIDENTIFIER, @ReqId UNIQUEIDENTIFIER, @ReqStatus NVARCHAR(16);

    IF @AccessRequestId IS NOT NULL
    BEGIN
        SELECT @ReqId = AccessRequestId, @DatasetId = DatasetId, @UserId = RequestingUserId,
               @Level = AccessLevelCode, @WorkspaceId = WorkspaceId, @ReqStatus = Status
        FROM gov.AccessRequest WHERE AccessRequestId = @AccessRequestId;

        IF @ReqId IS NULL
        BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Access request not found.'; RETURN; END
        IF @ReqStatus NOT IN (N'Approved', N'Pending')
        BEGIN SET @StatusCode = N'InvalidTransition'; SET @StatusMessage = N'Only approved or pending requests can be revoked.'; RETURN; END

        UPDATE gov.AccessRequest
        SET Status = N'Revoked', ReviewerUserId = @ReviewerId, ReviewComments = COALESCE(@RevokeReason, ReviewComments),
            DecisionUtc = SYSUTCDATETIME(), ModifiedUtc = SYSUTCDATETIME()
        WHERE AccessRequestId = @ReqId;
    END
    ELSE
    BEGIN
        SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;
        SELECT @UserId = UserId FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
        SET @Level = @AccessLevelCode;
        IF @DatasetId IS NULL OR @UserId IS NULL OR @Level IS NULL
        BEGIN SET @StatusCode = N'InvalidInput'; SET @StatusMessage = N'Dataset, user, and access level are required.'; RETURN; END
    END

    UPDATE gov.DatasetAccessGrant
    SET IsActive = 0, RevokedUtc = SYSUTCDATETIME(), RevokedByUserId = @ReviewerId, RevokeReason = @RevokeReason
    WHERE DatasetId = @DatasetId AND UserId = @UserId
      AND (@Level IS NULL OR AccessLevelCode = @Level)
      AND IsActive = 1;

    IF @@ROWCOUNT = 0 AND @AccessRequestId IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'No active grant found to revoke.'; RETURN; END

    EXEC gov.usp_WriteAudit @EventType = N'AccessRevoked', @DatasetId = @DatasetId,
        @UserId = @UserId, @ActorUserId = @ReviewerId, @WorkspaceId = @WorkspaceId,
        @AccessRequestId = @AccessRequestId, @DetailsJson = @RevokeReason;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_GetPendingAccessRequests
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ar.AccessRequestId, d.DatasetCode, d.DisplayName AS DatasetName,
           u.UserName AS RequestingUserName, u.DisplayName AS RequestingDisplayName,
           ar.AccessLevelCode, ar.BusinessJustification, ar.Status, ar.RequestedUtc,
           ar.WorkspaceId, w.WorkspaceCode
    FROM gov.AccessRequest ar
    INNER JOIN ingest.Dataset d ON d.DatasetId = ar.DatasetId
    INNER JOIN gov.AppUser u ON u.UserId = ar.RequestingUserId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = ar.WorkspaceId
    WHERE ar.Status = N'Pending'
      AND (@WorkspaceId IS NULL OR ar.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    ORDER BY ar.RequestedUtc;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_GetAccessRequestHistory
    @DatasetCode NVARCHAR(64) = NULL,
    @UserName    NVARCHAR(128) = NULL,
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Take        INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @Take IS NULL OR @Take < 1 SET @Take = 100;

    SELECT TOP (@Take)
           ar.AccessRequestId, d.DatasetCode, d.DisplayName AS DatasetName,
           u.UserName AS RequestingUserName, ar.AccessLevelCode, ar.BusinessJustification,
           ar.Status, ar.RequestedUtc,
           rv.UserName AS ReviewerUserName, ar.ReviewComments, ar.DecisionUtc,
           ar.WorkspaceId, w.WorkspaceCode
    FROM gov.AccessRequest ar
    INNER JOIN ingest.Dataset d ON d.DatasetId = ar.DatasetId
    INNER JOIN gov.AppUser u ON u.UserId = ar.RequestingUserId
    LEFT JOIN gov.AppUser rv ON rv.UserId = ar.ReviewerUserId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = ar.WorkspaceId
    WHERE (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
      AND (@UserName IS NULL OR u.UserName = @UserName)
      AND (@WorkspaceId IS NULL OR ar.WorkspaceId = @WorkspaceId)
    ORDER BY ar.RequestedUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_EvaluateDatasetAccess
    @DatasetCode NVARCHAR(64),
    @UserName    NVARCHAR(128),
    @RequiredAccessLevel NVARCHAR(32) = N'Read'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER, @Class NVARCHAR(32), @ClassRank TINYINT;
    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT;
    DECLARE @RequiredRank TINYINT;

    SELECT @DatasetId = d.DatasetId, @WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId),
           @Class = COALESCE(g.ClassificationCode, N'Internal')
    FROM ingest.Dataset d
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    WHERE d.DatasetCode = @DatasetCode AND d.IsActive = 1;

    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;

    SELECT @RequiredRank = RankOrder FROM gov.AccessLevel WHERE AccessLevelCode = @RequiredAccessLevel;
    SELECT @ClassRank = SensitivityRank FROM gov.Classification WHERE ClassificationCode = @Class;

    DECLARE @Allowed BIT = 0;
    DECLARE @Reason NVARCHAR(200) = N'Denied';
    DECLARE @EffectiveLevel NVARCHAR(32) = NULL;
    DECLARE @EffectiveRank TINYINT = 0;

    IF @DatasetId IS NULL OR @UserId IS NULL OR @RequiredRank IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS IsAllowed, CAST(NULL AS NVARCHAR(32)) AS EffectiveAccessLevel,
               N'Invalid dataset, user, or access level.' AS Reason,
               @Class AS ClassificationCode, CAST(0 AS BIT) AS IsOwner, CAST(0 AS BIT) AS IsSteward,
               CAST(0 AS BIT) AS IsWorkspaceMember, CAST(0 AS BIT) AS HasGrant, CAST(0 AS BIT) AS IsPlatformAdmin;
        RETURN;
    END

    DECLARE @IsOwner BIT = 0, @IsSteward BIT = 0, @IsMember BIT = 0, @HasGrant BIT = 0;

    IF EXISTS (SELECT 1 FROM gov.DatasetGovernance WHERE DatasetId = @DatasetId AND OwnerUserId = @UserId)
        SET @IsOwner = 1;
    IF EXISTS (SELECT 1 FROM gov.DatasetGovernance WHERE DatasetId = @DatasetId AND StewardUserId = @UserId)
        SET @IsSteward = 1;
    IF @WorkspaceId IS NOT NULL AND EXISTS (
        SELECT 1 FROM gov.WorkspaceMember WHERE WorkspaceId = @WorkspaceId AND UserId = @UserId AND IsActive = 1)
        SET @IsMember = 1;

    -- Platform admin
    IF @IsAdmin = 1
    BEGIN
        SET @Allowed = 1; SET @EffectiveLevel = N'Admin'; SET @EffectiveRank = 3; SET @Reason = N'Platform admin';
    END
    -- Owner / steward
    ELSE IF @IsOwner = 1 OR @IsSteward = 1
    BEGIN
        SET @Allowed = 1; SET @EffectiveLevel = N'Admin'; SET @EffectiveRank = 3;
        SET @Reason = CASE WHEN @IsOwner = 1 THEN N'Dataset owner' ELSE N'Dataset steward' END;
    END
    ELSE
    BEGIN
        -- Active grant
        SELECT TOP (1) @EffectiveLevel = g.AccessLevelCode, @EffectiveRank = al.RankOrder
        FROM gov.DatasetAccessGrant g
        INNER JOIN gov.AccessLevel al ON al.AccessLevelCode = g.AccessLevelCode
        WHERE g.DatasetId = @DatasetId AND g.UserId = @UserId AND g.IsActive = 1
          AND (g.ExpiresUtc IS NULL OR g.ExpiresUtc > SYSUTCDATETIME())
        ORDER BY al.RankOrder DESC;

        IF @EffectiveRank > 0
        BEGIN
            SET @HasGrant = 1;
            IF @EffectiveRank >= @RequiredRank
            BEGIN SET @Allowed = 1; SET @Reason = N'Approved access grant'; END
            ELSE BEGIN SET @Reason = N'Grant level insufficient'; END
        END

        -- Workspace role fallback for Public/Internal when member
        IF @Allowed = 0 AND @IsMember = 1 AND @ClassRank <= 2 -- Public/Internal
        BEGIN
            DECLARE @WsRole NVARCHAR(32);
            SELECT @WsRole = RoleCode FROM gov.WorkspaceMember
            WHERE WorkspaceId = @WorkspaceId AND UserId = @UserId AND IsActive = 1;

            IF @WsRole IN (N'WorkspaceAdmin', N'DataOwner', N'DataSteward', N'Analyst')
               AND @RequiredRank <= 2
            BEGIN
                SET @Allowed = 1;
                SET @EffectiveLevel = CASE WHEN @WsRole IN (N'WorkspaceAdmin', N'DataOwner') THEN N'Admin' ELSE N'Read' END;
                SET @Reason = N'Workspace membership for non-sensitive classification';
            END
            ELSE IF @WsRole = N'Viewer' AND @RequiredRank = 1 AND @ClassRank = 1
            BEGIN
                SET @Allowed = 1; SET @EffectiveLevel = N'Read';
                SET @Reason = N'Workspace viewer on Public dataset';
            END
        END

        IF @Allowed = 0 AND @Reason = N'Denied'
            SET @Reason = N'No qualifying grant, ownership, or workspace privilege';
    END

    -- Restricted datasets require Admin grant or owner/steward/platform admin even if workspace member
    IF @Allowed = 1 AND @ClassRank >= 4 AND @IsAdmin = 0 AND @IsOwner = 0 AND @IsSteward = 0
       AND ISNULL(@EffectiveRank, 0) < 3 AND @HasGrant = 0
    BEGIN
        SET @Allowed = 0;
        SET @Reason = N'Restricted dataset requires explicit Admin grant or ownership';
        SET @EffectiveLevel = NULL;
    END

    SELECT @Allowed AS IsAllowed, @EffectiveLevel AS EffectiveAccessLevel, @Reason AS Reason,
           @Class AS ClassificationCode, @IsOwner AS IsOwner, @IsSteward AS IsSteward,
           @IsMember AS IsWorkspaceMember, @HasGrant AS HasGrant, @IsAdmin AS IsPlatformAdmin;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_ExpireDatasetCertifications
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Expired TABLE (DatasetId UNIQUEIDENTIFIER, PrevGov NVARCHAR(32), PrevCert NVARCHAR(32));

    UPDATE g
    SET GovernanceStatusCode = N'Expired',
        CertificationStatusCode = N'Expired',
        ModifiedUtc = SYSUTCDATETIME()
    OUTPUT inserted.DatasetId, deleted.GovernanceStatusCode, deleted.CertificationStatusCode
    INTO @Expired (DatasetId, PrevGov, PrevCert)
    FROM gov.DatasetGovernance g
    WHERE g.CertificationStatusCode = N'Certified'
      AND g.CertificationExpiryUtc IS NOT NULL
      AND g.CertificationExpiryUtc < SYSUTCDATETIME();

    INSERT INTO gov.CertificationHistory
        (DatasetId, PreviousGovStatus, NewGovStatus, PreviousCertStatus, NewCertStatus, Comments)
    SELECT DatasetId, PrevGov, N'Expired', PrevCert, N'Expired', N'Auto-expired by scheduled job'
    FROM @Expired;

    INSERT INTO gov.GovernanceAuditEvent (EventType, DatasetId, DetailsJson)
    SELECT N'CertificationExpired', DatasetId, N'{"source":"ExpireDatasetCertifications"}'
    FROM @Expired;

    SELECT COUNT(*) AS ExpiredCount FROM @Expired;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_ArchiveGovernanceAudit
    @RetainDays INT = 730
AS
BEGIN
    SET NOCOUNT ON;
    IF @RetainDays < 90 SET @RetainDays = 90;
    DELETE FROM gov.GovernanceAuditEvent
    WHERE EventUtc < DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());
    SELECT @@ROWCOUNT AS AuditRowsDeleted;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_GovernanceSummary
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH ds AS
    (
        SELECT d.DatasetId,
               COALESCE(g.WorkspaceId, d.WorkspaceId) AS WorkspaceId,
               COALESCE(g.GovernanceStatusCode, N'Draft') AS GovernanceStatusCode,
               COALESCE(g.CertificationStatusCode, N'NotCertified') AS CertificationStatusCode
        FROM ingest.Dataset d
        LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
        WHERE d.IsActive = 1
          AND (@WorkspaceId IS NULL OR COALESCE(g.WorkspaceId, d.WorkspaceId) = @WorkspaceId
               OR COALESCE(g.WorkspaceId, d.WorkspaceId) IS NULL)
    )
    SELECT
        (SELECT COUNT(*) FROM ds) AS TotalDatasets,
        (SELECT COUNT(*) FROM ds WHERE CertificationStatusCode = N'Certified') AS CertifiedDatasets,
        (SELECT COUNT(*) FROM ds WHERE GovernanceStatusCode = N'UnderReview') AS PendingReview,
        (SELECT COUNT(*) FROM ds WHERE CertificationStatusCode = N'Expired' OR GovernanceStatusCode = N'Expired') AS ExpiredCertifications,
        (SELECT COUNT(*) FROM gov.AccessRequest ar
          WHERE ar.Status = N'Pending'
            AND (@WorkspaceId IS NULL OR ar.WorkspaceId = @WorkspaceId)) AS PendingAccessRequests,
        (SELECT COUNT(*) FROM gov.AccessRequest ar
          WHERE ar.Status = N'Approved'
            AND (@WorkspaceId IS NULL OR ar.WorkspaceId = @WorkspaceId)) AS ApprovedAccessRequests,
        (SELECT COUNT(*) FROM gov.AccessRequest ar
          WHERE ar.Status = N'Rejected'
            AND (@WorkspaceId IS NULL OR ar.WorkspaceId = @WorkspaceId)) AS RejectedAccessRequests;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DatasetsByClassification
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COALESCE(g.ClassificationCode, N'Internal') AS ClassificationCode,
           c.DisplayName AS ClassificationName,
           COUNT(*) AS DatasetCount
    FROM ingest.Dataset d
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    LEFT JOIN gov.Classification c ON c.ClassificationCode = COALESCE(g.ClassificationCode, N'Internal')
    WHERE d.IsActive = 1
      AND (@WorkspaceId IS NULL OR COALESCE(g.WorkspaceId, d.WorkspaceId) = @WorkspaceId)
    GROUP BY COALESCE(g.ClassificationCode, N'Internal'), c.DisplayName
    ORDER BY DatasetCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_GovernanceStatusDistribution
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COALESCE(g.GovernanceStatusCode, N'Draft') AS GovernanceStatusCode,
           gs.DisplayName AS GovernanceStatusName,
           COUNT(*) AS DatasetCount
    FROM ingest.Dataset d
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    LEFT JOIN gov.GovernanceStatus gs ON gs.StatusCode = COALESCE(g.GovernanceStatusCode, N'Draft')
    WHERE d.IsActive = 1
      AND (@WorkspaceId IS NULL OR COALESCE(g.WorkspaceId, d.WorkspaceId) = @WorkspaceId)
    GROUP BY COALESCE(g.GovernanceStatusCode, N'Draft'), gs.DisplayName
    ORDER BY DatasetCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_AccessRequestsByWorkspace
AS
BEGIN
    SET NOCOUNT ON;
    SELECT COALESCE(w.WorkspaceCode, N'(unassigned)') AS WorkspaceCode,
           COALESCE(w.DisplayName, N'Unassigned') AS WorkspaceName,
           SUM(CASE WHEN ar.Status = N'Pending' THEN 1 ELSE 0 END) AS PendingCount,
           SUM(CASE WHEN ar.Status = N'Approved' THEN 1 ELSE 0 END) AS ApprovedCount,
           SUM(CASE WHEN ar.Status = N'Rejected' THEN 1 ELSE 0 END) AS RejectedCount,
           SUM(CASE WHEN ar.Status = N'Revoked' THEN 1 ELSE 0 END) AS RevokedCount,
           COUNT(*) AS TotalRequests
    FROM gov.AccessRequest ar
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = ar.WorkspaceId
    GROUP BY w.WorkspaceCode, w.DisplayName
    ORDER BY TotalRequests DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_PendingCertificationReview
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Take INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Take IS NULL OR @Take < 1 SET @Take = 50;

    SELECT TOP (@Take)
           d.DatasetCode, d.DisplayName AS DatasetName, g.WorkspaceId, w.WorkspaceCode,
           g.ClassificationCode, g.GovernanceStatusCode, g.CertificationStatusCode,
           g.ReviewDueUtc, g.CertificationExpiryUtc,
           ou.UserName AS OwnerUserName, su.UserName AS StewardUserName
    FROM gov.DatasetGovernance g
    INNER JOIN ingest.Dataset d ON d.DatasetId = g.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = g.WorkspaceId
    LEFT JOIN gov.AppUser ou ON ou.UserId = g.OwnerUserId
    LEFT JOIN gov.AppUser su ON su.UserId = g.StewardUserId
    WHERE (g.GovernanceStatusCode IN (N'UnderReview', N'Draft')
       OR (g.CertificationStatusCode = N'Certified' AND g.ReviewDueUtc IS NOT NULL
           AND g.ReviewDueUtc < DATEADD(DAY, 14, SYSUTCDATETIME())))
      AND (@WorkspaceId IS NULL OR g.WorkspaceId = @WorkspaceId)
    ORDER BY CASE WHEN g.ReviewDueUtc IS NULL THEN 1 ELSE 0 END, g.ReviewDueUtc;
END
GO

CREATE OR ALTER PROCEDURE gov.usp_GetAuditEvents
    @DatasetCode NVARCHAR(64) = NULL,
    @EventType   NVARCHAR(64) = NULL,
    @Take        INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @Take IS NULL OR @Take < 1 SET @Take = 100;

    SELECT TOP (@Take)
           a.AuditEventId, a.EventType, d.DatasetCode, u.UserName AS SubjectUserName,
           act.UserName AS ActorUserName, a.WorkspaceId, a.AccessRequestId,
           a.DetailsJson, a.EventUtc
    FROM gov.GovernanceAuditEvent a
    LEFT JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
    LEFT JOIN gov.AppUser u ON u.UserId = a.UserId
    LEFT JOIN gov.AppUser act ON act.UserId = a.ActorUserId
    WHERE (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
      AND (@EventType IS NULL OR a.EventType = @EventType)
    ORDER BY a.EventUtc DESC, a.AuditEventId DESC;
END
GO

PRINT 'Governance procedures created.';
GO
