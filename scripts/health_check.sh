#!/bin/bash
#
# health_check.sh
# 
# Endpoint health monitoring script for HIE integration platforms.
# Part of the HIE Integration Framework.
#
# Author: Abdul Razack Razack Jawahar
# License: CC BY 4.0
#
# Usage: ./health_check.sh [config_file]
# Cron:  */1 * * * * /opt/hie/scripts/health_check.sh >> /var/log/hie/health.log 2>&1
#

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG_FILE="${1:-/etc/hie/health_check.conf}"
LOG_FILE="/var/log/hie/health_check.log"
STATE_DIR="/var/lib/hie/health"
ALERT_SCRIPT="/opt/hie/scripts/send_alert.sh"

# Default settings (override in config file)
CONNECT_TIMEOUT=5
READ_TIMEOUT=3
CONSECUTIVE_FAILURES_THRESHOLD=3
CHECK_INTERVAL=60

# Endpoints to check (override in config file)
declare -A ENDPOINTS=(
    ["activemq_primary"]="tcp:activemq-primary.hie.local:61616"
    ["activemq_secondary"]="tcp:activemq-secondary.hie.local:61616"
    ["database_primary"]="tcp:db-primary.hie.local:5432"
    ["database_secondary"]="tcp:db-secondary.hie.local:5432"
    ["gateway_http"]="http:gateway.hie.local:8080/health"
    ["fhir_server"]="http:fhir.hie.local:8080/fhir/metadata"
)

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

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
# HEALTH CHECK FUNCTIONS
# =============================================================================

# Check TCP connectivity
check_tcp() {
    local host="$1"
    local port="$2"
    
    if timeout "$CONNECT_TIMEOUT" bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check HTTP endpoint
check_http() {
    local url="$1"
    local response_code
    
    response_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$READ_TIMEOUT" \
        "$url" 2>/dev/null || echo "000")
    
    if [[ "$response_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        log_warn "HTTP check failed: $url returned $response_code"
        return 1
    fi
}

# Check HTTPS endpoint with certificate validation
check_https() {
    local url="$1"
    local response_code
    
    response_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$READ_TIMEOUT" \
        --cacert /etc/hie/certs/ca-bundle.crt \
        "$url" 2>/dev/null || echo "000")
    
    if [[ "$response_code" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    else
        log_warn "HTTPS check failed: $url returned $response_code"
        return 1
    fi
}

# Main check dispatcher
perform_check() {
    local endpoint_spec="$1"
    local protocol="${endpoint_spec%%:*}"
    local address="${endpoint_spec#*:}"
    
    case "$protocol" in
        tcp)
            local host="${address%%:*}"
            local port="${address##*:}"
            check_tcp "$host" "$port"
            ;;
        http)
            check_http "http://$address"
            ;;
        https)
            check_https "https://$address"
            ;;
        *)
            log_error "Unknown protocol: $protocol"
            return 1
            ;;
    esac
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

get_failure_count() {
    local endpoint_name="$1"
    local state_file="$STATE_DIR/${endpoint_name}.failures"
    
    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "0"
    fi
}

increment_failure_count() {
    local endpoint_name="$1"
    local state_file="$STATE_DIR/${endpoint_name}.failures"
    local current_count
    
    current_count=$(get_failure_count "$endpoint_name")
    echo $((current_count + 1)) > "$state_file"
    echo $((current_count + 1))
}

reset_failure_count() {
    local endpoint_name="$1"
    local state_file="$STATE_DIR/${endpoint_name}.failures"
    
    echo "0" > "$state_file"
}

was_previously_down() {
    local endpoint_name="$1"
    local state_file="$STATE_DIR/${endpoint_name}.down"
    
    [[ -f "$state_file" ]]
}

mark_as_down() {
    local endpoint_name="$1"
    local state_file="$STATE_DIR/${endpoint_name}.down"
    
    date '+%Y-%m-%d %H:%M:%S' > "$state_file"
}

mark_as_up() {
    local endpoint_name="$1"
    local state_file="$STATE_DIR/${endpoint_name}.down"
    
    rm -f "$state_file"
}

# =============================================================================
# ALERTING
# =============================================================================

send_alert() {
    local severity="$1"
    local endpoint_name="$2"
    local message="$3"
    
    log_warn "ALERT [$severity]: $endpoint_name - $message"
    
    # Call external alert script if available
    if [[ -x "$ALERT_SCRIPT" ]]; then
        "$ALERT_SCRIPT" "$severity" "$endpoint_name" "$message" &
    fi
    
    # Also write to a dedicated alerts file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$severity] $endpoint_name: $message" \
        >> "$STATE_DIR/alerts.log"
}

# =============================================================================
# MAIN HEALTH CHECK LOOP
# =============================================================================

check_all_endpoints() {
    local overall_status=0
    
    for endpoint_name in "${!ENDPOINTS[@]}"; do
        local endpoint_spec="${ENDPOINTS[$endpoint_name]}"
        
        if perform_check "$endpoint_spec"; then
            # Check passed
            local previous_failures
            previous_failures=$(get_failure_count "$endpoint_name")
            
            if was_previously_down "$endpoint_name"; then
                # Endpoint recovered
                log_info "RECOVERED: $endpoint_name is back up"
                send_alert "INFO" "$endpoint_name" "Endpoint recovered"
                mark_as_up "$endpoint_name"
            fi
            
            reset_failure_count "$endpoint_name"
            log_info "OK: $endpoint_name"
            
        else
            # Check failed
            local failure_count
            failure_count=$(increment_failure_count "$endpoint_name")
            
            log_warn "FAIL: $endpoint_name (consecutive failures: $failure_count)"
            
            if [[ $failure_count -ge $CONSECUTIVE_FAILURES_THRESHOLD ]]; then
                if ! was_previously_down "$endpoint_name"; then
                    # New outage detected
                    log_error "OUTAGE: $endpoint_name is DOWN after $failure_count consecutive failures"
                    send_alert "CRITICAL" "$endpoint_name" "Endpoint DOWN after $failure_count failures"
                    mark_as_down "$endpoint_name"
                fi
                overall_status=1
            fi
        fi
    done
    
    return $overall_status
}

# =============================================================================
# METRICS OUTPUT (Prometheus format)
# =============================================================================

output_metrics() {
    local metrics_file="$STATE_DIR/metrics.prom"
    
    {
        echo "# HELP hie_endpoint_up Endpoint health status (1=up, 0=down)"
        echo "# TYPE hie_endpoint_up gauge"
        
        for endpoint_name in "${!ENDPOINTS[@]}"; do
            local status=1
            if was_previously_down "$endpoint_name"; then
                status=0
            fi
            echo "hie_endpoint_up{endpoint=\"$endpoint_name\"} $status"
        done
        
        echo ""
        echo "# HELP hie_endpoint_consecutive_failures Number of consecutive check failures"
        echo "# TYPE hie_endpoint_consecutive_failures gauge"
        
        for endpoint_name in "${!ENDPOINTS[@]}"; do
            local failures
            failures=$(get_failure_count "$endpoint_name")
            echo "hie_endpoint_consecutive_failures{endpoint=\"$endpoint_name\"} $failures"
        done
        
        echo ""
        echo "# HELP hie_health_check_timestamp_seconds Last health check timestamp"
        echo "# TYPE hie_health_check_timestamp_seconds gauge"
        echo "hie_health_check_timestamp_seconds $(date +%s)"
        
    } > "$metrics_file.tmp"
    
    mv "$metrics_file.tmp" "$metrics_file"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_info "Starting health check for ${#ENDPOINTS[@]} endpoints"
    
    if check_all_endpoints; then
        log_info "All endpoints healthy"
    else
        log_error "One or more endpoints unhealthy"
    fi
    
    output_metrics
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
