-- ============================================================
-- 01_CreateDatabase.sql
-- Creates the EDIP database and schemas
-- ============================================================
IF DB_ID(N'EDIP') IS NULL
BEGIN
    CREATE DATABASE EDIP;
END
GO

USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'reg')
    EXEC(N'CREATE SCHEMA reg AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'meta')
    EXEC(N'CREATE SCHEMA meta AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'jobs')
    EXEC(N'CREATE SCHEMA jobs AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'rpt')
    EXEC(N'CREATE SCHEMA rpt AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dq')
    EXEC(N'CREATE SCHEMA dq AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ingest')
    EXEC(N'CREATE SCHEMA ingest AUTHORIZATION dbo;');
GO

PRINT 'EDIP database and schemas ready.';
GO
