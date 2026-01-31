/*
 * schema_partitioning_postgresql.sql
 * 
 * PostgreSQL implementation of schema partitioning for active-active deployment.
 * Part of the HIE Integration Framework.
 * 
 * Author: Abdul Razack Razack Jawahar
 * License: CC BY 4.0
 * 
 * Result: Eliminates primary key contention, enables 3x throughput improvement
 */

-- ============================================================================
-- SCHEMA CREATION
-- Each application node writes to its own schema
-- ============================================================================

-- Create schemas for each node
CREATE SCHEMA IF NOT EXISTS app_node1;
CREATE SCHEMA IF NOT EXISTS app_node2;

-- Grant appropriate permissions
GRANT ALL ON SCHEMA app_node1 TO app_user;
GRANT ALL ON SCHEMA app_node2 TO app_user;

-- ============================================================================
-- AUDIT LOG TABLE - Per Node
-- ============================================================================

-- Node 1 audit log
CREATE TABLE app_node1.audit_log (
    id              BIGSERIAL PRIMARY KEY,
    correlation_id  UUID NOT NULL,
    event_time      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    message_type    VARCHAR(32) NOT NULL,
    message_id      VARCHAR(64),
    patient_id      VARCHAR(64),
    source_system   VARCHAR(128),
    user_id         VARCHAR(64),
    action          VARCHAR(32),
    status          VARCHAR(16) DEFAULT 'PENDING',
    details         JSONB,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Node 2 audit log (identical structure)
CREATE TABLE app_node2.audit_log (
    id              BIGSERIAL PRIMARY KEY,
    correlation_id  UUID NOT NULL,
    event_time      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    message_type    VARCHAR(32) NOT NULL,
    message_id      VARCHAR(64),
    patient_id      VARCHAR(64),
    source_system   VARCHAR(128),
    user_id         VARCHAR(64),
    action          VARCHAR(32),
    status          VARCHAR(16) DEFAULT 'PENDING',
    details         JSONB,
    created_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- INDEXES - Per Node
-- ============================================================================

-- Node 1 indexes
CREATE INDEX idx_node1_audit_correlation ON app_node1.audit_log(correlation_id);
CREATE INDEX idx_node1_audit_event_time ON app_node1.audit_log(event_time);
CREATE INDEX idx_node1_audit_patient ON app_node1.audit_log(patient_id) WHERE patient_id IS NOT NULL;
CREATE INDEX idx_node1_audit_status ON app_node1.audit_log(status, event_time) WHERE status = 'PENDING';

-- Node 2 indexes
CREATE INDEX idx_node2_audit_correlation ON app_node2.audit_log(correlation_id);
CREATE INDEX idx_node2_audit_event_time ON app_node2.audit_log(event_time);
CREATE INDEX idx_node2_audit_patient ON app_node2.audit_log(patient_id) WHERE patient_id IS NOT NULL;
CREATE INDEX idx_node2_audit_status ON app_node2.audit_log(status, event_time) WHERE status = 'PENDING';

-- ============================================================================
-- UNIFIED VIEW - For Reporting and Queries
-- ============================================================================

CREATE OR REPLACE VIEW v_all_audit_logs AS
    SELECT 
        'node1' AS source_node,
        id,
        correlation_id,
        event_time,
        message_type,
        message_id,
        patient_id,
        source_system,
        user_id,
        action,
        status,
        details,
        created_at,
        updated_at
    FROM app_node1.audit_log
    
    UNION ALL
    
    SELECT 
        'node2' AS source_node,
        id,
        correlation_id,
        event_time,
        message_type,
        message_id,
        patient_id,
        source_system,
        user_id,
        action,
        status,
        details,
        created_at,
        updated_at
    FROM app_node2.audit_log;

-- Grant read access to the view
GRANT SELECT ON v_all_audit_logs TO reporting_user;

-- ============================================================================
-- RECONCILIATION QUERY
-- Find orphaned records that need reprocessing
-- ============================================================================

CREATE OR REPLACE VIEW v_orphaned_audit_records AS
    SELECT 
        source_node,
        correlation_id,
        event_time,
        message_type,
        status
    FROM v_all_audit_logs
    WHERE status = 'PENDING'
      AND event_time < (CURRENT_TIMESTAMP - INTERVAL '5 minutes')
      AND event_time > (CURRENT_TIMESTAMP - INTERVAL '24 hours');

-- ============================================================================
-- HELPER FUNCTIONS
-- ============================================================================

-- Function to get audit record by correlation ID across all nodes
CREATE OR REPLACE FUNCTION get_audit_by_correlation(p_correlation_id UUID)
RETURNS SETOF v_all_audit_logs AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM v_all_audit_logs
    WHERE correlation_id = p_correlation_id;
END;
$$ LANGUAGE plpgsql;

-- Function to get patient audit history
CREATE OR REPLACE FUNCTION get_patient_audit_history(
    p_patient_id VARCHAR(64),
    p_start_date TIMESTAMP WITH TIME ZONE DEFAULT NULL,
    p_end_date TIMESTAMP WITH TIME ZONE DEFAULT NULL
)
RETURNS SETOF v_all_audit_logs AS $$
BEGIN
    RETURN QUERY
    SELECT * FROM v_all_audit_logs
    WHERE patient_id = p_patient_id
      AND (p_start_date IS NULL OR event_time >= p_start_date)
      AND (p_end_date IS NULL OR event_time <= p_end_date)
    ORDER BY event_time DESC;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MONITORING QUERIES
-- ============================================================================

-- Current pending count by node
CREATE OR REPLACE VIEW v_audit_pending_by_node AS
    SELECT 
        source_node,
        COUNT(*) AS pending_count,
        MIN(event_time) AS oldest_pending
    FROM v_all_audit_logs
    WHERE status = 'PENDING'
    GROUP BY source_node;

-- Hourly audit statistics
CREATE OR REPLACE VIEW v_audit_hourly_stats AS
    SELECT 
        source_node,
        DATE_TRUNC('hour', event_time) AS hour,
        COUNT(*) AS total_count,
        COUNT(*) FILTER (WHERE status = 'COMPLETE') AS complete_count,
        COUNT(*) FILTER (WHERE status = 'FAILED') AS failed_count,
        COUNT(*) FILTER (WHERE status = 'PENDING') AS pending_count
    FROM v_all_audit_logs
    WHERE event_time > (CURRENT_TIMESTAMP - INTERVAL '24 hours')
    GROUP BY source_node, DATE_TRUNC('hour', event_time)
    ORDER BY hour DESC, source_node;

-- ============================================================================
-- DATA RETENTION / ARCHIVAL
-- ============================================================================

-- Move old records to archive (run in batches)
CREATE OR REPLACE PROCEDURE archive_old_audit_records(
    p_cutoff_date TIMESTAMP WITH TIME ZONE,
    p_batch_size INTEGER DEFAULT 10000
)
LANGUAGE plpgsql AS $$
DECLARE
    v_archived_count INTEGER := 0;
BEGIN
    -- Archive from node1
    WITH moved AS (
        DELETE FROM app_node1.audit_log
        WHERE id IN (
            SELECT id FROM app_node1.audit_log
            WHERE event_time < p_cutoff_date
            LIMIT p_batch_size
        )
        RETURNING *
    )
    INSERT INTO archive.audit_log 
    SELECT 'node1', * FROM moved;
    
    GET DIAGNOSTICS v_archived_count = ROW_COUNT;
    RAISE NOTICE 'Archived % records from node1', v_archived_count;
    
    -- Archive from node2
    WITH moved AS (
        DELETE FROM app_node2.audit_log
        WHERE id IN (
            SELECT id FROM app_node2.audit_log
            WHERE event_time < p_cutoff_date
            LIMIT p_batch_size
        )
        RETURNING *
    )
    INSERT INTO archive.audit_log 
    SELECT 'node2', * FROM moved;
    
    GET DIAGNOSTICS v_archived_count = ROW_COUNT;
    RAISE NOTICE 'Archived % records from node2', v_archived_count;
END;
$$;

-- ============================================================================
-- COMMENTS FOR DOCUMENTATION
-- ============================================================================

COMMENT ON SCHEMA app_node1 IS 'Audit log schema for application node 1';
COMMENT ON SCHEMA app_node2 IS 'Audit log schema for application node 2';
COMMENT ON VIEW v_all_audit_logs IS 'Unified view of audit logs from all nodes';
COMMENT ON VIEW v_orphaned_audit_records IS 'Records pending longer than reconciliation threshold';
