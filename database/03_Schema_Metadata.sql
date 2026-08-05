-- ============================================================
-- 03_Schema_Metadata.sql
-- Metadata Repository tables
-- ============================================================
USE EDIP;
GO

IF OBJECT_ID(N'meta.SchemaObject', N'U') IS NULL
BEGIN
    CREATE TABLE meta.SchemaObject
    (
        SchemaObjectId UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_SchemaObject PRIMARY KEY
                       CONSTRAINT DF_SchemaObject_Id DEFAULT NEWSEQUENTIALID(),
        DataSourceId   UNIQUEIDENTIFIER NOT NULL,
        SchemaName     NVARCHAR(128)    NOT NULL CONSTRAINT DF_SchemaObject_Schema DEFAULT N'dbo',
        ObjectName     NVARCHAR(256)    NOT NULL,
        ObjectType     NVARCHAR(16)     NOT NULL,
        CapturedUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_SchemaObject_Captured DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_SchemaObject_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_SchemaObject_Type CHECK (ObjectType IN (N'Table', N'View')),
        CONSTRAINT UQ_SchemaObject UNIQUE (DataSourceId, SchemaName, ObjectName, ObjectType)
    );

    CREATE INDEX IX_SchemaObject_Source ON meta.SchemaObject (DataSourceId);
END
GO

IF OBJECT_ID(N'meta.ColumnDefinition', N'U') IS NULL
BEGIN
    CREATE TABLE meta.ColumnDefinition
    (
        ColumnDefinitionId UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ColumnDefinition PRIMARY KEY
                           CONSTRAINT DF_ColumnDefinition_Id DEFAULT NEWSEQUENTIALID(),
        SchemaObjectId     UNIQUEIDENTIFIER NOT NULL,
        ColumnName         NVARCHAR(256)    NOT NULL,
        DataType           NVARCHAR(128)    NOT NULL,
        MaxLength          INT              NULL,
        NumericPrecision   TINYINT          NULL,
        NumericScale       INT              NULL,
        IsNullable         BIT              NOT NULL CONSTRAINT DF_Column_Nullable DEFAULT (1),
        OrdinalPosition    INT              NOT NULL,
        IsPrimaryKey       BIT              NOT NULL CONSTRAINT DF_Column_PK DEFAULT (0),
        IsForeignKey       BIT              NOT NULL CONSTRAINT DF_Column_FK DEFAULT (0),
        CONSTRAINT FK_ColumnDefinition_SchemaObject FOREIGN KEY (SchemaObjectId)
            REFERENCES meta.SchemaObject (SchemaObjectId) ON DELETE CASCADE,
        CONSTRAINT UQ_ColumnDefinition UNIQUE (SchemaObjectId, ColumnName)
    );

    CREATE INDEX IX_ColumnDefinition_Object ON meta.ColumnDefinition (SchemaObjectId);
END
GO

IF OBJECT_ID(N'meta.ObjectRelationship', N'U') IS NULL
BEGIN
    CREATE TABLE meta.ObjectRelationship
    (
        RelationshipId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ObjectRelationship PRIMARY KEY
                          CONSTRAINT DF_ObjectRelationship_Id DEFAULT NEWSEQUENTIALID(),
        DataSourceId      UNIQUEIDENTIFIER NOT NULL,
        ParentObjectId    UNIQUEIDENTIFIER NOT NULL,
        ChildObjectId     UNIQUEIDENTIFIER NOT NULL,
        ParentColumnName  NVARCHAR(256)    NOT NULL,
        ChildColumnName   NVARCHAR(256)    NOT NULL,
        ConstraintName    NVARCHAR(256)    NULL,
        CONSTRAINT FK_Relationship_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT FK_Relationship_Parent FOREIGN KEY (ParentObjectId)
            REFERENCES meta.SchemaObject (SchemaObjectId),
        CONSTRAINT FK_Relationship_Child FOREIGN KEY (ChildObjectId)
            REFERENCES meta.SchemaObject (SchemaObjectId)
    );

    CREATE INDEX IX_Relationship_Source ON meta.ObjectRelationship (DataSourceId);
END
GO

IF OBJECT_ID(N'meta.MetadataRefreshHistory', N'U') IS NULL
BEGIN
    CREATE TABLE meta.MetadataRefreshHistory
    (
        RefreshHistoryId      BIGINT           NOT NULL IDENTITY(1,1)
                              CONSTRAINT PK_MetadataRefreshHistory PRIMARY KEY,
        DataSourceId          UNIQUEIDENTIFIER NOT NULL,
        StartedUtc            DATETIME2(3)     NOT NULL CONSTRAINT DF_Refresh_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc          DATETIME2(3)     NULL,
        Status                NVARCHAR(32)     NOT NULL CONSTRAINT DF_Refresh_Status DEFAULT N'Running',
        ObjectsCaptured       INT              NOT NULL CONSTRAINT DF_Refresh_Objects DEFAULT (0),
        ColumnsCaptured       INT              NOT NULL CONSTRAINT DF_Refresh_Columns DEFAULT (0),
        RelationshipsCaptured INT              NOT NULL CONSTRAINT DF_Refresh_Rels DEFAULT (0),
        ErrorMessage          NVARCHAR(MAX)    NULL,
        CONSTRAINT FK_RefreshHistory_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_Refresh_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed'))
    );

    CREATE INDEX IX_RefreshHistory_Source_Utc
        ON meta.MetadataRefreshHistory (DataSourceId, StartedUtc DESC);
END
GO

PRINT 'Metadata schema objects created.';
GO
