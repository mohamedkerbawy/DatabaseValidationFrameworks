# General Database Testing Framework for T-SQL (Microsoft SQL Server)

A reusable database QA framework for Microsoft SQL Server, written for **T-SQL**. It covers schema discovery, data quality, referential integrity, business rules, reconciliation, security, transaction behavior, and performance.

> **Target:** Microsoft SQL Server 2016+ (most examples work on earlier versions; adjust features to your version)  
> **Language:** T-SQL  
> **Scope:** A framework template. Replace illustrative table and column names with your own schema.

## 1. Objectives

Use this framework to:

- Detect missing, duplicate, or invalid data.
- Validate primary keys, foreign keys, unique constraints, and check constraints.
- Verify cross-table business rules and aggregate calculations.
- Reconcile source and target data after ETL or migration.
- Test transaction behavior and access permissions.
- Inspect query plans and establish repeatable performance baselines.
- Report tests as `PASS`, `FAIL`, `WARN`, or `ERROR`.

## 2. Suggested project layout

```text
database-testing/
├── README.md
├── 00_environment_discovery.sql
├── 01_test_framework.sql
├── 02_schema_constraints.sql
├── 03_data_quality.sql
├── 04_referential_integrity.sql
├── 05_business_rules.sql
├── 06_reconciliation.sql
├── 07_security_checks.sql
├── 08_performance_checks.sql
└── reports/
    └── test-run-template.csv
```

## 3. Environment discovery

```sql
-- 00_environment_discovery.sql
SELECT
    @@SERVERNAME AS server_name,
    DB_NAME() AS database_name,
    SUSER_SNAME() AS login_name,
    USER_NAME() AS database_user,
    @@VERSION AS sql_server_version;

-- List user tables and their schemas.
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    t.create_date,
    t.modify_date
FROM sys.tables AS t
JOIN sys.schemas AS s
  ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name;

-- Inspect columns in the current database.
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable
FROM sys.tables AS t
JOIN sys.schemas AS s
  ON s.schema_id = t.schema_id
JOIN sys.columns AS c
  ON c.object_id = t.object_id
JOIN sys.types AS ty
  ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.column_id;
```

## 4. Test design principles

Each test should have:

| Attribute | Meaning |
|---|---|
| Test ID | Stable identifier, e.g. `DQ-001` |
| Test name | Human-readable assertion |
| Category | Quality, integrity, business rule, etc. |
| Severity | Blocking, warning, or informational |
| Violation query | Returns rows that break the rule |
| Expected result | Usually zero violating rows |
| Owner | Responsible team |
| Frequency | Per deployment, nightly, weekly, or on demand |

Prefer a **violation query** pattern: the query returns unexpected rows, and the test passes when the violation count is zero. Keep diagnostic queries separate from blocking assertions.

## 5. Reusable T-SQL test runner

This lightweight stored procedure records results in a table and can be called by test scripts. Create it in a dedicated QA database or a controlled schema in the target database.

```sql
-- 01_test_framework.sql
IF OBJECT_ID(N'dbo.DatabaseTestResults', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DatabaseTestResults
    (
        result_id       bigint IDENTITY(1,1) PRIMARY KEY,
        run_id          uniqueidentifier NOT NULL,
        test_id         nvarchar(100) NOT NULL,
        test_name       nvarchar(256) NOT NULL,
        category        nvarchar(100) NOT NULL,
        status          varchar(10) NOT NULL,
        violation_count bigint NULL,
        started_at      datetime2(3) NOT NULL,
        finished_at     datetime2(3) NOT NULL,
        duration_ms     bigint NOT NULL,
        details         nvarchar(2000) NULL,
        CONSTRAINT CK_DatabaseTestResults_Status
          CHECK (status IN ('PASS', 'FAIL', 'WARN', 'ERROR'))
    );
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_ReportDatabaseTest
    @RunId           uniqueidentifier,
    @TestId          nvarchar(100),
    @TestName        nvarchar(256),
    @Category        nvarchar(100),
    @ViolationCount  bigint,
    @StartedAt       datetime2(3),
    @Details         nvarchar(2000) = NULL,
    @Severity        varchar(10) = 'BLOCKING'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FinishedAt datetime2(3) = SYSUTCDATETIME();
    DECLARE @DurationMs bigint =
        DATEDIFF_BIG(MILLISECOND, @StartedAt, @FinishedAt);
    DECLARE @Status varchar(10);

    SET @Status =
        CASE
          WHEN ISNULL(@ViolationCount, 0) = 0 THEN 'PASS'
          WHEN @Severity = 'WARNING' THEN 'WARN'
          ELSE 'FAIL'
        END;

    INSERT dbo.DatabaseTestResults
    (
        run_id, test_id, test_name, category, status,
        violation_count, started_at, finished_at, duration_ms, details
    )
    VALUES
    (
        @RunId, @TestId, @TestName, @Category, @Status,
        @ViolationCount, @StartedAt, @FinishedAt, @DurationMs, @Details
    );

    SELECT
        @Status AS test_status,
        @TestId AS test_id,
        @TestName AS test_name,
        @ViolationCount AS violation_count,
        @DurationMs AS duration_ms,
        @Details AS details;
END;
GO
```

**Compatibility note:** `CREATE OR ALTER PROCEDURE` is supported in SQL Server 2016 SP1 and later. For older versions, use `CREATE PROCEDURE` or the appropriate drop-and-create deployment pattern.

### Example: run a test

Assume a table named `dbo.Customers` with `CustomerId`, `Email`, and `CreatedAt`.

```sql
DECLARE @RunId uniqueidentifier = NEWID();
DECLARE @StartedAt datetime2(3) = SYSUTCDATETIME();
DECLARE @ViolationCount bigint;

SELECT @ViolationCount = COUNT_BIG(*)
FROM dbo.Customers
WHERE CustomerId IS NULL
   OR Email IS NULL
   OR CreatedAt IS NULL;

EXEC dbo.usp_ReportDatabaseTest
    @RunId = @RunId,
    @TestId = N'DQ-001',
    @TestName = N'Required customer fields are populated',
    @Category = N'Data Quality',
    @ViolationCount = @ViolationCount,
    @StartedAt = @StartedAt,
    @Details = N'Expected zero rows with missing required fields.';
```

The procedure writes one result record and returns a status row. It does not automatically stop a deployment; configure the pipeline to fail when blocking tests have `FAIL` or `ERROR` results.

## 6. Data-quality tests

For these examples, substitute your real schema and business rules.

### Test 1 — Required fields

```sql
SELECT *
FROM dbo.Customers
WHERE CustomerId IS NULL
   OR Email IS NULL
   OR CreatedAt IS NULL;
```

### Test 2 — Duplicate business keys

```sql
SELECT
    Email,
    COUNT_BIG(*) AS DuplicateCount
FROM dbo.Customers
WHERE Email IS NOT NULL
GROUP BY Email
HAVING COUNT_BIG(*) > 1;
```

For case-insensitive matching, use the appropriate collation or a normalized expression. Be aware that collation settings can change equality behavior.

### Test 3 — Invalid domain values

```sql
SELECT *
FROM dbo.Orders
WHERE Status IS NULL
   OR Status NOT IN ('NEW', 'APPROVED', 'CANCELLED', 'COMPLETED');
```

### Test 4 — Numeric range violations

```sql
SELECT *
FROM dbo.OrderItems
WHERE Quantity <= 0
   OR UnitPrice < 0;
```

Confirm whether zero-priced promotional items are allowed.

### Test 5 — Invalid date ranges

```sql
SELECT *
FROM dbo.Contracts
WHERE StartDate IS NOT NULL
  AND EndDate IS NOT NULL
  AND StartDate > EndDate;
```

## 7. Referential-integrity tests

### Test 6 — Orphan order items

```sql
SELECT oi.*
FROM dbo.OrderItems AS oi
LEFT JOIN dbo.Orders AS o
  ON o.OrderId = oi.OrderId
WHERE o.OrderId IS NULL;
```

### Test 7 — Orders without a customer

```sql
SELECT o.*
FROM dbo.Orders AS o
LEFT JOIN dbo.Customers AS c
  ON c.CustomerId = o.CustomerId
WHERE c.CustomerId IS NULL;
```

If `CustomerId` is optional, decide whether NULL foreign keys are permitted and handle them explicitly.

### Test 8 — Inspect foreign-key state

```sql
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    fk.name AS foreign_key_name,
    fk.is_disabled,
    fk.is_not_trusted
FROM sys.foreign_keys AS fk
JOIN sys.tables AS t
  ON t.object_id = fk.parent_object_id
JOIN sys.schemas AS s
  ON s.schema_id = t.schema_id
ORDER BY s.name, t.name, fk.name;
```

A disabled or untrusted foreign key may not provide the expected protection. Review results before changing constraints.

## 8. Business rules and reconciliation

### Test 9 — Recalculate order totals

```sql
SELECT
    o.OrderId,
    o.TotalAmount AS StoredTotal,
    SUM(oi.Quantity * oi.UnitPrice) AS CalculatedTotal
FROM dbo.Orders AS o
JOIN dbo.OrderItems AS oi
  ON oi.OrderId = o.OrderId
GROUP BY o.OrderId, o.TotalAmount
HAVING ABS(
    o.TotalAmount - SUM(oi.Quantity * oi.UnitPrice)
) > 0.01;
```

This inner join checks orders with at least one item. Use a `LEFT JOIN` if zero-item orders must also be checked. Include taxes, discounts, shipping, currency, and rounding rules where appropriate.

### Test 10 — Duplicate external payment identifiers

```sql
SELECT
    ExternalTransactionId,
    COUNT_BIG(*) AS DuplicateCount
FROM dbo.Payments
WHERE ExternalTransactionId IS NOT NULL
GROUP BY ExternalTransactionId
HAVING COUNT_BIG(*) > 1;
```

### Test 11 — Reconcile successful payments against paid orders

```sql
WITH PaymentTotals AS
(
    SELECT OrderId, SUM(Amount) AS PaidAmount
    FROM dbo.Payments
    WHERE PaymentStatus = 'SUCCESS'
    GROUP BY OrderId
)
SELECT
    o.OrderId,
    o.TotalAmount,
    COALESCE(p.PaidAmount, CONVERT(decimal(19,4), 0)) AS PaidAmount
FROM dbo.Orders AS o
LEFT JOIN PaymentTotals AS p
  ON p.OrderId = o.OrderId
WHERE o.OrderStatus = 'PAID'
  AND ABS(
      o.TotalAmount -
      COALESCE(p.PaidAmount, CONVERT(decimal(19,4), 0))
  ) > 0.01;
```

This example assumes a single currency and no outstanding refunds or partial-payment rules.

### Test 12 — Source-to-target reconciliation

```sql
SELECT
    s.RecordId,
    s.Status AS SourceStatus,
    t.Status AS TargetStatus
FROM dbo.SourceTable AS s
LEFT JOIN dbo.TargetTable AS t
  ON t.RecordId = s.RecordId
WHERE t.RecordId IS NULL
   OR s.Status <> t.Status
   OR (s.Status IS NULL AND t.Status IS NOT NULL)
   OR (s.Status IS NOT NULL AND t.Status IS NULL);
```

Add comparisons for all critical columns. For large datasets, consider partitioned key comparisons and checksums as an initial screen, followed by row-level comparisons for mismatches.

## 9. Analytical tests

### Test 13 — Department-level aggregation

```sql
SELECT
    DepartmentId,
    COUNT_BIG(*) AS EmployeeCount,
    AVG(CAST(Salary AS decimal(19,4))) AS AverageSalary
FROM dbo.Employees
GROUP BY DepartmentId;
```

Compare the results to an independently calculated expected result or a trusted reporting output.

### Test 14 — Rank within groups

```sql
SELECT
    EmployeeId,
    DepartmentId,
    Salary,
    DENSE_RANK() OVER
    (
        PARTITION BY DepartmentId
        ORDER BY Salary DESC
    ) AS SalaryRank
FROM dbo.Employees;
```

### Test 15 — Statistical outliers

```sql
WITH TransactionStats AS
(
    SELECT
        AVG(CAST(Amount AS float)) AS MeanAmount,
        STDEV(CAST(Amount AS float)) AS StandardDeviation
    FROM dbo.Transactions
)
SELECT t.*
FROM dbo.Transactions AS t
CROSS JOIN TransactionStats AS s
WHERE s.StandardDeviation IS NOT NULL
  AND CAST(t.Amount AS float) >
      s.MeanAmount + 3 * s.StandardDeviation;
```

Treat outliers as review candidates rather than confirmed defects. `STDEV` returns sample standard deviation; use the appropriate function and statistical model for your requirements.

## 10. Security checks

Run security checks only with authorization and a least-privilege test account.

```sql
-- Current execution context
SELECT
    SUSER_SNAME() AS login_name,
    USER_NAME() AS database_user,
    DB_NAME() AS database_name;

-- Database-level permissions visible to the current principal
SELECT
    class_desc,
    permission_name,
    state_desc,
    OBJECT_NAME(major_id) AS object_name,
    USER_NAME(grantee_principal_id) AS grantee
FROM sys.database_permissions
WHERE grantee_principal_id IN
(
    DATABASE_PRINCIPAL_ID(USER_NAME()),
    DATABASE_PRINCIPAL_ID('public')
)
ORDER BY class_desc, permission_name;
```

Effective permissions may also be inherited through roles and server-level grants. Use `HAS_PERMS_BY_NAME` to check specific permissions and review role membership through the relevant catalog views. Do not run destructive permission tests against production.

## 11. Transaction and concurrency testing

Perform these tests in an isolated QA database with controlled fixture rows.

- **Rollback:** Make a test change, roll back, and verify it is absent.
- **Commit:** Commit a fixture change and verify it from another transaction.
- **Isolation:** Use two sessions to verify expected behavior under the configured isolation level.
- **Lost updates:** Update the same record from two sessions and confirm conflict detection or the intended resolution.
- **Deadlocks:** Test known lock-order scenarios in a controlled environment and verify retry handling.
- **Idempotency:** Repeat a supported operation and verify it does not produce duplicate effects.

Example rollback pattern (replace the table and columns; use only a disposable fixture):

```sql
BEGIN TRANSACTION;

-- Example only: replace with a known test fixture operation.
-- UPDATE dbo.TestFixture
-- SET TestValue = 'temporary'
-- WHERE TestId = 1001;

ROLLBACK TRANSACTION;
```

Do not use a generic transaction test against live business records.

## 12. Performance checks

### 12.1 Capture an estimated execution plan

In SQL Server Management Studio (SSMS), enable **Display Estimated Execution Plan** (Ctrl+L) or use:

```sql
SET SHOWPLAN_XML ON;
GO

SELECT
    DepartmentId,
    COUNT_BIG(*) AS EmployeeCount,
    AVG(CAST(Salary AS decimal(19,4))) AS AverageSalary
FROM dbo.Employees
GROUP BY DepartmentId;
GO

SET SHOWPLAN_XML OFF;
GO
```

When `SHOWPLAN_XML` is ON, SQL Server returns the estimated plan rather than executing the query. Run the `SET` statements in the same session and ensure it is turned OFF afterward.

### 12.2 Capture actual runtime metrics

For a controlled test, use:

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT
    DepartmentId,
    COUNT_BIG(*) AS EmployeeCount,
    AVG(CAST(Salary AS decimal(19,4))) AS AverageSalary
FROM dbo.Employees
GROUP BY DepartmentId;

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
```

Use actual execution plans and Query Store where appropriate. Record data volume, parameter values, warm/cold cache assumptions, duration, logical reads, and blocking. Avoid clearing production caches for benchmarks.

## 13. Query test results

### Run summary

```sql
DECLARE @RunId uniqueidentifier = NEWID();

-- Use the same @RunId when reporting all tests in one run.
SELECT @RunId AS ExampleRunId;

-- Review recent results:
SELECT TOP (200)
    run_id,
    test_id,
    test_name,
    category,
    status,
    violation_count,
    started_at,
    finished_at,
    duration_ms,
    details
FROM dbo.DatabaseTestResults
ORDER BY result_id DESC;
```

In a real suite, store the generated `RunId` in the orchestration script and pass it to every test. The sample above only demonstrates how to inspect recent results.

### Suggested status meanings

- `PASS` — no unexpected rows found.
- `FAIL` — a blocking assertion failed.
- `WARN` — result requires review or depends on a configurable rule.
- `ERROR` — test could not execute.

## 14. CI/CD operating model

1. Provision or reset an isolated database or schema.
2. Apply migrations and seed known fixtures.
3. Verify SQL Server version, schema, and test-account permissions.
4. Run blocking data-quality and integrity tests.
5. Run business-rule and reconciliation tests.
6. Run performance checks against representative data.
7. Publish test results and execution logs.
8. Fail the deployment gate for blocking `FAIL` or `ERROR` results.
9. Clean up the isolated environment.

Keep credentials out of source control and logs. Run destructive tests only against disposable environments.

## 15. Implementation checklist

- [ ] Identify SQL Server version and database compatibility level.
- [ ] Document schema owners and required permissions.
- [ ] Define test IDs, severity, and expected outcomes.
- [ ] Use isolated fixtures for tests requiring known data.
- [ ] Separate blocking assertions from diagnostic checks.
- [ ] Persist run IDs, status, failure counts, and duration.
- [ ] Execute the suite after each schema migration.
- [ ] Establish performance baselines before defining thresholds.
- [ ] Review test changes alongside schema and application changes.

## Final recommendation

Keep the **test intent** consistent across database platforms, but implement each runner using the target platform's language and metadata tools. This version is tailored to Microsoft SQL Server and T-SQL; it uses SQL Server catalog views, `datetime2`, `SYSUTCDATETIME()`, `COUNT_BIG`, `GO`, stored procedures, and SQL Server execution-plan tooling.
