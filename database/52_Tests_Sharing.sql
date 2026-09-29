-- ============================================================
-- 52_Tests_Sharing.sql
-- Assertion-style tests for sharing, export authorization,
-- export lifecycle, paging, history and reporting.
-- Re-runnable: test shares are revoked and test exports are
-- driven to a terminal state before the script ends.
-- ============================================================
USE EDIP;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;
CREATE TABLE #T (Id INT IDENTITY(1,1), TestName NVARCHAR(200), Expected NVARCHAR(100), Actual NVARCHAR(100), Passed BIT);
GO

-- ------------------------------------------------------------
-- Authorization
-- ------------------------------------------------------------
DECLARE @A TABLE (IsAllowed BIT, DecisionCode NVARCHAR(32), AccessSource NVARCHAR(32));
DECLARE @CustomerId UNIQUEIDENTIFIER = (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER');
DECLARE @OrderId UNIQUEIDENTIFIER = (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'ORDER');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: analyst CUSTOMER via Write grant', N'Allowed/AccessGrant', CONCAT(DecisionCode, N'/', AccessSource),
       CASE WHEN DecisionCode = N'Allowed' AND AccessSource = N'AccessGrant' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@CustomerId, 'A1000000-0000-0000-0000-000000000004');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: owner CUSTOMER', N'Allowed/DatasetOwner', CONCAT(DecisionCode, N'/', AccessSource),
       CASE WHEN DecisionCode = N'Allowed' AND AccessSource = N'DatasetOwner' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@CustomerId, 'A1000000-0000-0000-0000-000000000002');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: viewer CUSTOMER (Read share < Write policy)', N'InsufficientAccess', DecisionCode,
       CASE WHEN DecisionCode = N'InsufficientAccess' AND ShareStatus = N'Active' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@CustomerId, 'A1000000-0000-0000-0000-000000000005');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: outsider CUSTOMER', N'CrossWorkspaceDenied', DecisionCode,
       CASE WHEN DecisionCode = N'CrossWorkspaceDenied' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@CustomerId, 'A1000000-0000-0000-0000-000000000006');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: viewer ORDER (share expired at read time)', N'InsufficientAccess/Expired', CONCAT(DecisionCode, N'/', ShareStatus),
       CASE WHEN DecisionCode = N'InsufficientAccess' AND ShareStatus = N'Expired' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@OrderId, 'A1000000-0000-0000-0000-000000000005');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: analyst ORDER via workspace role (Internal)', N'Allowed/WorkspaceRole', CONCAT(DecisionCode, N'/', AccessSource),
       CASE WHEN DecisionCode = N'Allowed' AND AccessSource = N'WorkspaceRole' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@OrderId, 'A1000000-0000-0000-0000-000000000004');

INSERT #T (TestName, Expected, Actual, Passed)
SELECT N'Auth: admin CUSTOMER', N'Allowed/PlatformAdmin', CONCAT(DecisionCode, N'/', AccessSource),
       CASE WHEN DecisionCode = N'Allowed' AND AccessSource = N'PlatformAdmin' THEN 1 ELSE 0 END
FROM share.fn_EvaluateExportAccess(@CustomerId, 'A1000000-0000-0000-0000-000000000001');
GO

-- ------------------------------------------------------------
-- Share validation + lifecycle
-- ------------------------------------------------------------
DECLARE @S UNIQUEIDENTIFIER, @C NVARCHAR(32), @M NVARCHAR(500);
DECLARE @Past DATETIME2(3) = DATEADD(DAY, -1, SYSUTCDATETIME());
DECLARE @Future DATETIME2(3) = DATEADD(DAY, 10, SYSUTCDATETIME());
DECLARE @Future2 DATETIME2(3) = DATEADD(DAY, 20, SYSUTCDATETIME());

EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.owner',
    @AccessLevelCode = N'Read', @SharedByUserName = N'gov.owner',
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: self share rejected', N'SelfShare', @C, CASE WHEN @C = N'SelfShare' THEN 1 ELSE 0 END);

EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.outsider',
    @AccessLevelCode = N'Read', @SharedByUserName = N'gov.owner',
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: cross-workspace recipient rejected', N'CrossWorkspaceDenied', @C, CASE WHEN @C = N'CrossWorkspaceDenied' THEN 1 ELSE 0 END);

EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.analyst',
    @AccessLevelCode = N'Superuser', @SharedByUserName = N'gov.owner',
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: invalid access level rejected', N'InvalidAccessLevel', @C, CASE WHEN @C = N'InvalidAccessLevel' THEN 1 ELSE 0 END);

EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.analyst',
    @AccessLevelCode = N'Read', @SharedByUserName = N'gov.owner', @ExpiresUtc = @Past,
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: past expiry rejected', N'InvalidExpiry', @C, CASE WHEN @C = N'InvalidExpiry' THEN 1 ELSE 0 END);

EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.steward',
    @AccessLevelCode = N'Read', @SharedByUserName = N'gov.analyst',
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: analyst cannot share', N'Unauthorized', @C, CASE WHEN @C = N'Unauthorized' THEN 1 ELSE 0 END);

EXEC share.usp_CreateDatasetShare @DatasetCode = N'NOPE', @RecipientUserName = N'gov.analyst',
    @AccessLevelCode = N'Read', @SharedByUserName = N'gov.owner',
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: unknown dataset rejected', N'InvalidDataset', @C, CASE WHEN @C = N'InvalidDataset' THEN 1 ELSE 0 END);

-- Happy path: create → duplicate → update → no-op → revoke → modify revoked
SET @S = NULL;
EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.analyst',
    @AccessLevelCode = N'Read', @SharedByUserName = N'gov.steward', @ExpiresUtc = @Future,
    @Notes = N'test share', @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: create', N'Created', @C, CASE WHEN @C = N'Created' THEN 1 ELSE 0 END);
DECLARE @TestShare UNIQUEIDENTIFIER = @S;

EXEC share.usp_CreateDatasetShare @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.analyst',
    @AccessLevelCode = N'Write', @SharedByUserName = N'gov.owner',
    @ShareId = @S OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: duplicate active rejected', N'DuplicateActive', @C,
    CASE WHEN @C = N'DuplicateActive' AND @S = @TestShare THEN 1 ELSE 0 END);

EXEC share.usp_UpdateDatasetShare @ShareId = @TestShare, @ActorUserName = N'gov.owner',
    @AccessLevelCode = N'Write', @ExpiresUtc = @Future2, @Comments = N'raise level',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: update access level', N'Updated', @C, CASE WHEN @C = N'Updated' THEN 1 ELSE 0 END);

EXEC share.usp_UpdateDatasetShare @ShareId = @TestShare, @ActorUserName = N'gov.owner',
    @AccessLevelCode = N'Write', @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: identical update is no-op', N'NoChange', @C, CASE WHEN @C = N'NoChange' THEN 1 ELSE 0 END);

EXEC share.usp_RevokeDatasetShare @ShareId = @TestShare, @ActorUserName = N'gov.analyst',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: recipient cannot revoke', N'Unauthorized', @C, CASE WHEN @C = N'Unauthorized' THEN 1 ELSE 0 END);

EXEC share.usp_RevokeDatasetShare @ShareId = @TestShare, @ActorUserName = N'gov.owner',
    @RevokeReason = N'test cleanup', @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: revoke', N'Revoked', @C, CASE WHEN @C = N'Revoked' THEN 1 ELSE 0 END);

EXEC share.usp_RevokeDatasetShare @ShareId = @TestShare, @ActorUserName = N'gov.owner',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: revoke twice', N'AlreadyRevoked', @C, CASE WHEN @C = N'AlreadyRevoked' THEN 1 ELSE 0 END);

EXEC share.usp_UpdateDatasetShare @ShareId = @TestShare, @ActorUserName = N'gov.owner',
    @AccessLevelCode = N'Read', @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Share: modify revoked rejected', N'ShareRevoked', @C, CASE WHEN @C = N'ShareRevoked' THEN 1 ELSE 0 END);

INSERT #T
SELECT N'Share: history has Created/Updated/Revoked', N'3', CAST(COUNT(*) AS NVARCHAR(10)),
       CASE WHEN COUNT(*) = 3 THEN 1 ELSE 0 END
FROM share.DatasetShareHistory WHERE ShareId = @TestShare;

INSERT #T
SELECT N'Audit: share events written', N'>=3', CAST(COUNT(*) AS NVARCHAR(10)),
       CASE WHEN COUNT(*) >= 3 THEN 1 ELSE 0 END
FROM gov.GovernanceAuditEvent
WHERE EventType IN (N'ShareCreated', N'ShareModified', N'ShareRevoked')
  AND JSON_VALUE(DetailsJson, N'$.shareId') = CAST(@TestShare AS NVARCHAR(36));

-- Expired share modification is rejected
DECLARE @ExpiredShare UNIQUEIDENTIFIER =
    (SELECT TOP (1) ShareId FROM share.vw_DatasetShareEffective WHERE EffectiveStatus = N'Expired');
IF @ExpiredShare IS NOT NULL
BEGIN
    EXEC share.usp_UpdateDatasetShare @ShareId = @ExpiredShare, @ActorUserName = N'gov.owner',
        @AccessLevelCode = N'Read', @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
    INSERT #T VALUES (N'Share: modify expired rejected', N'ShareExpired', @C, CASE WHEN @C = N'ShareExpired' THEN 1 ELSE 0 END);
END
GO

-- ------------------------------------------------------------
-- Export spec validation
-- ------------------------------------------------------------
DECLARE @E UNIQUEIDENTIFIER, @C NVARCHAR(32), @M NVARCHAR(500);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Pdf',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: invalid format', N'InvalidFormat', @C, CASE WHEN @C = N'InvalidFormat' THEN 1 ELSE 0 END);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @SelectedColumnsJson = N'["CustomerId","Password"]',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: unknown column', N'InvalidColumn', @C, CASE WHEN @C = N'InvalidColumn' THEN 1 ELSE 0 END);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @FiltersJson = N'[{"column":"CustomerName","op":"; DROP TABLE x","value":"a"}]',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: invalid operator', N'InvalidOperator', @C, CASE WHEN @C = N'InvalidOperator' THEN 1 ELSE 0 END);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @FiltersJson = N'[{"column":"CreditLimit","op":"gt","value":"abc"}]',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: type-mismatched filter value', N'InvalidFilterValue', @C, CASE WHEN @C = N'InvalidFilterValue' THEN 1 ELSE 0 END);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @FiltersJson = N'[{"column":"CreditLimit","op":"between","value":[1]}]',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: between needs 2 values', N'InvalidFilterValue', @C, CASE WHEN @C = N'InvalidFilterValue' THEN 1 ELSE 0 END);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @SortJson = N'[{"column":"CustomerName","dir":"sideways"}]',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: invalid sort direction', N'InvalidSpec', @C, CASE WHEN @C = N'InvalidSpec' THEN 1 ELSE 0 END);

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.outsider', @FormatCode = N'Csv',
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: outsider denied', N'AccessDenied', @C, CASE WHEN @C = N'AccessDenied' THEN 1 ELSE 0 END);
GO

-- ------------------------------------------------------------
-- Export lifecycle + keyset paging + offset paging
-- ------------------------------------------------------------
DECLARE @E UNIQUEIDENTIFIER, @C NVARCHAR(32), @M NVARCHAR(500);
DECLARE @Tag NVARCHAR(40) = CONVERT(NVARCHAR(40), NEWID());   -- makes the spec unique per run
DECLARE @Filters NVARCHAR(MAX) =
    N'[{"column":"CreditLimit","op":"ge","value":0},{"column":"CustomerCode","op":"ne","value":"' + @Tag + N'"}]';

EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @SelectedColumnsJson = N'["CustomerId","CustomerName","CountryCode"]', @FiltersJson = @Filters,
    @ExportRequestId = @E OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: submit', N'Created', @C, CASE WHEN @C = N'Created' THEN 1 ELSE 0 END);

DECLARE @E2 UNIQUEIDENTIFIER;
EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
    @SelectedColumnsJson = N'["CustomerId","CustomerName","CountryCode"]', @FiltersJson = @Filters,
    @ExportRequestId = @E2 OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: identical in-flight rejected', N'DuplicateInFlight', @C,
    CASE WHEN @C = N'DuplicateInFlight' AND @E2 = @E THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E, @NewStatus = N'Completed', @RecordCount = 1,
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Pending -> Completed rejected', N'InvalidTransition', @C, CASE WHEN @C = N'InvalidTransition' THEN 1 ELSE 0 END);

EXEC share.usp_GetExportData @ExportRequestId = @E, @UserName = N'gov.analyst', @PageSize = 5,
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export data: blocked while Pending', N'InvalidState', @C, CASE WHEN @C = N'InvalidState' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E, @NewStatus = N'Processing', @ActorUserName = N'gov.viewer',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: other user cannot transition', N'Unauthorized', @C, CASE WHEN @C = N'Unauthorized' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E, @NewStatus = N'Processing',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Pending -> Processing', N'Processing', @C, CASE WHEN @C = N'Processing' THEN 1 ELSE 0 END);

-- Keyset page 1 and 2 (page size 5 over CustomerId)
PRINT '--- Keyset page 1 ---';
EXEC share.usp_GetExportData @ExportRequestId = @E, @UserName = N'gov.analyst', @PageSize = 5, @IncludeTotalCount = 1,
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export data: keyset page 1', N'OK', @C, CASE WHEN @C = N'OK' THEN 1 ELSE 0 END);

DECLARE @After NVARCHAR(100) =
    (SELECT CONVERT(NVARCHAR(100), MAX(CustomerId)) FROM (SELECT TOP (5) CustomerId FROM ingest.Customer
     WHERE CreditLimit >= 0 ORDER BY CustomerId) x);
PRINT '--- Keyset page 2 ---';
EXEC share.usp_GetExportData @ExportRequestId = @E, @UserName = N'gov.analyst', @PageSize = 5, @AfterKey = @After,
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export data: keyset page 2', N'OK', @C, CASE WHEN @C = N'OK' THEN 1 ELSE 0 END);

EXEC share.usp_GetExportData @ExportRequestId = @E, @UserName = N'gov.analyst', @PageSize = 5, @AfterKey = N'not-a-number',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export data: bad AfterKey', N'InvalidAfterKey', @C, CASE WHEN @C = N'InvalidAfterKey' THEN 1 ELSE 0 END);

EXEC share.usp_GetExportData @ExportRequestId = @E, @UserName = N'gov.viewer', @PageSize = 5,
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export data: other user blocked', N'Unauthorized', @C, CASE WHEN @C = N'Unauthorized' THEN 1 ELSE 0 END);

DECLARE @Rows BIGINT = (SELECT COUNT_BIG(*) FROM ingest.Customer WHERE CreditLimit >= 0);
EXEC share.usp_TransitionExportStatus @ExportRequestId = @E, @NewStatus = N'Completed', @RecordCount = @Rows,
    @FileSizeBytes = 1024, @FileReference = N'exports/test/customer.csv',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Processing -> Completed', N'Completed', @C, CASE WHEN @C = N'Completed' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E, @NewStatus = N'Pending',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Completed is terminal', N'InvalidTransition', @C, CASE WHEN @C = N'InvalidTransition' THEN 1 ELSE 0 END);

EXEC share.usp_RecordExportDownload @ExportRequestId = @E, @UserName = N'gov.viewer',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Download: other user blocked', N'Unauthorized', @C, CASE WHEN @C = N'Unauthorized' THEN 1 ELSE 0 END);

EXEC share.usp_RecordExportDownload @ExportRequestId = @E, @UserName = N'gov.analyst', @ClientInfo = N'tests',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Download: requester', N'Downloaded', @C, CASE WHEN @C = N'Downloaded' THEN 1 ELSE 0 END);

INSERT #T
SELECT N'Export: status history rows', N'3', CAST(COUNT(*) AS NVARCHAR(10)), CASE WHEN COUNT(*) = 3 THEN 1 ELSE 0 END
FROM share.ExportStatusHistory WHERE ExportRequestId = @E;

INSERT #T
SELECT N'Audit: export events (requested/started/completed/downloaded)', N'4', CAST(COUNT(DISTINCT EventType) AS NVARCHAR(10)),
       CASE WHEN COUNT(DISTINCT EventType) = 4 THEN 1 ELSE 0 END
FROM gov.GovernanceAuditEvent
WHERE EventType IN (N'ExportRequested', N'ExportStarted', N'ExportCompleted', N'ExportDownloaded')
  AND JSON_VALUE(DetailsJson, N'$.exportRequestId') = CAST(@E AS NVARCHAR(36));

-- Offset paging with custom sort + retry flow
DECLARE @E3 UNIQUEIDENTIFIER;
DECLARE @Filters3 NVARCHAR(MAX) =
    N'[{"column":"CountryCode","op":"notnull"},{"column":"CustomerCode","op":"ne","value":"' + @Tag + N'"}]';
EXEC share.usp_SubmitExportRequest @DatasetCode = N'CUSTOMER', @UserName = N'gov.owner', @FormatCode = N'Json',
    @SelectedColumnsJson = N'["CustomerName","CountryCode","CreditLimit"]', @FiltersJson = @Filters3,
    @SortJson = N'[{"column":"CreditLimit","dir":"desc"}]',
    @ExportRequestId = @E3 OUTPUT, @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
EXEC share.usp_TransitionExportStatus @ExportRequestId = @E3, @NewStatus = N'Processing',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
PRINT '--- Offset page 2 (sorted by CreditLimit desc) ---';
EXEC share.usp_GetExportData @ExportRequestId = @E3, @PageSize = 4, @PageNumber = 2, @IncludeTotalCount = 1,
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export data: offset page with sort', N'OK', @C, CASE WHEN @C = N'OK' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E3, @NewStatus = N'Failed',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Failed needs reason', N'FailureReasonRequired', @C, CASE WHEN @C = N'FailureReasonRequired' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E3, @NewStatus = N'Failed', @FailureReason = N'test failure',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Processing -> Failed', N'Failed', @C, CASE WHEN @C = N'Failed' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E3, @NewStatus = N'Pending',
    @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Failed -> Pending (retry)', N'Pending', @C, CASE WHEN @C = N'Pending' THEN 1 ELSE 0 END);

EXEC share.usp_TransitionExportStatus @ExportRequestId = @E3, @NewStatus = N'Cancelled', @ActorUserName = N'gov.owner',
    @FailureReason = N'test cleanup', @StatusCode = @C OUTPUT, @StatusMessage = @M OUTPUT;
INSERT #T VALUES (N'Export: Pending -> Cancelled', N'Cancelled', @C, CASE WHEN @C = N'Cancelled' THEN 1 ELSE 0 END);
GO

-- ------------------------------------------------------------
-- History / reporting smoke
-- ------------------------------------------------------------
PRINT '=== Export history (analyst, page 1) ===';
EXEC share.usp_GetExportHistory @UserName = N'gov.analyst', @PageSize = 10;
PRINT '=== Failed exports ===';
EXEC share.usp_GetExportHistory @Status = N'Failed';
PRINT '=== Export summary ===';
EXEC rpt.usp_ExportSummary;
PRINT '=== By format ===';
EXEC rpt.usp_ExportsByFormat;
PRINT '=== By dataset ===';
EXEC rpt.usp_ExportsByDataset;
PRINT '=== By user ===';
EXEC rpt.usp_ExportsByUser;
PRINT '=== Activity (7 days) ===';
EXEC rpt.usp_ExportActivityByDate @Days = 7;
PRINT '=== Share status summary ===';
EXEC rpt.usp_ShareStatusSummary;
PRINT '=== Expired shares (not yet marked) ===';
EXEC share.usp_GetExpiredShares @OnlyUnmarked = 1;
GO

INSERT #T
SELECT N'Report: summary totals consistent', N'Total = sum of statuses',
       CONCAT(COUNT(*), N' vs ', SUM(CASE WHEN Status IN (N'Pending', N'Processing', N'Completed', N'Failed', N'Cancelled') THEN 1 ELSE 0 END)),
       CASE WHEN COUNT(*) = SUM(CASE WHEN Status IN (N'Pending', N'Processing', N'Completed', N'Failed', N'Cancelled') THEN 1 ELSE 0 END) THEN 1 ELSE 0 END
FROM share.ExportRequest;
GO

PRINT '=== Test results ===';
SELECT Id, TestName, Expected, Actual, CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result FROM #T ORDER BY Id;
DECLARE @Failed INT = (SELECT COUNT(*) FROM #T WHERE Passed = 0);
DECLARE @Total INT = (SELECT COUNT(*) FROM #T);
PRINT CONCAT('Sharing tests: ', @Total - @Failed, '/', @Total, ' passed.');
IF @Failed > 0 RAISERROR('Sharing tests failed.', 16, 1);
GO
