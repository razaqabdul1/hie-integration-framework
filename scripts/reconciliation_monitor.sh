#!/bin/bash
#
# reconciliation_monitor.sh
#
# Monitors audit reconciliation status and alerts on orphaned records.
# Part of the HIE Integration Framework.
#
# Author: Abdul Razack Razack Jawahar
# License: CC BY 4.0
#
# Usage: ./reconciliation_monitor.sh [config_file]
# Cron:  */5 * * * * /opt/hie/scripts/reconciliation_monitor.sh
#

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG_FILE="${1:-/etc/hie/reconciliation.conf}"
LOG_FILE="/var/log/hie/reconciliation_monitor.log"
STATE_DIR="/var/lib/hie/reconciliation"

# Database connection (override in config file)
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-hie_audit}"
DB_USER="${DB_USER:-hie_app}"
PGPASSFILE="${PGPASSFILE:-/etc/hie/.pgpass}"

# Thresholds
WARN_PENDING_COUNT=100
CRIT_PENDING_COUNT=500
WARN_PENDING_AGE_MINUTES=10
CRIT_PENDING_AGE_MINUTES=30
WARN_FAILED_COUNT=10
CRIT_FAILED_COUNT=50

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

export PGPASSFILE

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# =============================================================================
# DATABASE QUERIES
# =============================================================================

run_query() {
    local query="$1"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -t -A -c "$query" 2>/dev/null
}

get_pending_count() {
    run_query "
        SELECT COUNT(*) 
        FROM v_all_audit_logs 
        WHERE status = 'PENDING'
    "
}

get_pending_count_by_node() {
    run_query "
        SELECT source_node, COUNT(*) 
        FROM v_all_audit_logs 
        WHERE status = 'PENDING'
        GROUP BY source_node
        ORDER BY source_node
    "
}

get_oldest_pending_age_minutes() {
    run_query "
        SELECT COALESCE(
            EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - MIN(event_time))) / 60,
            0
        )::INTEGER
        FROM v_all_audit_logs 
        WHERE status = 'PENDING'
    "
}

get_failed_count() {
    run_query "
        SELECT COUNT(*) 
        FROM v_all_audit_logs 
        WHERE status = 'FAILED'
          AND event_time > CURRENT_TIMESTAMP - INTERVAL '24 hours'
    "
}

get_hourly_stats() {
    run_query "
        SELECT 
            DATE_TRUNC('hour', event_time) AS hour,
            COUNT(*) FILTER (WHERE status = 'COMPLETE') AS complete,
            COUNT(*) FILTER (WHERE status = 'PENDING') AS pending,
            COUNT(*) FILTER (WHERE status = 'FAILED') AS failed
        FROM v_all_audit_logs
        WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '6 hours'
        GROUP BY DATE_TRUNC('hour', event_time)
        ORDER BY hour DESC
    "
}

get_orphaned_records() {
    run_query "
        SELECT source_node, correlation_id, event_time, message_type
        FROM v_all_audit_logs
        WHERE status = 'PENDING'
          AND event_time < CURRENT_TIMESTAMP - INTERVAL '${CRIT_PENDING_AGE_MINUTES} minutes'
          AND event_time > CURRENT_TIMESTAMP - INTERVAL '24 hours'
        ORDER BY event_time
        LIMIT 20
    "
}

# =============================================================================
# ALERTING
# =============================================================================

send_alert() {
    local severity="$1"
    local metric="$2"
    local message="$3"
    
    log_warn "ALERT [$severity]: $metric - $message"
    
    # Write to alerts file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$severity] $metric: $message" \
        >> "$STATE_DIR/alerts.log"
    
    # Call external alerting if configured
    if [[ -n "${ALERT_WEBHOOK:-}" ]]; then
        curl -s -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"severity\":\"$severity\",\"metric\":\"$metric\",\"message\":\"$message\"}" \
            >/dev/null 2>&1 || true
    fi
}

# =============================================================================
# MONITORING CHECKS
# =============================================================================

check_pending_count() {
    local count
    count=$(get_pending_count)
    
    log_info "Pending audit records: $count"
    
    if [[ $count -ge $CRIT_PENDING_COUNT ]]; then
        send_alert "CRITICAL" "pending_count" "Pending count ($count) exceeds critical threshold ($CRIT_PENDING_COUNT)"
        return 2
    elif [[ $count -ge $WARN_PENDING_COUNT ]]; then
        send_alert "WARNING" "pending_count" "Pending count ($count) exceeds warning threshold ($WARN_PENDING_COUNT)"
        return 1
    fi
    
    return 0
}

check_pending_age() {
    local age_minutes
    age_minutes=$(get_oldest_pending_age_minutes)
    
    log_info "Oldest pending record age: ${age_minutes} minutes"
    
    if [[ $age_minutes -ge $CRIT_PENDING_AGE_MINUTES ]]; then
        send_alert "CRITICAL" "pending_age" "Oldest pending record (${age_minutes}m) exceeds critical threshold (${CRIT_PENDING_AGE_MINUTES}m)"
        return 2
    elif [[ $age_minutes -ge $WARN_PENDING_AGE_MINUTES ]]; then
        send_alert "WARNING" "pending_age" "Oldest pending record (${age_minutes}m) exceeds warning threshold (${WARN_PENDING_AGE_MINUTES}m)"
        return 1
    fi
    
    return 0
}

check_failed_count() {
    local count
    count=$(get_failed_count)
    
    log_info "Failed records (24h): $count"
    
    if [[ $count -ge $CRIT_FAILED_COUNT ]]; then
        send_alert "CRITICAL" "failed_count" "Failed count ($count) exceeds critical threshold ($CRIT_FAILED_COUNT)"
        return 2
    elif [[ $count -ge $WARN_FAILED_COUNT ]]; then
        send_alert "WARNING" "failed_count" "Failed count ($count) exceeds warning threshold ($WARN_FAILED_COUNT)"
        return 1
    fi
    
    return 0
}

# =============================================================================
# METRICS OUTPUT (Prometheus format)
# =============================================================================

output_metrics() {
    local metrics_file="$STATE_DIR/metrics.prom"
    local pending_count failed_count oldest_age
    
    pending_count=$(get_pending_count)
    failed_count=$(get_failed_count)
    oldest_age=$(get_oldest_pending_age_minutes)
    
    {
        echo "# HELP hie_audit_pending_total Number of audit records in PENDING status"
        echo "# TYPE hie_audit_pending_total gauge"
        echo "hie_audit_pending_total $pending_count"
        
        echo ""
        echo "# HELP hie_audit_failed_total Number of FAILED audit records in last 24h"
        echo "# TYPE hie_audit_failed_total gauge"
        echo "hie_audit_failed_total $failed_count"
        
        echo ""
        echo "# HELP hie_audit_oldest_pending_minutes Age of oldest PENDING record in minutes"
        echo "# TYPE hie_audit_oldest_pending_minutes gauge"
        echo "hie_audit_oldest_pending_minutes $oldest_age"
        
        echo ""
        echo "# HELP hie_reconciliation_check_timestamp_seconds Last check timestamp"
        echo "# TYPE hie_reconciliation_check_timestamp_seconds gauge"
        echo "hie_reconciliation_check_timestamp_seconds $(date +%s)"
        
        # Per-node pending counts
        echo ""
        echo "# HELP hie_audit_pending_by_node Pending records per source node"
        echo "# TYPE hie_audit_pending_by_node gauge"
        while IFS='|' read -r node count; do
            [[ -n "$node" ]] && echo "hie_audit_pending_by_node{node=\"$node\"} $count"
        done < <(get_pending_count_by_node)
        
    } > "$metrics_file.tmp"
    
    mv "$metrics_file.tmp" "$metrics_file"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

generate_report() {
    local report_file="$STATE_DIR/daily_report_$(date +%Y%m%d).txt"
    
    {
        echo "========================================"
        echo "HIE Audit Reconciliation Report"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        echo ""
        
        echo "## Summary"
        echo "Pending records: $(get_pending_count)"
        echo "Failed records (24h): $(get_failed_count)"
        echo "Oldest pending: $(get_oldest_pending_age_minutes) minutes"
        echo ""
        
        echo "## Pending by Node"
        get_pending_count_by_node | while IFS='|' read -r node count; do
            [[ -n "$node" ]] && echo "  $node: $count"
        done
        echo ""
        
        echo "## Hourly Statistics (Last 6 Hours)"
        echo "Hour                    | Complete | Pending | Failed"
        echo "------------------------|----------|---------|-------"
        get_hourly_stats | while IFS='|' read -r hour complete pending failed; do
            [[ -n "$hour" ]] && printf "%-24s| %8s | %7s | %6s\n" "$hour" "$complete" "$pending" "$failed"
        done
        echo ""
        
        local orphaned
        orphaned=$(get_orphaned_records)
        if [[ -n "$orphaned" ]]; then
            echo "## Orphaned Records (Pending > ${CRIT_PENDING_AGE_MINUTES}m)"
            echo "$orphaned"
        else
            echo "## Orphaned Records: None"
        fi
        
    } > "$report_file"
    
    log_info "Report generated: $report_file"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local exit_code=0
    
    log_info "Starting reconciliation monitor"
    
    # Run all checks
    check_pending_count || exit_code=$?
    check_pending_age || [[ $? -gt $exit_code ]] && exit_code=$?
    check_failed_count || [[ $? -gt $exit_code ]] && exit_code=$?
    
    # Output metrics for Prometheus
    output_metrics
    
    # Generate daily report at midnight
    if [[ "$(date +%H%M)" == "0000" ]]; then
        generate_report
    fi
    
    case $exit_code in
        0) log_info "All checks passed" ;;
        1) log_warn "Some warnings detected" ;;
        *) log_error "Critical issues detected" ;;
    esac
    
    return $exit_code
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
