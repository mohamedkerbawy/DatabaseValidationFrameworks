# General Database Testing Framework for SQL and PL/SQL Environments

A reusable, vendor-aware framework for testing relational databases. It covers schema discovery, data quality, referential integrity, business rules, reconciliation, transaction behavior, security, and performance.

> **Important terminology:** PL/SQL is Oracle's procedural SQL language. Other database platforms have their own procedural languages (for example, T-SQL for SQL Server). This framework uses broadly portable SQL patterns where possible and identifies Oracle-specific PL/SQL examples separately.

## 1. Goals

Use this framework to:

- Detect data-quality defects before reports or applications consume the data.
- Verify primary keys, foreign keys, required fields, and business constraints.
- Reconcile source and target data after imports or migrations.
- Validate aggregate calculations and cross-table consistency.
- Test transactions, concurrency, permissions, and query performance.
- Produce repeatable, auditable test results suitable for manual QA or CI/CD.

## 2. Framework layout

A suggested repository structure:

```text
database-testing/
├── README.md
├── config/
│   └── test-environment.md
├── sql/
│   ├── 00_environment_discovery.sql
│   ├── 01_schema_constraints.sql
│   ├── 02_data_quality.sql
│   ├── 03_referential_integrity.sql
│   ├── 04_business_rules.sql
│   ├── 05_reconciliation.sql
│   ├── 06_analytics_validation.sql
│   ├── 07_security_checks.sql
│   └── 08_performance_checks.sql
├── oracle/
│   ├── test_framework_package.sql
│   └── run_all_tests.sql
└── reports/
    └── test-run-template.csv
```

The generic SQL sections can be adapted to Oracle, PostgreSQL, SQL Server, MySQL, or another relational database. Metadata catalogs, procedural wrappers, date arithmetic, exception handling, and execution-plan commands are platform-specific.

## 3. Define a test contract

Each test should have:

| Attribute | Description |
|---|---|
| `test_id` | Stable unique identifier |
| `test_name` | Human-readable name |
| `category` | Data quality, integrity, business rule, etc. |
| `severity` | Blocking, warning, or informational |
| `query` | Query that identifies violating rows |
| `expected_result` | Usually zero violating rows |
| `owner` | Team responsible for the rule |
| `run_frequency` | Per deployment, nightly, weekly, or on demand |

Use the rule “**a test query returns violating rows**.” A test passes when the number of unexpected rows is zero. Some tests, such as detecting unusual spending, are diagnostic and require a threshold or human review.

## 4. Environment discovery

### 4.1 Portable checks

Most database systems support basic queries like:

```sql
-- Verify that a query can execute.
SELECT 1 AS connection_test;

-- Example row count. Replace sample_table with a real table.
SELECT COUNT(*) AS row_count
FROM sample_table;
```

`DUAL`, schema metadata views, date literals, and procedural syntax differ between database platforms. For example, Oracle supports `SELECT 1 FROM dual`, while many other systems allow `SELECT 1` directly.

### 4.2 Discover tables and columns

Use the platform's catalog or information schema. The following pattern is common in systems that implement `INFORMATION_SCHEMA`:

```sql
SELECT
    table_schema,
    table_name,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema NOT IN ('information_schema')
ORDER BY table_schema, table_name, ordinal_position;
```

This query is **not universal**: catalog visibility and system schemas vary. Oracle users typically query `USER_TABLES`, `USER_TAB_COLUMNS`, `ALL_TABLES`, and `ALL_TAB_COLUMNS`, depending on privileges and scope.

## 5. Core data-quality tests

For the examples below, assume a generic table named `customers` with columns `customer_id`, `email`, and `created_at`. Replace names with those in your database.

### Test 1 — Required fields are populated

```sql
SELECT *
FROM customers
WHERE customer_id IS NULL
   OR email IS NULL
   OR created_at IS NULL;
```

**Expected:** zero rows, if all three fields are required by the data contract.

### Test 2 — Duplicate business keys

```sql
SELECT email, COUNT(*) AS duplicate_count
FROM customers
WHERE email IS NOT NULL
GROUP BY email
HAVING COUNT(*) > 1;
```

If email uniqueness is case-insensitive, normalize with the platform's equivalent of `UPPER(email)` and define how whitespace should be handled.

### Test 3 — Invalid domain values

```sql
SELECT *
FROM orders
WHERE status IS NULL
   OR status NOT IN ('NEW', 'APPROVED', 'CANCELLED', 'COMPLETED');
```

Adapt allowed values to the application's approved status model.

### Test 4 — Numeric range violations

```sql
SELECT *
FROM order_items
WHERE quantity <= 0
   OR unit_price < 0;
```

Make sure the test reflects actual rules. For example, a zero-price item may be legitimate for a promotion.

### Test 5 — Date ordering

```sql
SELECT *
FROM contracts
WHERE start_date IS NOT NULL
  AND end_date IS NOT NULL
  AND start_date > end_date;
```

This checks an invalid date range without assuming a particular date literal syntax.

## 6. Referential-integrity tests

### Test 6 — Orphan child records

```sql
SELECT child.*
FROM order_items child
LEFT JOIN orders parent
  ON parent.order_id = child.order_id
WHERE parent.order_id IS NULL;
```

**Expected:** zero rows when every order item must reference an existing order.

### Test 7 — Missing parent records across another relationship

```sql
SELECT o.*
FROM orders o
LEFT JOIN customers c
  ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL;
```

A nullable foreign key may be valid. If it is optional, exclude rows where the child foreign-key column is `NULL`.

### Test 8 — Check declared constraints

Inspect the database catalog to verify that expected primary-key, unique, check, and foreign-key constraints exist and are enabled. The exact catalog query is vendor-specific.

Do not rely solely on data scans: a table may currently contain valid data while lacking the constraints that protect future writes.

## 7. Business-rule and consistency tests

### Test 9 — Recalculate order totals

```sql
SELECT
    o.order_id,
    o.total_amount AS stored_total,
    SUM(oi.quantity * oi.unit_price) AS calculated_total
FROM orders o
JOIN order_items oi
  ON oi.order_id = o.order_id
GROUP BY o.order_id, o.total_amount
HAVING ABS(
    o.total_amount - SUM(oi.quantity * oi.unit_price)
) > 0.01;
```

This inner-join version checks orders with at least one item. Use a `LEFT JOIN` and appropriate null handling if zero-item orders must also be validated. Account for discounts, taxes, shipping, currency, and rounding policy.

### Test 10 — Detect duplicate transactions

```sql
SELECT
    external_transaction_id,
    COUNT(*) AS duplicate_count
FROM payments
WHERE external_transaction_id IS NOT NULL
GROUP BY external_transaction_id
HAVING COUNT(*) > 1;
```

Prefer a stable external transaction identifier over matching only amount and timestamp.

### Test 11 — Reconcile payment and order totals

```sql
WITH payment_totals AS (
    SELECT order_id, SUM(amount) AS paid_amount
    FROM payments
    WHERE payment_status = 'SUCCESS'
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.total_amount,
    COALESCE(p.paid_amount, 0) AS paid_amount
FROM orders o
LEFT JOIN payment_totals p
  ON p.order_id = o.order_id
WHERE o.order_status = 'PAID'
  AND ABS(o.total_amount - COALESCE(p.paid_amount, 0)) > 0.01;
```

`COALESCE` is supported by many major SQL platforms. Validate refund, partial-payment, and multi-currency rules before using this as a blocking assertion.

### Test 12 — Source-to-target reconciliation

```sql
SELECT
    s.record_id,
    s.status AS source_status,
    t.status AS target_status
FROM source_table s
LEFT JOIN target_table t
  ON t.record_id = s.record_id
WHERE t.record_id IS NULL
   OR s.status <> t.status
   OR (s.status IS NULL AND t.status IS NOT NULL)
   OR (s.status IS NOT NULL AND t.status IS NULL);
```

Extend comparisons to all business-critical columns. For very large datasets, consider partitioned checksums or key-range comparisons, but do not rely on a checksum alone when exact row-level evidence is required.

## 8. Analytics validation

### Test 13 — Compare an aggregate with a detail-level calculation

```sql
SELECT
    department_id,
    COUNT(*) AS employee_count,
    AVG(salary) AS average_salary
FROM employees
GROUP BY department_id;
```

Compare these results with the application's dashboard or expected baseline. For automated testing, store expected values in a controlled fixture or calculate both sides independently.

### Test 14 — Rank values within groups

```sql
SELECT
    employee_id,
    department_id,
    salary,
    DENSE_RANK() OVER (
        PARTITION BY department_id
        ORDER BY salary DESC
    ) AS salary_rank
FROM employees;
```

Use this to validate ranking logic and tie behavior. Window functions are broadly supported, but exact feature support depends on database version.

### Test 15 — Find unusually high values

```sql
WITH group_stats AS (
    SELECT
        AVG(amount) AS mean_amount,
        STDDEV(amount) AS standard_deviation
    FROM transactions
)
SELECT t.*
FROM transactions t
CROSS JOIN group_stats s
WHERE s.standard_deviation IS NOT NULL
  AND t.amount > s.mean_amount + 3 * s.standard_deviation;
```

The `STDDEV` function name and semantics can vary. Use the vendor equivalent, and treat statistical outliers as candidates for review rather than confirmed defects.

## 9. Security and access checks

Security testing should be performed with authorization and a least-privilege test account.

Recommended checks:

1. Confirm the test account can read required tables but cannot perform prohibited writes.
2. Inspect effective roles and object privileges through the database's catalog views.
3. Verify sensitive columns are not exposed to unauthorized roles.
4. Test application-level row filtering and tenant isolation using approved test identities.
5. Confirm audit logging is enabled for the operations that require it.
6. Verify secrets are not stored in SQL scripts, logs, or test fixtures.

Privilege catalog queries and role inheritance behavior are database-specific. Do not attempt destructive permission tests against production.

## 10. Transaction and concurrency tests

Run these in a dedicated test database using controlled test records.

- **Rollback:** Insert or update a fixture row, roll back, and verify that the change is absent.
- **Commit:** Commit a fixture change and verify it from a new transaction.
- **Isolation:** Use two sessions to test expected behavior under the configured isolation level.
- **Lost updates:** Have two sessions update the same record and verify the application detects or safely resolves conflicts.
- **Deadlocks:** Exercise known lock-order scenarios in a controlled environment and verify the application handles deadlock errors.
- **Idempotency:** Repeat a supported operation and verify it does not create unintended duplicate effects.

Do not run generic transaction examples against real business records. Build isolated fixtures and clean them up safely.

## 11. Performance tests

### 11.1 Establish a baseline

For each critical query, record:

- Execution duration and variability
- Rows returned and rows scanned
- Logical and physical reads, where available
- Execution plan and index usage
- Lock waits, blocking, and timeout frequency
- Data volume and environment details

### 11.2 Use vendor-specific tools

- **Oracle:** `EXPLAIN PLAN`, `DBMS_XPLAN`, SQL Trace, and approved monitoring views.
- **SQL Server:** actual execution plans, Query Store, and Extended Events.
- **PostgreSQL:** `EXPLAIN (ANALYZE, BUFFERS)` with care because `ANALYZE` executes the query.
- **MySQL:** `EXPLAIN ANALYZE` where supported by the server version.

Execution-plan commands differ, and some execute the query. Avoid applying a fixed runtime threshold until you have a stable baseline and representative data volumes.

## 12. Oracle PL/SQL test runner example

The following is an optional Oracle-specific helper. It runs a supplied violation count through a standard reporting procedure. The caller must calculate the count and pass it in; the procedure does not dynamically execute SQL.

```sql
SET SERVEROUTPUT ON;

CREATE OR REPLACE PACKAGE db_test_runner AS
  PROCEDURE begin_suite(p_name IN VARCHAR2);
  PROCEDURE assert_zero(
    p_test_name       IN VARCHAR2,
    p_violation_count IN NUMBER,
    p_details         IN VARCHAR2 DEFAULT NULL
  );
  PROCEDURE finish_suite;
END db_test_runner;
/

CREATE OR REPLACE PACKAGE BODY db_test_runner AS
  g_suite  VARCHAR2(200);
  g_total  PLS_INTEGER := 0;
  g_pass   PLS_INTEGER := 0;
  g_fail   PLS_INTEGER := 0;

  PROCEDURE begin_suite(p_name IN VARCHAR2) IS
  BEGIN
    g_suite := p_name;
    g_total := 0;
    g_pass := 0;
    g_fail := 0;
    DBMS_OUTPUT.PUT_LINE('=== Suite: ' || g_suite || ' ===');
  END begin_suite;

  PROCEDURE assert_zero(
    p_test_name       IN VARCHAR2,
    p_violation_count IN NUMBER,
    p_details         IN VARCHAR2 DEFAULT NULL
  ) IS
  BEGIN
    g_total := g_total + 1;

    IF NVL(p_violation_count, 0) = 0 THEN
      g_pass := g_pass + 1;
      DBMS_OUTPUT.PUT_LINE('[PASS] ' || p_test_name);
    ELSE
      g_fail := g_fail + 1;
      DBMS_OUTPUT.PUT_LINE(
        '[FAIL] ' || p_test_name ||
        ' | violations=' || TO_CHAR(p_violation_count)
      );
    END IF;

    IF p_details IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('       ' || p_details);
    END IF;
  END assert_zero;

  PROCEDURE finish_suite IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE(
      'Total=' || g_total ||
      ', Passed=' || g_pass ||
      ', Failed=' || g_fail
    );
  END finish_suite;
END db_test_runner;
/
```

Example usage:

```sql
DECLARE
  l_count NUMBER;
BEGIN
  db_test_runner.begin_suite('Customer data quality');

  SELECT COUNT(*)
    INTO l_count
    FROM customers
   WHERE customer_id IS NULL;

  db_test_runner.assert_zero(
    'Customer ID is not NULL',
    l_count
  );

  db_test_runner.finish_suite;
END;
/
```

This runner reports through `DBMS_OUTPUT` and keeps totals in package state for the current session. For a durable test history, create a test-results table and insert a row per assertion. For CI/CD gating, add a documented policy for raising an application error when blocking tests fail.

## 13. Recommended results table

A persistent results table can use a structure like this. The DDL below is broadly conventional but data types and identity/sequence syntax may need platform-specific changes.

```sql
CREATE TABLE database_test_results (
    run_id          VARCHAR(64)   NOT NULL,
    test_id         VARCHAR(128)  NOT NULL,
    test_name       VARCHAR(256)  NOT NULL,
    category        VARCHAR(64)   NOT NULL,
    status          VARCHAR(16)   NOT NULL,
    violation_count INTEGER,
    started_at      TIMESTAMP,
    duration_ms     INTEGER,
    details         VARCHAR(2000)
);
```

Recommended statuses:

- `PASS` — assertion met.
- `FAIL` — assertion violated.
- `WARN` — review needed or business rule is configurable.
- `ERROR` — test could not run.

Restrict access to the results table if test details could expose sensitive data.

## 14. CI/CD operating model

A practical pipeline can follow these steps:

1. Provision or reset a disposable database/schema.
2. Apply migrations and seed controlled fixtures.
3. Verify the database version, schema, and required permissions.
4. Run blocking integrity and business-rule tests.
5. Run reconciliation and analytical tests.
6. Run performance checks against a stable, representative dataset.
7. Publish the result report and logs.
8. Block deployment on failed mandatory tests; allow explicitly approved warnings.
9. Clean up the test environment.

Keep production credentials out of CI logs and avoid running destructive tests against production.

## 15. Implementation checklist

- [ ] Document supported database engines and versions.
- [ ] Identify schema owners and test-account privileges.
- [ ] Define business rules and expected outcomes.
- [ ] Use isolated fixtures for tests that need known data.
- [ ] Separate blocking assertions from diagnostics.
- [ ] Capture test IDs, run IDs, durations, and failure counts.
- [ ] Run the suite on every schema migration.
- [ ] Keep vendor-specific SQL in clearly named folders.
- [ ] Establish performance baselines before setting thresholds.
- [ ] Review and version-control test changes alongside schema changes.