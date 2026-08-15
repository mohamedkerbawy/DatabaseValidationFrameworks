/* ============================================================================
   DATABASE VALIDATION FRAMEWORK (SQL Server)
   Purpose : Reconcile source vs. target data during an 
             ETL (Extract, Transform, Load) / migration
             process — row counts, checksums, referential integrity, and
             business rules — with every result logged for audit and
             triage.
   Author  : Mohamed Kerbawy
   ============================================================================ */


/* ----------------------------------------------------------------------------
   1. VALIDATION LOG TABLE
   audit trail with RunId and Severity for triage
---------------------------------------------------------------------------- */
CREATE TABLE dbo.ValidationLog (
    LogId          INT IDENTITY(1,1) PRIMARY KEY,
    RunId          VARCHAR(40)     NOT NULL,          -- groups one migration run
    CheckName      VARCHAR(100)    NOT NULL,          -- e.g. 'ROW_COUNT', 'CHECKSUM'
    SourceTable    SYSNAME         NULL,
    TargetTable    SYSNAME         NULL,
    Status         VARCHAR(10)     NOT NULL,          -- PASS / FAIL / WARN
    Severity       VARCHAR(10)     DEFAULT 'MEDIUM',  -- LOW / MEDIUM / HIGH / CRITICAL
    Details        NVARCHAR(4000),
    CheckedAt      DATETIME2       DEFAULT SYSDATETIME()
);
GO

CREATE INDEX IX_ValidationLog_Run ON dbo.ValidationLog (RunId, Status);
GO


/* ----------------------------------------------------------------------------
   2. HELPER: write a result row
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.LogResult
    @RunId        VARCHAR(40),
    @CheckName    VARCHAR(100),
    @SourceTable  SYSNAME = NULL,
    @TargetTable  SYSNAME = NULL,
    @Status       VARCHAR(10),
    @Severity     VARCHAR(10),
    @Details      NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.ValidationLog (RunId, CheckName, SourceTable, TargetTable, Status, Severity, Details)
    VALUES (@RunId, @CheckName, @SourceTable, @TargetTable, @Status, @Severity, @Details);
END
GO


/* ----------------------------------------------------------------------------
   3. ROW-COUNT RECONCILIATION
   source vs. target count reconciliation using dynamic SQL (sp_executesql)
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ValidateRowCounts
    @RunId        VARCHAR(40),
    @SourceTable  SYSNAME,
    @TargetTable  SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @SourceCount INT, @TargetCount INT, @Sql NVARCHAR(MAX);

    SET @Sql = N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@SourceTable);
    EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @SourceCount OUTPUT;

    SET @Sql = N'SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@TargetTable);
    EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @TargetCount OUTPUT;

    IF @SourceCount = @TargetCount
        EXEC dbo.LogResult @RunId, 'ROW_COUNT', @SourceTable, @TargetTable, 'PASS', 'LOW',
            N'Row counts match: ' + CAST(@SourceCount AS NVARCHAR(20));
    ELSE
        EXEC dbo.LogResult @RunId, 'ROW_COUNT', @SourceTable, @TargetTable, 'FAIL', 'CRITICAL',
            N'Source=' + CAST(@SourceCount AS NVARCHAR(20)) +
            N' Target=' + CAST(@TargetCount AS NVARCHAR(20)) +
            N' Diff=' + CAST(@SourceCount - @TargetCount AS NVARCHAR(20));
END
GO


/* ----------------------------------------------------------------------------
   4. CHECKSUM COMPARISON
   Uses HASHBYTES ('SHA2_256', ...) to catch silent value drift that row counts alone miss.
   @HashExpr should be a concatenation of the columns to compare, already
   cast to NVARCHAR where needed, e.g. N'CONCAT(FullName, Dob, Status)'
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ValidateChecksums
    @RunId        VARCHAR(40),
    @SourceTable  SYSNAME,
    @TargetTable  SYSNAME,
    @KeyColumn    SYSNAME,
    @HashExpr     NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Sql NVARCHAR(MAX), @MismatchCount INT;

    SET @Sql = N'
        SELECT @Cnt = COUNT(*) FROM (
            SELECT ' + QUOTENAME(@KeyColumn) + N',
                   HASHBYTES(''SHA2_256'', ' + @HashExpr + N') AS RowHash
            FROM ' + QUOTENAME(@SourceTable) + N'
            EXCEPT
            SELECT ' + QUOTENAME(@KeyColumn) + N',
                   HASHBYTES(''SHA2_256'', ' + @HashExpr + N') AS RowHash
            FROM ' + QUOTENAME(@TargetTable) + N'
        ) AS Diff';

    EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @MismatchCount OUTPUT;

    IF @MismatchCount = 0
        EXEC dbo.LogResult @RunId, 'CHECKSUM', @SourceTable, @TargetTable, 'PASS', 'LOW',
            N'All row hashes match';
    ELSE
        EXEC dbo.LogResult @RunId, 'CHECKSUM', @SourceTable, @TargetTable, 'FAIL', 'HIGH',
            CAST(@MismatchCount AS NVARCHAR(20)) + N' row(s) with mismatched hash — data changed in transit';
END
GO


/* ----------------------------------------------------------------------------
   5. REFERENTIAL INTEGRITY CHECK
   Finds orphaned foreign keys the migration may have introduced.
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ValidateReferentialIntegrity
    @RunId        VARCHAR(40),
    @ChildTable   SYSNAME,
    @FkColumn     SYSNAME,
    @ParentTable  SYSNAME,
    @PkColumn     SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Sql NVARCHAR(MAX), @OrphanCount INT;

    SET @Sql = N'
        SELECT @Cnt = COUNT(*)
        FROM ' + QUOTENAME(@ChildTable) + N' c
        WHERE c.' + QUOTENAME(@FkColumn) + N' IS NOT NULL
        AND NOT EXISTS (
            SELECT 1 FROM ' + QUOTENAME(@ParentTable) + N' p
            WHERE p.' + QUOTENAME(@PkColumn) + N' = c.' + QUOTENAME(@FkColumn) + N'
        )';

    EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @OrphanCount OUTPUT;

    IF @OrphanCount = 0
        EXEC dbo.LogResult @RunId, 'REFERENTIAL_INTEGRITY', @ChildTable, @ParentTable, 'PASS', 'LOW',
            N'No orphaned foreign keys found';
    ELSE
        EXEC dbo.LogResult @RunId, 'REFERENTIAL_INTEGRITY', @ChildTable, @ParentTable, 'FAIL', 'CRITICAL',
            CAST(@OrphanCount AS NVARCHAR(20)) + N' orphaned row(s) in ' + @ChildTable +
            N'.' + @FkColumn + N' with no matching ' + @ParentTable + N'.' + @PkColumn;
END
GO


/* ----------------------------------------------------------------------------
   6. BUSINESS-RULE VALIDATION
   Example: required fields must not be null, and dates must be realistic.
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.ValidateBusinessRules
    @RunId      VARCHAR(40),
    @TableName  SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Sql NVARCHAR(MAX), @NullRequired INT, @BadDates INT;

    -- Rule 1: required fields must not be null
    SET @Sql = N'
        SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@TableName) + N'
        WHERE CustomerId IS NULL OR FullName IS NULL';
    EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @NullRequired OUTPUT;

    IF @NullRequired = 0
        EXEC dbo.LogResult @RunId, 'BUSINESS_RULE_REQUIRED_FIELDS', @TableName, NULL, 'PASS', 'LOW',
            N'No missing required fields';
    ELSE
        EXEC dbo.LogResult @RunId, 'BUSINESS_RULE_REQUIRED_FIELDS', @TableName, NULL, 'FAIL', 'HIGH',
            CAST(@NullRequired AS NVARCHAR(20)) + N' row(s) missing CustomerId or FullName';

    -- Rule 2: dates must be realistic (not in the future, not before 1900)
    SET @Sql = N'
        SELECT @Cnt = COUNT(*) FROM ' + QUOTENAME(@TableName) + N'
        WHERE RecordDate > GETDATE() OR RecordDate < ''1900-01-01''';
    EXEC sp_executesql @Sql, N'@Cnt INT OUTPUT', @Cnt = @BadDates OUTPUT;

    IF @BadDates = 0
        EXEC dbo.LogResult @RunId, 'BUSINESS_RULE_DATE_RANGE', @TableName, NULL, 'PASS', 'LOW',
            N'All dates within valid range';
    ELSE
        EXEC dbo.LogResult @RunId, 'BUSINESS_RULE_DATE_RANGE', @TableName, NULL, 'WARN', 'MEDIUM',
            CAST(@BadDates AS NVARCHAR(20)) + N' row(s) with out-of-range RecordDate';
END
GO


/* ----------------------------------------------------------------------------
   7. MASTER RUNNER
   master procedure tying it together per run
---------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.RunFullValidation
    @SourceTable  SYSNAME,
    @TargetTable  SYSNAME,
    @KeyColumn    SYSNAME,
    @HashExpr     NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @RunId VARCHAR(40) = FORMAT(SYSDATETIME(), 'yyyyMMdd_HHmmss');

    EXEC dbo.ValidateRowCounts @RunId, @SourceTable, @TargetTable;
    EXEC dbo.ValidateChecksums @RunId, @SourceTable, @TargetTable, @KeyColumn, @HashExpr;
    EXEC dbo.ValidateReferentialIntegrity @RunId, @TargetTable, 'ParentId', 'ParentTable', 'ParentId';
    EXEC dbo.ValidateBusinessRules @RunId, @TargetTable;

    PRINT 'Validation run ' + @RunId + ' complete. See dbo.ValidationLog.';
END
GO


/* ----------------------------------------------------------------------------
   8. TRIAGE VIEW
   Failures/warnings only, worst severity first — what a reviewer checks
   each morning during the migration window.
   note: the triage view, with the severity-ordering note since T-SQL views can't ORDER BY directly
---------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_ValidationFailures AS
SELECT
    RunId, CheckName, SourceTable, TargetTable, Severity, Details, CheckedAt
FROM dbo.ValidationLog
WHERE Status IN ('FAIL', 'WARN')
GO
-- Note: ORDER BY isn't valid inside a view without TOP; sort when querying:
-- SELECT * FROM dbo.vw_ValidationFailures
-- ORDER BY CASE Severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END, CheckedAt DESC;


/* ----------------------------------------------------------------------------
   9. SAMPLE USAGE
---------------------------------------------------------------------------- */
-- EXEC dbo.RunFullValidation
--     @SourceTable = 'LegacyOrders',
--     @TargetTable = 'DwOrders',
--     @KeyColumn   = 'OrderId',
--     @HashExpr    = N'CONCAT(CustomerId, OrderDate, TotalAmount, Status)';
--
-- SELECT * FROM dbo.vw_ValidationFailures
-- ORDER BY CASE Severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END, CheckedAt DESC;
