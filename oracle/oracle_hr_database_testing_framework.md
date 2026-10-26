# Oracle Database Testing Framework — HR Schema

A practical, reusable database QA framework for Oracle Database using the familiar sample `HR` schema. It provides a lightweight test runner, reusable assertions, example test cases, and guidance for extending the suite.

> **Target:** Oracle Database 12c+ and SQL Developer / SQLcl  
> **Schema:** Oracle sample `HR` schema  
> **Safety:** The tests below are read-only. They do not insert, update, or delete HR data.

## 1. Objectives

This framework helps validate:

- Required fields and primary-key uniqueness
- Foreign-key integrity
- Business rules, such as valid salary ranges
- Department and employee relationships
- Data quality and duplicate detection
- Aggregate consistency and reporting logic
- Execution-plan and query-performance behavior

The HR sample schema commonly includes `EMPLOYEES`, `DEPARTMENTS`, `JOBS`, `JOB_HISTORY`, `LOCATIONS`, `COUNTRIES`, and `REGIONS`. Exact columns and constraints can vary by installation.

## 2. Suggested project structure

Organize the SQL files like this:

```text
hr-db-testing/
├── README.md
├── 00_environment_checks.sql
├── 01_test_framework.sql
├── 02_hr_data_quality_tests.sql
├── 03_hr_relationship_tests.sql
├── 04_hr_business_rule_tests.sql
├── 05_hr_analytics_tests.sql
└── 06_performance_checks.sql
```

This document includes the example SQL for each part. You can split the sections into separate files when adopting the framework in a project.

## 3. Run the framework

1. Connect to the database using a dedicated test account with read access to the `HR` schema.
2. In Oracle SQL Developer, open a SQL worksheet and enable **Run Script (F5)**.
3. Run the environment checks first.
4. Run the test framework setup, then the test suites.
5. Review the `PASS`, `FAIL`, and `WARN` messages in the Script Output panel.

If your connected account is not `HR`, qualify table names with the schema owner, for example `HR.EMPLOYEES`, or create suitable read-only grants/synonyms.

## 4. Environment checks

```sql
-- 00_environment_checks.sql
SET SERVEROUTPUT ON;

SELECT USER AS connected_user FROM dual;

SELECT owner, table_name
FROM all_tables
WHERE owner = 'HR'
  AND table_name IN (
    'EMPLOYEES', 'DEPARTMENTS', 'JOBS', 'JOB_HISTORY',
    'LOCATIONS', 'COUNTRIES', 'REGIONS'
  )
ORDER BY table_name;

-- Check whether the key tables are visible to the current user.
SELECT
    CASE
      WHEN COUNT(DISTINCT table_name) = 4 THEN 'PASS'
      ELSE 'WARN'
    END AS result,
    COUNT(DISTINCT table_name) AS visible_core_tables
FROM all_tables
WHERE owner = 'HR'
  AND table_name IN ('EMPLOYEES', 'DEPARTMENTS', 'JOBS', 'JOB_HISTORY');
```

The environment check reports visibility, not whether every expected row exists. An empty table can be valid in a customized test environment.

## 5. Minimal test framework

The following package centralizes test reporting. Each test reports a status, a short description, the number of violating rows, and optional details.

```sql
-- 01_test_framework.sql
SET SERVEROUTPUT ON;

CREATE OR REPLACE PACKAGE hr_test_framework AS
  PROCEDURE begin_suite(p_suite_name IN VARCHAR2);
  PROCEDURE report(
    p_test_name IN VARCHAR2,
    p_passed    IN BOOLEAN,
    p_failures  IN NUMBER DEFAULT 0,
    p_details   IN VARCHAR2 DEFAULT NULL
  );
  PROCEDURE finish_suite;
END hr_test_framework;
/

CREATE OR REPLACE PACKAGE BODY hr_test_framework AS
  g_suite_name  VARCHAR2(200);
  g_total       PLS_INTEGER := 0;
  g_passed      PLS_INTEGER := 0;
  g_failed      PLS_INTEGER := 0;
  g_warnings    PLS_INTEGER := 0;

  PROCEDURE begin_suite(p_suite_name IN VARCHAR2) IS
  BEGIN
    g_suite_name := p_suite_name;
    g_total := 0;
    g_passed := 0;
    g_failed := 0;
    g_warnings := 0;

    DBMS_OUTPUT.PUT_LINE('==================================================');
    DBMS_OUTPUT.PUT_LINE('SUITE: ' || g_suite_name);
    DBMS_OUTPUT.PUT_LINE('Started: ' ||
      TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM'));
    DBMS_OUTPUT.PUT_LINE('==================================================');
  END begin_suite;

  PROCEDURE report(
    p_test_name IN VARCHAR2,
    p_passed    IN BOOLEAN,
    p_failures  IN NUMBER DEFAULT 0,
    p_details   IN VARCHAR2 DEFAULT NULL
  ) IS
  BEGIN
    g_total := g_total + 1;

    IF p_passed THEN
      g_passed := g_passed + 1;
      DBMS_OUTPUT.PUT_LINE('[PASS] ' || p_test_name);
    ELSE
      g_failed := g_failed + 1;
      DBMS_OUTPUT.PUT_LINE('[FAIL] ' || p_test_name ||
        ' | violating rows=' || NVL(TO_CHAR(p_failures), 'unknown'));
    END IF;

    IF p_details IS NOT NULL THEN
      DBMS_OUTPUT.PUT_LINE('       ' || p_details);
    END IF;
  END report;

  PROCEDURE finish_suite IS
  BEGIN
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------');
    DBMS_OUTPUT.PUT_LINE('Total: ' || g_total ||
      ' | Passed: ' || g_passed ||
      ' | Failed: ' || g_failed);
    DBMS_OUTPUT.PUT_LINE('Finished: ' ||
      TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM'));
    DBMS_OUTPUT.PUT_LINE('--------------------------------------------------');
  END finish_suite;
END hr_test_framework;
/
```

**Note:** The package reports results to `DBMS_OUTPUT`; it does not persist them. For CI/CD, you can extend it to insert results into a dedicated test-results table or raise an application error when failures occur.

## 6. HR data quality tests

The standard Oracle HR sample schema normally defines `EMPLOYEE_ID` as the employee primary key and includes employee names, email, hire date, job, salary, commission, manager, and department fields.

```sql
-- 02_hr_data_quality_tests.sql
SET SERVEROUTPUT ON;

DECLARE
  l_count NUMBER;
BEGIN
  hr_test_framework.begin_suite('HR data quality');

  -- Test 1: Employee primary-key column must not be NULL.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees
  WHERE employee_id IS NULL;

  hr_test_framework.report(
    'EMPLOYEES.EMPLOYEE_ID is not NULL',
    l_count = 0, l_count
  );

  -- Test 2: Employee IDs must be unique.
  SELECT COUNT(*) INTO l_count
  FROM (
    SELECT employee_id
    FROM hr.employees
    GROUP BY employee_id
    HAVING COUNT(*) > 1
  );

  hr_test_framework.report(
    'EMPLOYEES.EMPLOYEE_ID is unique',
    l_count = 0, l_count,
    'Counts duplicate employee_id groups.'
  );

  -- Test 3: Required employee fields are present.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees
  WHERE first_name IS NULL
     OR last_name IS NULL
     OR email IS NULL
     OR hire_date IS NULL
     OR job_id IS NULL;

  hr_test_framework.report(
    'Required employee fields are populated',
    l_count = 0, l_count
  );

  -- Test 4: Salary is non-negative when supplied.
  -- Whether salary must be non-NULL is a business decision.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees
  WHERE salary < 0;

  hr_test_framework.report(
    'Employee salary is not negative',
    l_count = 0, l_count
  );

  -- Test 5: Email values are unique (case-insensitive policy).
  SELECT COUNT(*) INTO l_count
  FROM (
    SELECT UPPER(email) AS normalized_email
    FROM hr.employees
    WHERE email IS NOT NULL
    GROUP BY UPPER(email)
    HAVING COUNT(*) > 1
  );

  hr_test_framework.report(
    'Employee email is unique ignoring case',
    l_count = 0, l_count,
    'This is a recommended quality rule; confirm your email policy.'
  );

  hr_test_framework.finish_suite;
END;
/
```

## 7. HR relationship and referential-integrity tests

These tests identify records that do not match expected parent rows. They are useful for data migrations, imports, and schemas where constraints may have been disabled.

```sql
-- 03_hr_relationship_tests.sql
SET SERVEROUTPUT ON;

DECLARE
  l_count NUMBER;
BEGIN
  hr_test_framework.begin_suite('HR relationships');

  -- Test 6: Every non-NULL employee department exists.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees e
  WHERE e.department_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM hr.departments d
      WHERE d.department_id = e.department_id
    );

  hr_test_framework.report(
    'Employee department references a valid department',
    l_count = 0, l_count
  );

  -- Test 7: Every employee job exists.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees e
  WHERE NOT EXISTS (
    SELECT 1
    FROM hr.jobs j
    WHERE j.job_id = e.job_id
  );

  hr_test_framework.report(
    'Employee job references a valid job',
    l_count = 0, l_count
  );

  -- Test 8: Every non-NULL manager ID identifies an employee.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees e
  WHERE e.manager_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM hr.employees m
      WHERE m.employee_id = e.manager_id
    );

  hr_test_framework.report(
    'Employee manager references a valid employee',
    l_count = 0, l_count
  );

  -- Test 9: Department location references a valid location.
  SELECT COUNT(*) INTO l_count
  FROM hr.departments d
  WHERE d.location_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM hr.locations l
      WHERE l.location_id = d.location_id
    );

  hr_test_framework.report(
    'Department location references a valid location',
    l_count = 0, l_count
  );

  -- Test 10: Job history employee and job references are valid.
  SELECT COUNT(*) INTO l_count
  FROM hr.job_history h
  WHERE NOT EXISTS (
          SELECT 1 FROM hr.employees e
          WHERE e.employee_id = h.employee_id
        )
     OR NOT EXISTS (
          SELECT 1 FROM hr.jobs j
          WHERE j.job_id = h.job_id
        );

  hr_test_framework.report(
    'Job history employee and job references are valid',
    l_count = 0, l_count
  );

  hr_test_framework.finish_suite;
END;
/
```

## 8. HR business-rule tests

Business rules differ between organizations. Treat these examples as configurable policies, not universal truths.

```sql
-- 04_hr_business_rule_tests.sql
SET SERVEROUTPUT ON;

DECLARE
  l_count NUMBER;
BEGIN
  hr_test_framework.begin_suite('HR business rules');

  -- Test 11: Hire date must not be in the future.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees
  WHERE hire_date > SYSDATE;

  hr_test_framework.report(
    'Hire date is not in the future',
    l_count = 0, l_count
  );

  -- Test 12: Salary falls within the range defined for the employee's job.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees e
  JOIN hr.jobs j ON j.job_id = e.job_id
  WHERE e.salary IS NOT NULL
    AND (e.salary < j.min_salary OR e.salary > j.max_salary);

  hr_test_framework.report(
    'Employee salary is within job salary range',
    l_count = 0, l_count
  );

  -- Test 13: Job history dates are ordered correctly.
  SELECT COUNT(*) INTO l_count
  FROM hr.job_history
  WHERE start_date > end_date;

  hr_test_framework.report(
    'Job history start date is not after end date',
    l_count = 0, l_count
  );

  -- Test 14: Employee commission is between 0 and 1, when present.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees
  WHERE commission_pct < 0
     OR commission_pct > 1;

  hr_test_framework.report(
    'Commission percentage is between 0 and 1',
    l_count = 0, l_count
  );

  -- Test 15: Manager cannot be the employee themself.
  SELECT COUNT(*) INTO l_count
  FROM hr.employees
  WHERE manager_id = employee_id;

  hr_test_framework.report(
    'Employee is not their own manager',
    l_count = 0, l_count
  );

  hr_test_framework.finish_suite;
END;
/
```

## 9. HR analytical and reporting tests

These checks validate aggregate logic and provide useful diagnostics. Some results are informational rather than pass/fail defects.

### Test 16: Employee count by department

```sql
SELECT
    d.department_id,
    d.department_name,
    COUNT(e.employee_id) AS employee_count
FROM hr.departments d
LEFT JOIN hr.employees e
  ON e.department_id = d.department_id
GROUP BY d.department_id, d.department_name
ORDER BY d.department_id;
```

Use this as a baseline report and compare its results with the application or BI dashboard.

### Test 17: Departments with no employees

```sql
SELECT d.department_id, d.department_name
FROM hr.departments d
WHERE NOT EXISTS (
  SELECT 1
  FROM hr.employees e
  WHERE e.department_id = d.department_id
)
ORDER BY d.department_id;
```

An empty department can be legitimate; review results against business expectations.

### Test 18: Employees paid above their department's average

```sql
SELECT
    employee_id,
    first_name,
    last_name,
    department_id,
    salary,
    department_avg_salary
FROM (
    SELECT
        e.employee_id,
        e.first_name,
        e.last_name,
        e.department_id,
        e.salary,
        AVG(e.salary) OVER (
            PARTITION BY e.department_id
        ) AS department_avg_salary
    FROM hr.employees e
)
WHERE salary > department_avg_salary
ORDER BY department_id, salary DESC;
```

This is an analytical example, not necessarily a failure condition.

### Test 19: Detect overlapping job-history periods for an employee

This version treats the end date as inclusive. It flags periods that overlap by at least one calendar day.

```sql
SELECT
    a.employee_id,
    a.start_date AS first_start,
    a.end_date   AS first_end,
    b.start_date AS second_start,
    b.end_date   AS second_end
FROM hr.job_history a
JOIN hr.job_history b
  ON b.employee_id = a.employee_id
 AND (
      a.start_date < b.start_date
      OR (a.start_date = b.start_date AND a.job_id < b.job_id)
 )
 AND a.start_date <= b.end_date
 AND b.start_date <= a.end_date
ORDER BY a.employee_id, a.start_date;
```

If your schema permits two distinct history rows with the same employee, dates, and job, use a unique history-row identifier for deterministic pair selection. Review the HR schema's intended rules before treating overlaps as failures.

## 10. Performance checks

### Test 20: Inspect the execution plan for a representative HR query

```sql
EXPLAIN PLAN FOR
SELECT
    department_id,
    COUNT(*) AS employee_count,
    AVG(salary) AS average_salary
FROM hr.employees
GROUP BY department_id;

SELECT *
FROM TABLE(
    DBMS_XPLAN.DISPLAY(
        NULL,
        NULL,
        'BASIC +COST +CARDINALITY +PREDICATE'
    )
);
```

`EXPLAIN PLAN` shows an estimated plan; it does not execute the query. To inspect actual runtime statistics, execute the query with `/*+ gather_plan_statistics */` and then inspect the appropriate cursor using `DBMS_XPLAN.DISPLAY_CURSOR`. Access to plan views may require additional privileges.

Do not set a fixed performance pass/fail threshold until you have a stable baseline, representative data volume, and controlled test environment.

## 11. Test results and exit criteria

The basic runner writes results to `DBMS_OUTPUT`. For a production-grade framework, persist a record per test with fields such as:

| Field | Purpose |
|---|---|
| `RUN_ID` | Groups tests from one execution |
| `TEST_NAME` | Stable test identifier |
| `STATUS` | `PASS`, `FAIL`, `WARN`, or `ERROR` |
| `FAILURE_COUNT` | Number of violating rows |
| `STARTED_AT` | Test start timestamp |
| `DURATION_MS` | Execution duration |
| `DETAILS` | Additional diagnostic context |

Recommended CI/CD policy:

- **PASS:** No violating rows were found.
- **FAIL:** A defined data-quality or business assertion failed.
- **WARN:** The result needs human review or depends on a configurable business rule.
- **ERROR:** The test could not execute, for example because a table or privilege was missing.

For deployment gates, fail the pipeline only for tests explicitly classified as blocking. Keep diagnostic queries and business-dependent checks separate from mandatory integrity assertions.

## 12. Extending the framework

1. Add a test with a clear name and a query that counts violating rows.
2. Call `hr_test_framework.report(test_name, count = 0, count, details)`.
3. Decide whether the test is blocking or informational.
4. Validate the test against both valid and intentionally invalid data in a disposable test schema.
5. Store results if you need historical trends or CI/CD integration.

### Important implementation notes

- The examples use `HR.EMPLOYEES` and other `HR`-qualified tables. Your account needs permission to read them.
- The standard HR sample data is not identical across all Oracle versions or customized installations.
- The examples are read-only and are intended to be safe for initial validation, but large tables can still create substantial workload.
- A zero-row result means only that the specific query found no violations; it does not prove the entire database is correct.
