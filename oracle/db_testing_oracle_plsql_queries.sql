-- ============================================================================
-- SQL QUERIES FOR DATABASE TESTING
-- Oracle Database / PL/SQL-compatible script
--
-- Purpose:
--   Data quality, referential integrity, analytics, reconciliation,
--   migration validation, anomaly detection, and performance diagnostics.
--
-- Assumptions:
--   - Run against an Oracle schema containing the sample table/column names
--     used below, or adapt names to your schema.
--   - Queries are provided as standalone SQL statements, with PL/SQL wrappers
--     where useful for assertions.
--   - Some examples require supporting tables such as CUSTOMER_STATUS_HISTORY,
--     LOGIN_EVENTS, ASSIGNMENTS, SOURCE_CUSTOMERS, TARGET_CUSTOMERS, and
--     PRODUCT_PRICE_HISTORY.
--
-- Oracle notes:
--   - Replace PostgreSQL generate_series() with CONNECT BY date/number
--     generators (queries 6 and 12).
--   - Replace IS DISTINCT FROM with explicit NULL-safe comparisons (query 17).
--   - Oracle uses DBMS_XPLAN / SQL Monitor for execution-plan analysis.
--   - DATE arithmetic uses days; SYSTIMESTAMP is used for timestamp windows.
-- ============================================================================

SET SERVEROUTPUT ON;

-- ============================================================================
-- 1. Find duplicate customer email addresses
-- Expected result for a clean dataset: no rows, if email must be unique.
-- ============================================================================
SELECT email, COUNT(*) AS duplicate_count
FROM customers
WHERE email IS NOT NULL
GROUP BY email
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

-- ============================================================================
-- 2. Find orders referencing nonexistent customers
-- ============================================================================
SELECT o.*
FROM orders o
LEFT JOIN customers c
  ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL;

-- ============================================================================
-- 3. Find records missing mandatory fields
-- ============================================================================
SELECT *
FROM customers
WHERE customer_id IS NULL
   OR email IS NULL
   OR created_at IS NULL;

-- ============================================================================
-- 4. Find invalid order amounts or statuses
-- Adjust the allowed status list to match your application.
-- ============================================================================
SELECT *
FROM orders
WHERE total_amount < 0
   OR status NOT IN ('PENDING', 'PAID', 'SHIPPED', 'CANCELLED', 'REFUNDED')
   OR status IS NULL;

-- ============================================================================
-- 5. Compare stored order totals with item-level calculated totals
-- Include tax, shipping, discounts, and other business rules as applicable.
-- ============================================================================
SELECT
    o.order_id,
    o.total_amount AS stored_total,
    NVL(SUM(oi.quantity * oi.unit_price), 0) AS calculated_total
FROM orders o
LEFT JOIN order_items oi
  ON oi.order_id = o.order_id
GROUP BY o.order_id, o.total_amount
HAVING ABS(
    NVL(o.total_amount, 0) - NVL(SUM(oi.quantity * oi.unit_price), 0)
) > 0.01
   OR o.total_amount IS NULL;

-- ============================================================================
-- 6. Find gaps in sequential order IDs
-- Note: ID gaps are not necessarily errors; sequences can skip values.
-- ============================================================================
WITH bounds AS (
    SELECT MIN(order_id) AS min_id, MAX(order_id) AS max_id
    FROM orders
),
all_ids AS (
    SELECT b.min_id + LEVEL - 1 AS candidate_id
    FROM bounds b
    CONNECT BY LEVEL <= NVL(b.max_id - b.min_id + 1, 0)
)
SELECT a.candidate_id AS missing_order_id
FROM all_ids a
LEFT JOIN orders o
  ON o.order_id = a.candidate_id
WHERE o.order_id IS NULL
ORDER BY a.candidate_id;

-- ============================================================================
-- 7. Find potential duplicate payments
-- Refine with provider transaction ID, status, and time-window rules.
-- ============================================================================
SELECT
    order_id,
    amount,
    payment_method,
    COUNT(*) AS transaction_count
FROM payments
GROUP BY order_id, amount, payment_method
HAVING COUNT(*) > 1
ORDER BY transaction_count DESC;

-- ============================================================================
-- 8. Flag customers whose spending is more than three standard deviations
-- above the customer-level mean.
-- ============================================================================
WITH customer_spending AS (
    SELECT customer_id, SUM(total_amount) AS total_spent
    FROM orders
    WHERE status = 'PAID'
    GROUP BY customer_id
),
stats AS (
    SELECT AVG(total_spent) AS avg_spending,
           STDDEV_POP(total_spent) AS std_spending
    FROM customer_spending
)
SELECT
    cs.customer_id,
    cs.total_spent,
    s.avg_spending,
    s.std_spending
FROM customer_spending cs
CROSS JOIN stats s
WHERE s.std_spending IS NOT NULL
  AND cs.total_spent > s.avg_spending + 3 * s.std_spending
ORDER BY cs.total_spent DESC;

-- ============================================================================
-- 9. Rank employees by salary within each department
-- ============================================================================
SELECT
    employee_id,
    department_id,
    salary,
    DENSE_RANK() OVER (
        PARTITION BY department_id
        ORDER BY salary DESC
    ) AS salary_rank
FROM employees
ORDER BY department_id, salary_rank;

-- ============================================================================
-- 10. Calculate a running total of paid sales
-- ============================================================================
SELECT
    order_date,
    order_id,
    total_amount,
    SUM(total_amount) OVER (
        ORDER BY order_date, order_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_sales
FROM orders
WHERE status = 'PAID'
ORDER BY order_date, order_id;

-- ============================================================================
-- 11. Detect customer status changes in a history table
-- Requires CUSTOMER_STATUS_HISTORY(customer_id, status, updated_at).
-- Add a stable unique key to the ORDER BY if timestamps can repeat.
-- ============================================================================
WITH status_history AS (
    SELECT
        customer_id,
        status,
        updated_at,
        LAG(status) OVER (
            PARTITION BY customer_id
            ORDER BY updated_at
        ) AS previous_status
    FROM customer_status_history
)
SELECT *
FROM status_history
WHERE previous_status IS NOT NULL
  AND status <> previous_status;

-- ============================================================================
-- 12. Find dates with no paid orders in January 2026
-- A date without sales may be valid, not necessarily a data defect.
-- ============================================================================
WITH calendar AS (
    SELECT DATE '2026-01-01' + LEVEL - 1 AS report_date
    FROM dual
    CONNECT BY LEVEL <= DATE '2026-02-01' - DATE '2026-01-01'
),
daily_sales AS (
    SELECT TRUNC(order_date) AS report_date,
           SUM(total_amount) AS sales
    FROM orders
    WHERE status = 'PAID'
      AND order_date >= DATE '2026-01-01'
      AND order_date <  DATE '2026-02-01'
    GROUP BY TRUNC(order_date)
)
SELECT c.report_date, NVL(d.sales, 0) AS sales
FROM calendar c
LEFT JOIN daily_sales d
  ON d.report_date = c.report_date
WHERE d.report_date IS NULL
ORDER BY c.report_date;

-- ============================================================================
-- 13. Detect repeated failed login attempts in the last 15 minutes
-- Requires LOGIN_EVENTS(user_id, ip_address, event_type, event_time).
-- ============================================================================
SELECT
    user_id,
    ip_address,
    COUNT(*) AS failed_attempts,
    MIN(event_time) AS first_attempt,
    MAX(event_time) AS last_attempt
FROM login_events
WHERE event_type = 'LOGIN_FAILED'
  AND event_time >= SYSTIMESTAMP - INTERVAL '15' MINUTE
GROUP BY user_id, ip_address
HAVING COUNT(*) >= 5
ORDER BY failed_attempts DESC;

-- ============================================================================
-- 14. Find overlapping assignments for the same employee
-- Assumes end_date is exclusive; adjust if your ranges are inclusive.
-- ============================================================================
SELECT
    a.employee_id,
    a.assignment_id AS assignment_1,
    b.assignment_id AS assignment_2
FROM assignments a
JOIN assignments b
  ON a.employee_id = b.employee_id
 AND a.assignment_id < b.assignment_id
 AND a.start_date < b.end_date
 AND b.start_date < a.end_date;

-- ============================================================================
-- 15. Find products that have never been ordered
-- ============================================================================
SELECT p.product_id, p.product_name
FROM products p
WHERE NOT EXISTS (
    SELECT 1
    FROM order_items oi
    WHERE oi.product_id = p.product_id
);

-- ============================================================================
-- 16. Reconcile paid orders with successful payment totals
-- Include refunds, partial payments, and currencies where relevant.
-- ============================================================================
WITH payment_totals AS (
    SELECT order_id, SUM(amount) AS paid_amount
    FROM payments
    WHERE status = 'SUCCESS'
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.total_amount AS order_total,
    NVL(p.paid_amount, 0) AS paid_total
FROM orders o
LEFT JOIN payment_totals p
  ON p.order_id = o.order_id
WHERE o.status = 'PAID'
  AND (
      ABS(NVL(o.total_amount, 0) - NVL(p.paid_amount, 0)) > 0.01
      OR o.total_amount IS NULL
  );

-- ============================================================================
-- 17. Compare source and target customer data after migration
-- Oracle NULL-safe comparison uses explicit NULL checks.
-- ============================================================================
SELECT
    s.customer_id,
    s.email AS source_email,
    t.email AS target_email,
    s.status AS source_status,
    t.status AS target_status
FROM source_customers s
LEFT JOIN target_customers t
  ON t.customer_id = s.customer_id
WHERE t.customer_id IS NULL
   OR (s.email <> t.email OR (s.email IS NULL AND t.email IS NOT NULL)
                         OR (s.email IS NOT NULL AND t.email IS NULL))
   OR (s.status <> t.status OR (s.status IS NULL AND t.status IS NOT NULL)
                           OR (s.status IS NOT NULL AND t.status IS NULL));

-- ============================================================================
-- 18. Find order items with missing order or product records
-- ============================================================================
SELECT
    oi.order_item_id,
    oi.order_id,
    oi.product_id
FROM order_items oi
LEFT JOIN orders o
  ON o.order_id = oi.order_id
LEFT JOIN products p
  ON p.product_id = oi.product_id
WHERE o.order_id IS NULL
   OR p.product_id IS NULL;

-- ============================================================================
-- 19. Flag product price changes greater than 20%
-- Requires PRODUCT_PRICE_HISTORY(product_id, effective_date, price).
-- Add a unique history ID to ORDER BY if effective dates can repeat.
-- ============================================================================
WITH price_changes AS (
    SELECT
        product_id,
        effective_date,
        price,
        LAG(price) OVER (
            PARTITION BY product_id
            ORDER BY effective_date
        ) AS previous_price
    FROM product_price_history
)
SELECT
    product_id,
    effective_date,
    previous_price,
    price,
    ROUND(
        100 * (price - previous_price) / NULLIF(previous_price, 0),
        2
    ) AS change_percent
FROM price_changes
WHERE previous_price > 0
  AND ABS(price - previous_price) > previous_price * 0.20
ORDER BY ABS(price - previous_price) DESC;

-- ============================================================================
-- 20. Inspect execution plan and runtime statistics
-- EXPLAIN PLAN estimates the plan without executing the query.
-- For runtime statistics, execute the query with gather_plan_statistics,
-- then inspect DBMS_XPLAN.DISPLAY_CURSOR for the current session cursor.
-- ============================================================================
EXPLAIN PLAN FOR
SELECT /*+ gather_plan_statistics */
    customer_id,
    COUNT(*) AS order_count,
    SUM(total_amount) AS total_spent
FROM orders
WHERE status = 'PAID'
  AND order_date >= DATE '2026-01-01'
GROUP BY customer_id;

SELECT *
FROM TABLE(DBMS_XPLAN.DISPLAY(NULL, NULL, 'BASIC +COST +CARDINALITY +PREDICATE'));

-- Optional runtime plan inspection:
-- Run the SELECT below, then execute:
-- SELECT *
-- FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));
SELECT /*+ gather_plan_statistics */
    customer_id,
    COUNT(*) AS order_count,
    SUM(total_amount) AS total_spent
FROM orders
WHERE status = 'PAID'
  AND order_date >= DATE '2026-01-01'
GROUP BY customer_id;

-- ============================================================================
-- OPTIONAL PL/SQL ASSERTION TEMPLATE
-- Use this pattern to convert a query into an automated pass/fail test.
-- Replace the sample query with the count of violating rows.
-- ============================================================================
DECLARE
    l_failure_count NUMBER;
BEGIN
    SELECT COUNT(*)
      INTO l_failure_count
      FROM (
          SELECT email
          FROM customers
          WHERE email IS NOT NULL
          GROUP BY email
          HAVING COUNT(*) > 1
      );

    IF l_failure_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('PASS: No duplicate customer email addresses.');
    ELSE
        DBMS_OUTPUT.PUT_LINE(
            'FAIL: Found ' || l_failure_count ||
            ' duplicated email groups.'
        );
        -- To fail a CI/deployment step, uncomment:
        -- RAISE_APPLICATION_ERROR(-20001, 'Duplicate customer emails found');
    END IF;
END;
/

-- END OF SCRIPT
