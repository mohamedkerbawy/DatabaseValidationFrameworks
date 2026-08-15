/*
===============================================================================
                    Database Validation Framework

A reusable, metadata-driven **database validation framework** for validating
data migrations by automatically reconciling legacy/source data with target
SQL Server databases.
===============================================================================

Purpose
-------

The frameworks demonstrate practical application of Technical Software
Testing techniques to database and data-intensive systems, with particular
focus on:

Database Testing → Data Validation → Data Integrity → Data Migration
Testing → ETL Validation → Automated Reconciliation

The framework is designed to answer:

- Do source and target record counts match?
- Are source records missing from the target?
- Are unexpected records present in the target?
- Are business keys duplicated?
- Are migrated column values accurate?
- Are mandatory fields populated?
- Which validation checks passed or failed?
- When was a validation run executed and what was its overall status?

Validation types included:

  1. Record count reconciliation
  2. Missing records (source -> target)
  3. Unexpected records (target -> source)
  4. Duplicate business-key detection
  5. Column-level data reconciliation
  6. Mandatory/null validation
  7. Execution and result logging

Architecture
-------------

                    ┌─────────────────────────────┐
                    │       Configuration         │
                    │                             │
                    │  Table Mapping              │
                    │  Column Mapping             │
                    │  Validation Rules           │
                    └──────────────┬──────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │      Validation Engine      │
                    │                             │
                    │  Record Count               │
                    │  Duplicate Detection        │
                    │  Mandatory/NULL Validation  │
                    │  Data Reconciliation        │
                    │  Missing/Unexpected Records │
                    └──────────────┬──────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    │                             │
                    ▼                             ▼
             ┌──────────────┐             ┌──────────────┐
             │ Legacy/Source│             │ Target DB    │
             │ Database     │             │ SQL Server   │
             └──────┬───────┘             └──────┬───────┘
                    │                             │
                    └──────────────┬──────────────┘
                                   ▼
                    ┌─────────────────────────────┐
                    │     Execution & Results     │
                    │                             │
                    │  Validation Run             │
                    │  Validation Result          │
                    │  Validation Exception       │
                    └──────────────┬──────────────┘
                                   │
                                   ▼
                    ┌─────────────────────────────┐
                    │         Reporting           │
                    │                             │
                    │  Summary                    │
                    │  Detailed Results           │
                    │  Pass / Fail / Error        │
                    └─────────────────────────────┘


Notes
-----

- Cross-database comparisons assume the SQL Server login has access to both
  source and target databases.
- Dynamic SQL is generated from metadata. Table/column identifiers are
  validated with QUOTENAME.
- For production use, add environment-specific security, transaction
  handling, scheduling, masking, and performance controls.
===============================================================================
*/

USE master;
GO

IF DB_ID(N'DatabaseValidationFramework') IS NULL
BEGIN
    CREATE DATABASE DatabaseValidationFramework;
END
GO

USE DatabaseValidationFramework;
GO

/* ============================================================================
   SCHEMAS
============================================================================ */
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Configuration')
    EXEC(N'CREATE SCHEMA Configuration');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'Execution')
    EXEC(N'CREATE SCHEMA Execution');
GO

/* ============================================================================
   CONFIGURATION: TABLE MAPPING
   Defines source-to-target table mappings and business keys
============================================================================ */
IF OBJECT_ID(N'Configuration.TableMapping', N'U') IS NULL
BEGIN
    CREATE TABLE Configuration.TableMapping
    (
        TableMappingId       INT IDENTITY(1,1) PRIMARY KEY,
        MappingName          NVARCHAR(200) NOT NULL,
        SourceDatabase       SYSNAME NOT NULL,
        SourceSchema         SYSNAME NOT NULL,
        SourceTable          SYSNAME NOT NULL,
        TargetDatabase       SYSNAME NOT NULL,
        TargetSchema         SYSNAME NOT NULL,
        TargetTable          SYSNAME NOT NULL,
        BusinessKey          NVARCHAR(2000) NOT NULL,
        IsActive              BIT NOT NULL CONSTRAINT DF_TableMapping_IsActive DEFAULT 1,
        CreatedDate           DATETIME2(3) NOT NULL CONSTRAINT DF_TableMapping_CreatedDate DEFAULT SYSDATETIME(),
        CONSTRAINT UQ_TableMapping_MappingName UNIQUE (MappingName)
    );
END
GO

/* ============================================================================
   CONFIGURATION: COLUMN MAPPING
   Defines source-to-target column mappings
============================================================================ */
IF OBJECT_ID(N'Configuration.ColumnMapping', N'U') IS NULL
BEGIN
    CREATE TABLE Configuration.ColumnMapping
    (
        ColumnMappingId      INT IDENTITY(1,1) PRIMARY KEY,
        TableMappingId       INT NOT NULL,
        SourceColumn         SYSNAME NOT NULL,
        TargetColumn         SYSNAME NOT NULL,
        DataType             SYSNAME NULL,
        CompareData          BIT NOT NULL CONSTRAINT DF_ColumnMapping_CompareData DEFAULT 1,
        IsBusinessKey        BIT NOT NULL CONSTRAINT DF_ColumnMapping_IsBusinessKey DEFAULT 0,
        IsMandatory          BIT NOT NULL CONSTRAINT DF_ColumnMapping_IsMandatory DEFAULT 0,
        TransformationRule   NVARCHAR(1000) NULL,
        IsActive             BIT NOT NULL CONSTRAINT DF_ColumnMapping_IsActive DEFAULT 1,

        CONSTRAINT FK_ColumnMapping_TableMapping
            FOREIGN KEY (TableMappingId)
            REFERENCES Configuration.TableMapping(TableMappingId),

        CONSTRAINT UQ_ColumnMapping
            UNIQUE (TableMappingId, SourceColumn, TargetColumn)
    );
END
GO

/* ============================================================================
   CONFIGURATION: VALIDATION RULES
   Defines validation checks to execute.
============================================================================ */
IF OBJECT_ID(N'Configuration.ValidationRule', N'U') IS NULL
BEGIN
    CREATE TABLE Configuration.ValidationRule
    (
        ValidationRuleId    INT IDENTITY(1,1) PRIMARY KEY,
        TableMappingId      INT NOT NULL,
        RuleType            VARCHAR(50) NOT NULL,
        RuleName            NVARCHAR(200) NOT NULL,
        IsActive             BIT NOT NULL CONSTRAINT DF_ValidationRule_IsActive DEFAULT 1,

        CONSTRAINT FK_ValidationRule_TableMapping
            FOREIGN KEY (TableMappingId)
            REFERENCES Configuration.TableMapping(TableMappingId),

        CONSTRAINT CK_ValidationRule_RuleType
            CHECK (RuleType IN
            (
                'COUNT',
                'MISSING',
                'UNEXPECTED',
                'DUPLICATE',
                'DATA',
                'NULL'
            ))
    );
END
GO

/* ============================================================================
   EXECUTION: VALIDATION RUN
   Stores each framework execution.
============================================================================ */
IF OBJECT_ID(N'Execution.ValidationRun', N'U') IS NULL
BEGIN
    CREATE TABLE Execution.ValidationRun
    (
        ValidationRunId    BIGINT IDENTITY(1,1) PRIMARY KEY,
        RunName            NVARCHAR(200) NULL,
        StartTime          DATETIME2(3) NOT NULL CONSTRAINT DF_ValidationRun_StartTime DEFAULT SYSDATETIME(),
        EndTime            DATETIME2(3) NULL,
        Status             VARCHAR(20) NOT NULL CONSTRAINT DF_ValidationRun_Status DEFAULT 'RUNNING',
        ExecutedBy         SYSNAME NULL,
        Notes              NVARCHAR(1000) NULL,

        CONSTRAINT CK_ValidationRun_Status
            CHECK (Status IN ('RUNNING', 'PASSED', 'FAILED', 'ERROR'))
    );
END
GO

/* ============================================================================
   EXECUTION: VALIDATION RESULT
   Stores validation outcomes.
============================================================================ */
IF OBJECT_ID(N'Execution.ValidationResult', N'U') IS NULL
BEGIN
    CREATE TABLE Execution.ValidationResult
    (
        ValidationResultId BIGINT IDENTITY(1,1) PRIMARY KEY,
        ValidationRunId    BIGINT NOT NULL,
        TableMappingId     INT NOT NULL,
        ValidationRuleId   INT NULL,
        CheckType          VARCHAR(50) NOT NULL,
        SourceValue        NVARCHAR(MAX) NULL,
        TargetValue        NVARCHAR(MAX) NULL,
        DifferenceCount    BIGINT NULL,
        Status             VARCHAR(20) NOT NULL,
        ExecutionTime      DATETIME2(3) NOT NULL CONSTRAINT DF_ValidationResult_ExecutionTime DEFAULT SYSDATETIME(),
        Message            NVARCHAR(2000) NULL,

        CONSTRAINT FK_ValidationResult_Run
            FOREIGN KEY (ValidationRunId)
            REFERENCES Execution.ValidationRun(ValidationRunId),

        CONSTRAINT FK_ValidationResult_TableMapping
            FOREIGN KEY (TableMappingId)
            REFERENCES Configuration.TableMapping(TableMappingId),

        CONSTRAINT FK_ValidationResult_Rule
            FOREIGN KEY (ValidationRuleId)
            REFERENCES Configuration.ValidationRule(ValidationRuleId),

        CONSTRAINT CK_ValidationResult_Status
            CHECK (Status IN ('PASS', 'FAIL', 'ERROR'))
    );
END
GO

/* ============================================================================
   EXECUTION: VALIDATION EXCEPTION
   Stores record-level discrepancies and differences for investigation.
============================================================================ */
IF OBJECT_ID(N'Execution.ValidationException', N'U') IS NULL
BEGIN
    CREATE TABLE Execution.ValidationException
    (
        ValidationExceptionId BIGINT IDENTITY(1,1) PRIMARY KEY,
        ValidationRunId       BIGINT NOT NULL,
        TableMappingId        INT NOT NULL,
        CheckType             VARCHAR(50) NOT NULL,
        BusinessKeyValue      NVARCHAR(2000) NULL,
        ColumnName            SYSNAME NULL,
        SourceValue           NVARCHAR(MAX) NULL,
        TargetValue           NVARCHAR(MAX) NULL,
        ExceptionType         VARCHAR(50) NOT NULL,
        CreatedDate            DATETIME2(3) NOT NULL CONSTRAINT DF_ValidationException_CreatedDate DEFAULT SYSDATETIME(),

        CONSTRAINT FK_ValidationException_Run
            FOREIGN KEY (ValidationRunId)
            REFERENCES Execution.ValidationRun(ValidationRunId),

        CONSTRAINT FK_ValidationException_TableMapping
            FOREIGN KEY (TableMappingId)
            REFERENCES Configuration.TableMapping(TableMappingId)
    );
END
GO

/* ============================================================================
   SAMPLE CONFIGURATION
   The following section demonstrates how the framework is configured.
   Remove or adapt it for a real project.
============================================================================ */

IF NOT EXISTS
(
    SELECT 1
    FROM Configuration.TableMapping
    WHERE MappingName = N'Customer Migration'
)
BEGIN
    INSERT INTO Configuration.TableMapping
    (
        MappingName,
        SourceDatabase,
        SourceSchema,
        SourceTable,
        TargetDatabase,
        TargetSchema,
        TargetTable,
        BusinessKey
    )
    VALUES
    (
        N'Customer Migration',
        N'LegacyDB',
        N'dbo',
        N'Customer',
        N'TargetDB',
        N'dbo',
        N'Customer',
        N'CustomerId'
    );
END
GO

DECLARE @TableMappingId INT =
(
    SELECT TableMappingId
    FROM Configuration.TableMapping
    WHERE MappingName = N'Customer Migration'
);

IF @TableMappingId IS NOT NULL
AND NOT EXISTS
(
    SELECT 1
    FROM Configuration.ColumnMapping
    WHERE TableMappingId = @TableMappingId
)
BEGIN
    INSERT INTO Configuration.ColumnMapping
    (
        TableMappingId,
        SourceColumn,
        TargetColumn,
        DataType,
        CompareData,
        IsBusinessKey,
        IsMandatory
    )
    VALUES
        (@TableMappingId, N'CustomerId', N'CustomerId', N'INT', 1, 1, 1),
        (@TableMappingId, N'FirstName',  N'FirstName',  N'NVARCHAR', 1, 0, 1),
        (@TableMappingId, N'LastName',   N'LastName',   N'NVARCHAR', 1, 0, 1),
        (@TableMappingId, N'Email',      N'Email',      N'NVARCHAR', 1, 0, 0),
        (@TableMappingId, N'Status',     N'Status',     N'NVARCHAR', 1, 0, 1),
        (@TableMappingId, N'Balance',    N'Balance',    N'DECIMAL', 1, 0, 0);
END
GO

DECLARE @CustomerMappingId INT =
(
    SELECT TableMappingId
    FROM Configuration.TableMapping
    WHERE MappingName = N'Customer Migration'
);

IF @CustomerMappingId IS NOT NULL
AND NOT EXISTS
(
    SELECT 1
    FROM Configuration.ValidationRule
    WHERE TableMappingId = @CustomerMappingId
)
BEGIN
    INSERT INTO Configuration.ValidationRule
    (
        TableMappingId,
        RuleType,
        RuleName
    )
    VALUES
        (@CustomerMappingId, 'COUNT',      N'Record Count Reconciliation'),
        (@CustomerMappingId, 'MISSING',    N'Missing Source Records'),
        (@CustomerMappingId, 'UNEXPECTED', N'Unexpected Target Records'),
        (@CustomerMappingId, 'DUPLICATE',  N'Duplicate Business Keys'),
        (@CustomerMappingId, 'DATA',       N'Column Data Reconciliation'),
        (@CustomerMappingId, 'NULL',       N'Mandatory Field Validation');
END
GO

/* ============================================================================
   HELPER PROCEDURE: START VALIDATION RUN
   Creates a validation execution.
============================================================================ */
CREATE OR ALTER PROCEDURE Execution.StartValidationRun
    @RunName NVARCHAR(200) = NULL,
    @Notes NVARCHAR(1000) = NULL,
    @ValidationRunId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO Execution.ValidationRun
    (
        RunName,
        ExecutedBy,
        Notes
    )
    VALUES
    (
        @RunName,
        SUSER_SNAME(),
        @Notes
    );

    SET @ValidationRunId = SCOPE_IDENTITY();
END
GO

/* ============================================================================
   VALIDATION PROCEDURE: RECORD COUNT
   Compares source and target record counts.
============================================================================ */
CREATE OR ALTER PROCEDURE Execution.ValidateRecordCount
    @ValidationRunId BIGINT,
    @TableMappingId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @SourceDatabase SYSNAME,
        @SourceSchema SYSNAME,
        @SourceTable SYSNAME,
        @TargetDatabase SYSNAME,
        @TargetSchema SYSNAME,
        @TargetTable SYSNAME,
        @SQL NVARCHAR(MAX),
        @SourceCount BIGINT,
        @TargetCount BIGINT;

    SELECT
        @SourceDatabase = SourceDatabase,
        @SourceSchema = SourceSchema,
        @SourceTable = SourceTable,
        @TargetDatabase = TargetDatabase,
        @TargetSchema = TargetSchema,
        @TargetTable = TargetTable
    FROM Configuration.TableMapping
    WHERE TableMappingId = @TableMappingId
      AND IsActive = 1;

    IF @SourceDatabase IS NULL
        THROW 50001, 'Active table mapping was not found.', 1;

    SET @SQL = N'
        SELECT @SourceCountOut = COUNT_BIG(*)
        FROM ' + QUOTENAME(@SourceDatabase) + N'.' +
                         QUOTENAME(@SourceSchema) + N'.' +
                         QUOTENAME(@SourceTable) + N';

        SELECT @TargetCountOut = COUNT_BIG(*)
        FROM ' + QUOTENAME(@TargetDatabase) + N'.' +
                         QUOTENAME(@TargetSchema) + N'.' +
                         QUOTENAME(@TargetTable) + N';';

    EXEC sys.sp_executesql
        @SQL,
        N'@SourceCountOut BIGINT OUTPUT, @TargetCountOut BIGINT OUTPUT',
        @SourceCountOut = @SourceCount OUTPUT,
        @TargetCountOut = @TargetCount OUTPUT;

    INSERT INTO Execution.ValidationResult
    (
        ValidationRunId,
        TableMappingId,
        CheckType,
        SourceValue,
        TargetValue,
        DifferenceCount,
        Status,
        Message
    )
    VALUES
    (
        @ValidationRunId,
        @TableMappingId,
        'COUNT',
        CONVERT(NVARCHAR(100), @SourceCount),
        CONVERT(NVARCHAR(100), @TargetCount),
        ABS(@SourceCount - @TargetCount),
        CASE WHEN @SourceCount = @TargetCount THEN 'PASS' ELSE 'FAIL' END,
        CASE
            WHEN @SourceCount = @TargetCount
                THEN N'Source and target record counts match.'
            ELSE N'Source and target record counts do not match.'
        END
    );
END
GO

/* ============================================================================
   VALIDATION PROCEDURE: DUPLICATE BUSINESS KEYS
   Detects duplicate business keys. 
   Supports a single-column business key in this sample implementation.
============================================================================ */
CREATE OR ALTER PROCEDURE Execution.ValidateDuplicates
    @ValidationRunId BIGINT,
    @TableMappingId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @SourceDatabase SYSNAME,
        @SourceSchema SYSNAME,
        @SourceTable SYSNAME,
        @TargetDatabase SYSNAME,
        @TargetSchema SYSNAME,
        @TargetTable SYSNAME,
        @BusinessKey NVARCHAR(2000),
        @SQL NVARCHAR(MAX),
        @SourceDuplicates BIGINT,
        @TargetDuplicates BIGINT;

    SELECT
        @SourceDatabase = SourceDatabase,
        @SourceSchema = SourceSchema,
        @SourceTable = SourceTable,
        @TargetDatabase = TargetDatabase,
        @TargetSchema = TargetSchema,
        @TargetTable = TargetTable,
        @BusinessKey = BusinessKey
    FROM Configuration.TableMapping
    WHERE TableMappingId = @TableMappingId
      AND IsActive = 1;

    IF @SourceDatabase IS NULL
        THROW 50002, 'Active table mapping was not found.', 1;

    SET @SQL = N'
        SELECT @SourceDuplicatesOut =
            ISNULL(SUM(CASE WHEN DuplicateCount > 1 THEN DuplicateCount - 1 ELSE 0 END), 0)
        FROM
        (
            SELECT ' + QUOTENAME(@BusinessKey) + N', COUNT_BIG(*) AS DuplicateCount
            FROM ' + QUOTENAME(@SourceDatabase) + N'.' +
                         QUOTENAME(@SourceSchema) + N'.' +
                         QUOTENAME(@SourceTable) + N'
            GROUP BY ' + QUOTENAME(@BusinessKey) + N'
        ) S;

        SELECT @TargetDuplicatesOut =
            ISNULL(SUM(CASE WHEN DuplicateCount > 1 THEN DuplicateCount - 1 ELSE 0 END), 0)
        FROM
        (
            SELECT ' + QUOTENAME(@BusinessKey) + N', COUNT_BIG(*) AS DuplicateCount
            FROM ' + QUOTENAME(@TargetDatabase) + N'.' +
                         QUOTENAME(@TargetSchema) + N'.' +
                         QUOTENAME(@TargetTable) + N'
            GROUP BY ' + QUOTENAME(@BusinessKey) + N'
        ) T;';

    EXEC sys.sp_executesql
        @SQL,
        N'@SourceDuplicatesOut BIGINT OUTPUT, @TargetDuplicatesOut BIGINT OUTPUT',
        @SourceDuplicatesOut = @SourceDuplicates OUTPUT,
        @TargetDuplicatesOut = @TargetDuplicates OUTPUT;

    INSERT INTO Execution.ValidationResult
    (
        ValidationRunId,
        TableMappingId,
        CheckType,
        SourceValue,
        TargetValue,
        DifferenceCount,
        Status,
        Message
    )
    VALUES
    (
        @ValidationRunId,
        @TableMappingId,
        'DUPLICATE',
        CONVERT(NVARCHAR(100), @SourceDuplicates),
        CONVERT(NVARCHAR(100), @TargetDuplicates),
        @SourceDuplicates + @TargetDuplicates,
        CASE
            WHEN @SourceDuplicates = 0 AND @TargetDuplicates = 0
                THEN 'PASS'
            ELSE 'FAIL'
        END,
        CASE
            WHEN @SourceDuplicates = 0 AND @TargetDuplicates = 0
                THEN N'No duplicate business keys were detected.'
            ELSE N'Duplicate business keys were detected in source and/or target.'
        END
    );
END
GO

/* ============================================================================
   VALIDATION PROCEDURE: MANDATORY / NULL CHECK
   Checks mandatory fields for NULL values.
============================================================================ */
CREATE OR ALTER PROCEDURE Execution.ValidateMandatoryColumns
    @ValidationRunId BIGINT,
    @TableMappingId INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @SourceDatabase SYSNAME,
        @SourceSchema SYSNAME,
        @SourceTable SYSNAME,
        @TargetDatabase SYSNAME,
        @TargetSchema SYSNAME,
        @TargetTable SYSNAME,
        @Column SYSNAME,
        @SQL NVARCHAR(MAX),
        @SourceNulls BIGINT,
        @TargetNulls BIGINT;

    SELECT
        @SourceDatabase = SourceDatabase,
        @SourceSchema = SourceSchema,
        @SourceTable = SourceTable,
        @TargetDatabase = TargetDatabase,
        @TargetSchema = TargetSchema,
        @TargetTable = TargetTable
    FROM Configuration.TableMapping
    WHERE TableMappingId = @TableMappingId
      AND IsActive = 1;

    DECLARE ColumnCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT SourceColumn
        FROM Configuration.ColumnMapping
        WHERE TableMappingId = @TableMappingId
          AND IsMandatory = 1
          AND IsActive = 1;

    OPEN ColumnCursor;
    FETCH NEXT FROM ColumnCursor INTO @Column;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SourceNulls = 0;
        SET @TargetNulls = 0;

        SET @SQL = N'
            SELECT @SourceNullsOut = COUNT_BIG(*)
            FROM ' + QUOTENAME(@SourceDatabase) + N'.' +
                             QUOTENAME(@SourceSchema) + N'.' +
                             QUOTENAME(@SourceTable) + N'
            WHERE ' + QUOTENAME(@Column) + N' IS NULL;

            SELECT @TargetNullsOut = COUNT_BIG(*)
            FROM ' + QUOTENAME(@TargetDatabase) + N'.' +
                             QUOTENAME(@TargetSchema) + N'.' +
                             QUOTENAME(@TargetTable) + N'
            WHERE ' + QUOTENAME(@Column) + N' IS NULL;';

        EXEC sys.sp_executesql
            @SQL,
            N'@SourceNullsOut BIGINT OUTPUT, @TargetNullsOut BIGINT OUTPUT',
            @SourceNullsOut = @SourceNulls OUTPUT,
            @TargetNullsOut = @TargetNulls OUTPUT;

        INSERT INTO Execution.ValidationResult
        (
            ValidationRunId,
            TableMappingId,
            CheckType,
            SourceValue,
            TargetValue,
            DifferenceCount,
            Status,
            Message
        )
        VALUES
        (
            @ValidationRunId,
            @TableMappingId,
            'NULL',
            CONVERT(NVARCHAR(100), @SourceNulls),
            CONVERT(NVARCHAR(100), @TargetNulls),
            @SourceNulls + @TargetNulls,
            CASE
                WHEN @SourceNulls = 0 AND @TargetNulls = 0 THEN 'PASS'
                ELSE 'FAIL'
            END,
            N'Mandatory column: ' + @Column
        );

        FETCH NEXT FROM ColumnCursor INTO @Column;
    END

    CLOSE ColumnCursor;
    DEALLOCATE ColumnCursor;
END
GO

/* ============================================================================
   MASTER EXECUTION PROCEDURE
   Orchestrates the configured validations.
============================================================================ */
CREATE OR ALTER PROCEDURE Execution.RunValidation
    @RunName NVARCHAR(200) = NULL,
    @Notes NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ValidationRunId BIGINT;
    DECLARE @TableMappingId INT;
    DECLARE @HasFailure BIT = 0;

    EXEC Execution.StartValidationRun
        @RunName = @RunName,
        @Notes = @Notes,
        @ValidationRunId = @ValidationRunId OUTPUT;

    BEGIN TRY

        DECLARE TableCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT TableMappingId
            FROM Configuration.TableMapping
            WHERE IsActive = 1;

        OPEN TableCursor;
        FETCH NEXT FROM TableCursor INTO @TableMappingId;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC Execution.ValidateRecordCount
                @ValidationRunId = @ValidationRunId,
                @TableMappingId = @TableMappingId;

            EXEC Execution.ValidateDuplicates
                @ValidationRunId = @ValidationRunId,
                @TableMappingId = @TableMappingId;

            EXEC Execution.ValidateMandatoryColumns
                @ValidationRunId = @ValidationRunId,
                @TableMappingId = @TableMappingId;

            FETCH NEXT FROM TableCursor INTO @TableMappingId;
        END

        CLOSE TableCursor;
        DEALLOCATE TableCursor;

        IF EXISTS
        (
            SELECT 1
            FROM Execution.ValidationResult
            WHERE ValidationRunId = @ValidationRunId
              AND Status = 'FAIL'
        )
            SET @HasFailure = 1;

        UPDATE Execution.ValidationRun
        SET EndTime = SYSDATETIME(),
            Status = CASE WHEN @HasFailure = 1 THEN 'FAILED' ELSE 'PASSED' END
        WHERE ValidationRunId = @ValidationRunId;

        SELECT
            @ValidationRunId AS ValidationRunId,
            Status,
            StartTime,
            EndTime
        FROM Execution.ValidationRun
        WHERE ValidationRunId = @ValidationRunId;

        SELECT
            ValidationResultId,
            TableMappingId,
            CheckType,
            SourceValue,
            TargetValue,
            DifferenceCount,
            Status,
            Message,
            ExecutionTime
        FROM Execution.ValidationResult
        WHERE ValidationRunId = @ValidationRunId
        ORDER BY ValidationResultId;

    END TRY
    BEGIN CATCH

        UPDATE Execution.ValidationRun
        SET EndTime = SYSDATETIME(),
            Status = 'ERROR',
            Notes = CONCAT(COALESCE(Notes + N' | ', N''), ERROR_MESSAGE())
        WHERE ValidationRunId = @ValidationRunId;

        THROW;
    END CATCH
END
GO

/* ============================================================================
   REPORTING VIEWS
   Provides run-level validation statistics.
   Provides detailed validation results.
============================================================================ */
CREATE OR ALTER VIEW Execution.vw_ValidationSummary
AS
SELECT
    VR.ValidationRunId,
    VR.RunName,
    VR.StartTime,
    VR.EndTime,
    VR.Status AS RunStatus,
    COUNT(R.ValidationResultId) AS TotalChecks,
    SUM(CASE WHEN R.Status = 'PASS' THEN 1 ELSE 0 END) AS PassedChecks,
    SUM(CASE WHEN R.Status = 'FAIL' THEN 1 ELSE 0 END) AS FailedChecks,
    SUM(CASE WHEN R.Status = 'ERROR' THEN 1 ELSE 0 END) AS ErrorChecks
FROM Execution.ValidationRun VR
LEFT JOIN Execution.ValidationResult R
    ON R.ValidationRunId = VR.ValidationRunId
GROUP BY
    VR.ValidationRunId,
    VR.RunName,
    VR.StartTime,
    VR.EndTime,
    VR.Status;
GO

CREATE OR ALTER VIEW Execution.vw_ValidationResults
AS
SELECT
    R.ValidationRunId,
    TM.MappingName,
    TM.SourceDatabase,
    TM.SourceSchema,
    TM.SourceTable,
    TM.TargetDatabase,
    TM.TargetSchema,
    TM.TargetTable,
    R.CheckType,
    R.SourceValue,
    R.TargetValue,
    R.DifferenceCount,
    R.Status,
    R.Message,
    R.ExecutionTime
FROM Execution.ValidationResult R
INNER JOIN Configuration.TableMapping TM
    ON TM.TableMappingId = R.TableMappingId;
GO

/* ============================================================================
   EXAMPLE Configuration
===============================================================================

-- Table Mapping

INSERT INTO Configuration.TableMapping
(
    MappingName,
    SourceDatabase,
    SourceSchema,
    SourceTable,
    TargetDatabase,
    TargetSchema,
    TargetTable,
    BusinessKey
)
VALUES
(
    N'Customer Migration',
    N'LegacyDB',
    N'dbo',
    N'Customer',
    N'TargetDB',
    N'dbo',
    N'Customer',
    N'CustomerId'
);

-- Column Mapping

INSERT INTO Configuration.ColumnMapping
(
    TableMappingId,
    SourceColumn,
    TargetColumn,
    CompareData,
    IsBusinessKey
)
VALUES
(1, 'CustomerId', 'CustomerId', 1, 1),
(1, 'FirstName',  'FirstName',  1, 0),
(1, 'LastName',   'LastName',   1, 0),
(1, 'Email',      'Email',      1, 0),
(1, 'Status',     'Status',     1, 0),
(1, 'Balance',    'Balance',    1, 0);

CustomerId  → CustomerId
FirstName   → FirstName
LastName    → LastName
Email       → Email
Status      → Status
Balance     → Balance

-- Validation Rules

INSERT INTO Configuration.ValidationRule
(
    TableMappingId,
    RuleType,
    RuleName
)
VALUES
(1, 'COUNT',      'Record Count Reconciliation'),
(1, 'MISSING',    'Missing Records'),
(1, 'DUPLICATE',  'Duplicate Records'),
(1, 'DATA',       'Column Data Reconciliation'),
(1, 'NULL',       'Mandatory Field Validation');

COUNT
MISSING
UNEXPECTED
DUPLICATE
DATA
NULL

/* ============================================================================
   EXAMPLE EXECUTION
===============================================================================

-- Ensure LegacyDB and TargetDB exist and the sample Customer table mapping
-- matches the actual schemas before executing.

EXEC Execution.RunValidation
    @RunName = N'Customer Migration Validation',
    @Notes = N'Validation of migrated customer records.';

The framework records the execution and returns validation results.

Example:

ValidationRunId | CheckType | SourceValue | TargetValue | Status
-----------------------------------------------------------------
1001            | COUNT     | 125000      | 125000      | PASS
1001            | DUPLICATE | 0           | 0           | PASS
1001            | NULL      | 0           | 3           | FAIL

For field-level reconciliation:

CustomerId | Field       | SourceValue | TargetValue | Status
--------------------------------------------------------------
10001      | Name        | Mohamed     | Mohamed     | PASS
10001      | Status      | Active      | Active      | PASS
10001      | Balance     | 1500.00     | 1500.00     | PASS
10002      | Name        | Ahmed       | Ahmad       | FAIL

-- Summary:

SELECT *
FROM Execution.vw_ValidationSummary
ORDER BY ValidationRunId DESC;

-- Detailed results:

SELECT *
FROM Execution.vw_ValidationResults
ORDER BY ValidationRunId DESC, ExecutionTime DESC;

/* ============================================================================
   Future Enhancements
===============================================================================

The sample framework intentionally provides a foundation that can be extended.

Recommended next enhancements:

- [ ] Implement source-to-target missing-record reconciliation.
- [ ] Implement target-only/unexpected-record reconciliation.
- [ ] Implement generic field-level comparison using `ColumnMapping`.
- [ ] Support composite business keys.
- [ ] Add configurable comparison tolerances for numeric values.
- [ ] Support transformation rules.
- [ ] Add checksum/hash-based reconciliation for large datasets.
- [ ] Add referential-integrity validation.
- [ ] Add configurable business-rule validation.
- [ ] Add record-level exception persistence for all failed checks.
- [ ] Add retry/error-handling policies.
- [ ] Add CI/CD integration.
- [ ] Add automated HTML/CSV reporting.
- [ ] Add performance optimizations for large migration datasets.