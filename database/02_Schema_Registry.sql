-- ============================================================
-- 02_Schema_Registry.sql
-- Data Source Registry tables
-- ============================================================
USE EDIP;
GO

IF OBJECT_ID(N'reg.DataSourceType', N'U') IS NULL
BEGIN
    CREATE TABLE reg.DataSourceType
    (
        DataSourceTypeId   INT           NOT NULL CONSTRAINT PK_DataSourceType PRIMARY KEY,
        TypeCode           NVARCHAR(32)  NOT NULL,
        DisplayName        NVARCHAR(100) NOT NULL,
        CONSTRAINT UQ_DataSourceType_TypeCode UNIQUE (TypeCode)
    );
END
GO

IF OBJECT_ID(N'reg.DataSource', N'U') IS NULL
BEGIN
    CREATE TABLE reg.DataSource
    (
        DataSourceId       UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DataSource PRIMARY KEY
                           CONSTRAINT DF_DataSource_Id DEFAULT NEWSEQUENTIALID(),
        Name               NVARCHAR(200)    NOT NULL,
        Description        NVARCHAR(1000)   NULL,
        DataSourceTypeId   INT              NOT NULL,
        Status             NVARCHAR(32)     NOT NULL CONSTRAINT DF_DataSource_Status DEFAULT N'Active',
        HealthStatus       NVARCHAR(32)     NOT NULL CONSTRAINT DF_DataSource_Health DEFAULT N'Unknown',
        LastValidatedUtc   DATETIME2(3)     NULL,
        CreatedUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_DataSource_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_DataSource_Modified DEFAULT SYSUTCDATETIME(),
        IsDeleted          BIT              NOT NULL CONSTRAINT DF_DataSource_IsDeleted DEFAULT (0),
        CONSTRAINT FK_DataSource_Type FOREIGN KEY (DataSourceTypeId)
            REFERENCES reg.DataSourceType (DataSourceTypeId),
        CONSTRAINT CK_DataSource_Status CHECK (Status IN (N'Active', N'Inactive', N'Disabled')),
        CONSTRAINT CK_DataSource_Health CHECK (HealthStatus IN (N'Unknown', N'Healthy', N'Degraded', N'Unhealthy'))
    );

    CREATE UNIQUE INDEX UX_DataSource_Name_Active
        ON reg.DataSource (Name)
        WHERE IsDeleted = 0;

    CREATE INDEX IX_DataSource_Type ON reg.DataSource (DataSourceTypeId) WHERE IsDeleted = 0;
    CREATE INDEX IX_DataSource_Health ON reg.DataSource (HealthStatus) WHERE IsDeleted = 0;
END
GO

IF OBJECT_ID(N'reg.SqlConnectionDetail', N'U') IS NULL
BEGIN
    CREATE TABLE reg.SqlConnectionDetail
    (
        DataSourceId              UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_SqlConnectionDetail PRIMARY KEY,
        Host                      NVARCHAR(255)    NOT NULL,
        Port                      INT              NOT NULL,
        DatabaseName              NVARCHAR(128)    NOT NULL,
        AuthMode                  NVARCHAR(32)     NOT NULL CONSTRAINT DF_SqlConn_Auth DEFAULT N'SqlPassword',
        Username                  NVARCHAR(128)    NOT NULL,
        EncryptedPassword         NVARCHAR(MAX)    NULL,
        TrustServerCertificate    BIT              NOT NULL CONSTRAINT DF_SqlConn_Trust DEFAULT (1),
        ConnectionTimeoutSeconds  INT              NOT NULL CONSTRAINT DF_SqlConn_Timeout DEFAULT (30),
        CONSTRAINT FK_SqlConnectionDetail_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_SqlConn_Auth CHECK (AuthMode IN (N'SqlPassword', N'Windows', N'Integrated'))
    );
END
GO

IF OBJECT_ID(N'reg.FileDataSourceDetail', N'U') IS NULL
BEGIN
    CREATE TABLE reg.FileDataSourceDetail
    (
        DataSourceId   UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_FileDataSourceDetail PRIMARY KEY,
        FilePath       NVARCHAR(1000)   NOT NULL,
        Format         NVARCHAR(16)     NOT NULL,
        Delimiter      NVARCHAR(8)      NOT NULL CONSTRAINT DF_File_Delimiter DEFAULT N',',
        HasHeaderRow   BIT              NOT NULL CONSTRAINT DF_File_Header DEFAULT (1),
        SheetName      NVARCHAR(128)    NULL,
        EncodingName   NVARCHAR(32)     NOT NULL CONSTRAINT DF_File_Encoding DEFAULT N'UTF-8',
        CONSTRAINT FK_FileDataSourceDetail_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_File_Format CHECK (Format IN (N'CSV', N'Excel'))
    );
END
GO

IF OBJECT_ID(N'reg.ConnectionValidationLog', N'U') IS NULL
BEGIN
    CREATE TABLE reg.ConnectionValidationLog
    (
        ValidationLogId BIGINT           NOT NULL IDENTITY(1,1)
                        CONSTRAINT PK_ConnectionValidationLog PRIMARY KEY,
        DataSourceId    UNIQUEIDENTIFIER NOT NULL,
        IsSuccess       BIT              NOT NULL,
        Message         NVARCHAR(2000)   NULL,
        LatencyMs       INT              NULL,
        ValidatedUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_ValidationLog_Utc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ValidationLog_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId)
    );

    CREATE INDEX IX_ValidationLog_Source_Utc
        ON reg.ConnectionValidationLog (DataSourceId, ValidatedUtc DESC);
END
GO

PRINT 'Registry schema objects created.';
GO
