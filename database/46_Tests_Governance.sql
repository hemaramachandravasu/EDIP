-- ============================================================
-- 46_Tests_Governance.sql
-- ============================================================
USE EDIP;
GO

PRINT '=== Governance summary ===';
EXEC rpt.usp_GovernanceSummary;

PRINT '=== CUSTOMER governance ===';
EXEC gov.usp_GetDatasetGovernance @DatasetCode = N'CUSTOMER';

PRINT '=== Certification history ===';
EXEC gov.usp_GetCertificationHistory @DatasetCode = N'CUSTOMER';

PRINT '=== Pending access requests ===';
EXEC gov.usp_GetPendingAccessRequests;

PRINT '=== Policy: analyst Write on CUSTOMER (expect allowed via grant) ===';
EXEC gov.usp_EvaluateDatasetAccess @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @RequiredAccessLevel = N'Write';

PRINT '=== Policy: outsider Read on CUSTOMER (expect denied) ===';
EXEC gov.usp_EvaluateDatasetAccess @DatasetCode = N'CUSTOMER', @UserName = N'gov.outsider', @RequiredAccessLevel = N'Read';

PRINT '=== Policy: owner Admin ===';
EXEC gov.usp_EvaluateDatasetAccess @DatasetCode = N'CUSTOMER', @UserName = N'gov.owner', @RequiredAccessLevel = N'Admin';

PRINT '=== By classification ===';
EXEC rpt.usp_DatasetsByClassification;

PRINT '=== Status distribution ===';
EXEC rpt.usp_GovernanceStatusDistribution;

PRINT '=== Access requests by workspace ===';
EXEC rpt.usp_AccessRequestsByWorkspace;

PRINT 'Governance tests complete.';
GO
