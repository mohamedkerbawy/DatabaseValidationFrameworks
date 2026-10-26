/*
===============================================================================
               SQL query patterns for data validation
                      Author: Mohamed Kerbawy
===============================================================================*/

/* ============================================================================
   Detecting Complex Duplicates (Beyond Simple Group By)

   When validating data, we often need to see the complete row structure 
   of duplicate entries, not just the counts. Window functions identify 
   exact duplicates while retaining individual row data.
============================================================================ */

WITH DuplicateCheck AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY unique_key_column_1, unique_key_column_2 
               ORDER BY created_at DESC
           ) as row_num
    FROM target_table
)
SELECT * 
FROM DuplicateCheck 
WHERE row_num > 1;

/* ============================================================================
   Chronological & Overlapping Time Validations

  For tables tracking effective dates, subscriptions, or transactional logs, 
  dates must never overlap or break sequential logic.
============================================================================ */

WITH ChronoCheck AS (
    SELECT id, 
           start_date, 
           end_date,
           LEAD(start_date) OVER (PARTITION BY entity_id ORDER BY start_date) AS next_start_date
    FROM subscription_table
)
SELECT * 
FROM ChronoCheck 
WHERE start_date > end_date 
   OR next_start_date < end_date;

/* ============================================================================
   Conditional Aggregation for Null & Range Violations

  Instead of running individual audits, we can run a bulk profile query 
  on a table to flag missing or out-of-bounds metrics in a single pass
============================================================================ */

SELECT 
    COUNT(*) AS total_rows,
    COUNT(CASE WHEN user_email IS NULL THEN 1 END) AS null_emails,
    COUNT(CASE WHEN age < 0 OR age > 120 THEN 1 END) AS invalid_age_range,
    COUNT(CASE WHEN status NOT IN ('Active', 'Pending', 'Archived') THEN 1 END) AS invalid_statuses
FROM user_registry;

/* ============================================================================
  Reconciling Source vs. Target Systems (Data Migration Auditing)

  When data is moved or transformed between environments, 
  using a FULL OUTER JOIN or EXCEPT sets up a quick reconciliation checkpoint
============================================================================ */

(
    SELECT customer_id, account_balance FROM staging_table
    EXCEPT
    SELECT customer_id, account_balance FROM production_table
)
UNION ALL
(
    SELECT customer_id, account_balance FROM production_table
    EXCEPT
    SELECT customer_id, account_balance FROM staging_table
);

/* ============================================================================
  Identifying Orphan Records (Referential Integrity Check)

  This query flags records in a child table that point 
  to a non-existent parent ID, breaking foreign key constraints.

  Even if database constraints exist, bulk migrations or legacy pipelines 
  can occasionally bypass them, leading to orphan records.
============================================================================ */

SELECT child.id, child.parent_id 
FROM child_table child
LEFT JOIN parent_table parent 
  ON child.parent_id = parent.id
WHERE parent.id IS NULL 
  AND child.parent_id IS NOT NULL;
