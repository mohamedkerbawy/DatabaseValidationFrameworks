/* ============================================================================
   DATABASE VALIDATION FRAMEWORK (Oracle PL/SQL)
   Purpose : Reconcile source vs. target data during an ETL / migration
             process — row counts, checksums, referential integrity, and
             business rules — with every result logged for audit and
             compliance-risk triage.
   Author  : Mohamed Kerbawy
   ============================================================================ */


/* ----------------------------------------------------------------------------
   1. VALIDATION LOG TABLE
   Every check writes a row here. This becomes the audit trail used to
   triage defects by severity/compliance risk instead of a one-off report.
---------------------------------------------------------------------------- */
CREATE TABLE validation_log (
    log_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          VARCHAR2(40)    NOT NULL,           -- groups one migration run
    check_name      VARCHAR2(100)   NOT NULL,           -- e.g. 'ROW_COUNT', 'CHECKSUM'
    source_table    VARCHAR2(128),
    target_table    VARCHAR2(128),
    status          VARCHAR2(10)    NOT NULL,           -- PASS / FAIL / WARN
    severity        VARCHAR2(10)    DEFAULT 'MEDIUM',   -- LOW / MEDIUM / HIGH / CRITICAL
    details         VARCHAR2(4000),
    checked_at      TIMESTAMP       DEFAULT SYSTIMESTAMP
);

CREATE INDEX idx_validation_run ON validation_log(run_id, status);


/* ----------------------------------------------------------------------------
   2. HELPER: write a result row (keeps every check's logging identical)
---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE log_result (
    p_run_id       IN VARCHAR2,
    p_check_name   IN VARCHAR2,
    p_source_table IN VARCHAR2,
    p_target_table IN VARCHAR2,
    p_status       IN VARCHAR2,
    p_severity     IN VARCHAR2,
    p_details      IN VARCHAR2
) IS
BEGIN
    INSERT INTO validation_log
        (run_id, check_name, source_table, target_table, status, severity, details)
    VALUES
        (p_run_id, p_check_name, p_source_table, p_target_table, p_status, p_severity, p_details);
    COMMIT;
END log_result;
/


/* ----------------------------------------------------------------------------
   3. ROW-COUNT RECONCILIATION
   Simplest but highest-signal check: did every row make it across?
---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE validate_row_counts (
    p_run_id       IN VARCHAR2,
    p_source_table IN VARCHAR2,
    p_target_table IN VARCHAR2
) IS
    v_source_count NUMBER;
    v_target_count NUMBER;
BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_source_table INTO v_source_count;
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || p_target_table INTO v_target_count;

    IF v_source_count = v_target_count THEN
        log_result(p_run_id, 'ROW_COUNT', p_source_table, p_target_table, 'PASS', 'LOW',
            'Row counts match: ' || v_source_count);
    ELSE
        log_result(p_run_id, 'ROW_COUNT', p_source_table, p_target_table, 'FAIL', 'CRITICAL',
            'Source=' || v_source_count || ' Target=' || v_target_count ||
            ' Diff=' || (v_source_count - v_target_count));
    END IF;
END validate_row_counts;
/


/* ----------------------------------------------------------------------------
   4. CHECKSUM COMPARISON
   Row counts can match while data is still corrupted in transit — a
   per-row checksum (via STANDARD_HASH) catches silent value drift.
---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE validate_checksums (
    p_run_id        IN VARCHAR2,
    p_source_table  IN VARCHAR2,
    p_target_table  IN VARCHAR2,
    p_key_column    IN VARCHAR2,   -- e.g. 'RECORD_ID'
    p_hash_columns  IN VARCHAR2    -- comma-separated columns to hash, e.g. 'NAME||DOB||STATUS'
) IS
    v_mismatch_count NUMBER;
BEGIN
    EXECUTE IMMEDIATE '
        SELECT COUNT(*) FROM (
            SELECT ' || p_key_column || ',
                   STANDARD_HASH(' || p_hash_columns || ', ''SHA256'') AS row_hash
            FROM ' || p_source_table || '
            MINUS
            SELECT ' || p_key_column || ',
                   STANDARD_HASH(' || p_hash_columns || ', ''SHA256'') AS row_hash
            FROM ' || p_target_table || '
        )'
    INTO v_mismatch_count;

    IF v_mismatch_count = 0 THEN
        log_result(p_run_id, 'CHECKSUM', p_source_table, p_target_table, 'PASS', 'LOW',
            'All row hashes match');
    ELSE
        log_result(p_run_id, 'CHECKSUM', p_source_table, p_target_table, 'FAIL', 'HIGH',
            v_mismatch_count || ' row(s) with mismatched hash — data changed in transit');
    END IF;
END validate_checksums;
/


/* ----------------------------------------------------------------------------
   5. REFERENTIAL INTEGRITY CHECK
   Finds orphaned foreign keys the migration may have introduced —
   e.g. a case record pointing to a citizen ID that no longer exists.
---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE validate_referential_integrity (
    p_run_id        IN VARCHAR2,
    p_child_table   IN VARCHAR2,
    p_fk_column     IN VARCHAR2,
    p_parent_table  IN VARCHAR2,
    p_pk_column     IN VARCHAR2
) IS
    v_orphan_count NUMBER;
BEGIN
    EXECUTE IMMEDIATE '
        SELECT COUNT(*) FROM ' || p_child_table || ' c
        WHERE c.' || p_fk_column || ' IS NOT NULL
        AND NOT EXISTS (
            SELECT 1 FROM ' || p_parent_table || ' p
            WHERE p.' || p_pk_column || ' = c.' || p_fk_column || '
        )'
    INTO v_orphan_count;

    IF v_orphan_count = 0 THEN
        log_result(p_run_id, 'REFERENTIAL_INTEGRITY', p_child_table, p_parent_table, 'PASS', 'LOW',
            'No orphaned foreign keys found');
    ELSE
        log_result(p_run_id, 'REFERENTIAL_INTEGRITY', p_child_table, p_parent_table, 'FAIL', 'CRITICAL',
            v_orphan_count || ' orphaned row(s) in ' || p_child_table ||
            '.' || p_fk_column || ' with no matching ' || p_parent_table || '.' || p_pk_column);
    END IF;
END validate_referential_integrity;
/


/* ----------------------------------------------------------------------------
   6. BUSINESS-RULE VALIDATION
   Example: required fields must not be null, and dates must fall in a
   sane range. Swap in whatever domain rules matter for the migration.
---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE validate_business_rules (
    p_run_id      IN VARCHAR2,
    p_table_name  IN VARCHAR2
) IS
    v_null_required NUMBER;
    v_bad_dates     NUMBER;
BEGIN
    -- Rule 1: required fields must not be null
    EXECUTE IMMEDIATE '
        SELECT COUNT(*) FROM ' || p_table_name || '
        WHERE national_id IS NULL OR full_name IS NULL'
    INTO v_null_required;

    IF v_null_required = 0 THEN
        log_result(p_run_id, 'BUSINESS_RULE_REQUIRED_FIELDS', p_table_name, NULL, 'PASS', 'LOW',
            'No missing required fields');
    ELSE
        log_result(p_run_id, 'BUSINESS_RULE_REQUIRED_FIELDS', p_table_name, NULL, 'FAIL', 'HIGH',
            v_null_required || ' row(s) missing national_id or full_name');
    END IF;

    -- Rule 2: dates must be realistic (not in the future, not before 1900)
    EXECUTE IMMEDIATE '
        SELECT COUNT(*) FROM ' || p_table_name || '
        WHERE record_date > SYSDATE OR record_date < DATE ''1900-01-01'''
    INTO v_bad_dates;

    IF v_bad_dates = 0 THEN
        log_result(p_run_id, 'BUSINESS_RULE_DATE_RANGE', p_table_name, NULL, 'PASS', 'LOW',
            'All dates within valid range');
    ELSE
        log_result(p_run_id, 'BUSINESS_RULE_DATE_RANGE', p_table_name, NULL, 'WARN', 'MEDIUM',
            v_bad_dates || ' row(s) with out-of-range record_date');
    END IF;
END validate_business_rules;
/


/* ----------------------------------------------------------------------------
   7. MASTER RUNNER
   Ties every check together into a single migration validation pass.
   Call this once per table pair being migrated.
---------------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE run_full_validation (
    p_source_table IN VARCHAR2,
    p_target_table IN VARCHAR2,
    p_key_column   IN VARCHAR2,
    p_hash_columns IN VARCHAR2
) IS
    v_run_id VARCHAR2(40) := TO_CHAR(SYSTIMESTAMP, 'YYYYMMDD_HH24MISS');
BEGIN
    validate_row_counts(v_run_id, p_source_table, p_target_table);
    validate_checksums(v_run_id, p_source_table, p_target_table, p_key_column, p_hash_columns);
    validate_referential_integrity(v_run_id, p_target_table, 'PARENT_ID', 'PARENT_TABLE', 'PARENT_ID');
    validate_business_rules(v_run_id, p_target_table);

    DBMS_OUTPUT.PUT_LINE('Validation run ' || v_run_id || ' complete. See validation_log.');
END run_full_validation;
/


/* ----------------------------------------------------------------------------
   8. TRIAGE VIEW
   What a reviewer actually looks at each morning during the migration —
   failures only, worst severity first.
---------------------------------------------------------------------------- */
CREATE OR REPLACE VIEW vw_validation_failures AS
SELECT run_id, check_name, source_table, target_table, severity, details, checked_at
FROM validation_log
WHERE status IN ('FAIL', 'WARN')
ORDER BY
    CASE severity
        WHEN 'CRITICAL' THEN 1
        WHEN 'HIGH'     THEN 2
        WHEN 'MEDIUM'   THEN 3
        ELSE 4
    END,
    checked_at DESC;


/* ----------------------------------------------------------------------------
   9. SAMPLE USAGE
---------------------------------------------------------------------------- */
-- BEGIN
--     run_full_validation(
--         p_source_table => 'LEGACY_CITIZENS',
--         p_target_table => 'ORACLE_CITIZENS',
--         p_key_column   => 'CITIZEN_ID',
--         p_hash_columns => 'FULL_NAME || DOB || STATUS'
--     );
-- END;
-- /
--
-- SELECT * FROM vw_validation_failures;
