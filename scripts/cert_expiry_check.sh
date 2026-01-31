#!/bin/bash
#
# cert_expiry_check.sh
#
# Monitors TLS certificate expiration for HIE endpoints.
# Part of the HIE Integration Framework.
#
# Author: Abdul Razack Razack Jawahar
# License: CC BY 4.0
#
# Usage: ./cert_expiry_check.sh [config_file]
# Cron:  0 6 * * * /opt/hie/scripts/cert_expiry_check.sh
#

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

CONFIG_FILE="${1:-/etc/hie/cert_check.conf}"
LOG_FILE="/var/log/hie/cert_expiry.log"
STATE_DIR="/var/lib/hie/certs"

# Thresholds (days)
WARN_DAYS=30
CRIT_DAYS=14
URGENT_DAYS=7

# Endpoints to check (override in config file)
declare -A TLS_ENDPOINTS=(
    ["activemq_external"]="activemq.hie.example.com:61617"
    ["gateway_https"]="gateway.hie.example.com:443"
    ["fhir_server"]="fhir.hie.example.com:443"
    ["partner_lab"]="lab-partner.example.com:443"
)

# Local certificate files to check
declare -A LOCAL_CERTS=(
    ["broker_cert"]="/etc/hie/certs/broker.crt"
    ["client_cert"]="/etc/hie/certs/client.crt"
    ["ca_cert"]="/etc/hie/certs/ca.crt"
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
# CERTIFICATE CHECKING FUNCTIONS
# =============================================================================

# Get certificate expiry date from remote endpoint
get_remote_cert_expiry() {
    local host_port="$1"
    local host="${host_port%%:*}"
    local port="${host_port##*:}"
    
    echo | openssl s_client -servername "$host" -connect "$host_port" 2>/dev/null | \
        openssl x509 -noout -enddate 2>/dev/null | \
        sed 's/notAfter=//'
}

# Get certificate expiry date from local file
get_local_cert_expiry() {
    local cert_file="$1"
    
    if [[ -f "$cert_file" ]]; then
        openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | \
            sed 's/notAfter=//'
    else
        echo ""
    fi
}

# Calculate days until expiry
days_until_expiry() {
    local expiry_date="$1"
    
    if [[ -z "$expiry_date" ]]; then
        echo "-1"
        return
    fi
    
    local expiry_epoch now_epoch
    expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    
    if [[ $expiry_epoch -eq 0 ]]; then
        echo "-1"
        return
    fi
    
    echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

# Get certificate subject/CN
get_cert_subject() {
    local host_port="$1"
    
    echo | openssl s_client -connect "$host_port" 2>/dev/null | \
        openssl x509 -noout -subject 2>/dev/null | \
        sed 's/subject=//'
}

# =============================================================================
# ALERTING
# =============================================================================

send_alert() {
    local severity="$1"
    local cert_name="$2"
    local days="$3"
    local message="$4"
    
    log_warn "ALERT [$severity]: $cert_name - $message"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$severity] $cert_name (${days}d): $message" \
        >> "$STATE_DIR/alerts.log"
    
    # Call external alerting if configured
    if [[ -n "${ALERT_WEBHOOK:-}" ]]; then
        curl -s -X POST "$ALERT_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"severity\":\"$severity\",\"certificate\":\"$cert_name\",\"days_remaining\":$days,\"message\":\"$message\"}" \
            >/dev/null 2>&1 || true
    fi
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

check_remote_certs() {
    local overall_status=0
    
    log_info "Checking ${#TLS_ENDPOINTS[@]} remote TLS endpoints..."
    
    for cert_name in "${!TLS_ENDPOINTS[@]}"; do
        local host_port="${TLS_ENDPOINTS[$cert_name]}"
        local expiry_date days severity
        
        expiry_date=$(get_remote_cert_expiry "$host_port")
        
        if [[ -z "$expiry_date" ]]; then
            log_error "FAILED: Cannot retrieve certificate from $cert_name ($host_port)"
            send_alert "CRITICAL" "$cert_name" "-1" "Cannot retrieve certificate from $host_port"
            overall_status=2
            continue
        fi
        
        days=$(days_until_expiry "$expiry_date")
        
        if [[ $days -lt 0 ]]; then
            severity="CRITICAL"
            log_error "EXPIRED: $cert_name certificate has expired!"
            send_alert "$severity" "$cert_name" "$days" "Certificate EXPIRED"
            overall_status=2
        elif [[ $days -le $URGENT_DAYS ]]; then
            severity="CRITICAL"
            log_error "URGENT: $cert_name expires in $days days (on $expiry_date)"
            send_alert "$severity" "$cert_name" "$days" "Expires in $days days - URGENT"
            overall_status=2
        elif [[ $days -le $CRIT_DAYS ]]; then
            severity="CRITICAL"
            log_warn "CRITICAL: $cert_name expires in $days days (on $expiry_date)"
            send_alert "$severity" "$cert_name" "$days" "Expires in $days days"
            [[ $overall_status -lt 2 ]] && overall_status=2
        elif [[ $days -le $WARN_DAYS ]]; then
            severity="WARNING"
            log_warn "WARNING: $cert_name expires in $days days (on $expiry_date)"
            send_alert "$severity" "$cert_name" "$days" "Expires in $days days"
            [[ $overall_status -lt 1 ]] && overall_status=1
        else
            log_info "OK: $cert_name expires in $days days (on $expiry_date)"
        fi
        
        # Save state for metrics
        echo "$days" > "$STATE_DIR/${cert_name}.days"
    done
    
    return $overall_status
}

check_local_certs() {
    local overall_status=0
    
    log_info "Checking ${#LOCAL_CERTS[@]} local certificate files..."
    
    for cert_name in "${!LOCAL_CERTS[@]}"; do
        local cert_file="${LOCAL_CERTS[$cert_name]}"
        local expiry_date days severity
        
        if [[ ! -f "$cert_file" ]]; then
            log_warn "MISSING: $cert_name file not found at $cert_file"
            continue
        fi
        
        expiry_date=$(get_local_cert_expiry "$cert_file")
        
        if [[ -z "$expiry_date" ]]; then
            log_error "INVALID: Cannot parse certificate $cert_name at $cert_file"
            continue
        fi
        
        days=$(days_until_expiry "$expiry_date")
        
        if [[ $days -lt 0 ]]; then
            severity="CRITICAL"
            log_error "EXPIRED: $cert_name certificate has expired!"
            send_alert "$severity" "$cert_name" "$days" "Local certificate EXPIRED"
            overall_status=2
        elif [[ $days -le $CRIT_DAYS ]]; then
            severity="CRITICAL"
            log_warn "CRITICAL: $cert_name expires in $days days"
            send_alert "$severity" "$cert_name" "$days" "Local cert expires in $days days"
            [[ $overall_status -lt 2 ]] && overall_status=2
        elif [[ $days -le $WARN_DAYS ]]; then
            severity="WARNING"
            log_warn "WARNING: $cert_name expires in $days days"
            send_alert "$severity" "$cert_name" "$days" "Local cert expires in $days days"
            [[ $overall_status -lt 1 ]] && overall_status=1
        else
            log_info "OK: $cert_name expires in $days days"
        fi
        
        echo "$days" > "$STATE_DIR/${cert_name}.days"
    done
    
    return $overall_status
}

# =============================================================================
# METRICS OUTPUT
# =============================================================================

output_metrics() {
    local metrics_file="$STATE_DIR/metrics.prom"
    
    {
        echo "# HELP hie_cert_expiry_days Days until certificate expiration"
        echo "# TYPE hie_cert_expiry_days gauge"
        
        for cert_name in "${!TLS_ENDPOINTS[@]}"; do
            local days_file="$STATE_DIR/${cert_name}.days"
            if [[ -f "$days_file" ]]; then
                echo "hie_cert_expiry_days{certificate=\"$cert_name\",type=\"remote\"} $(cat "$days_file")"
            fi
        done
        
        for cert_name in "${!LOCAL_CERTS[@]}"; do
            local days_file="$STATE_DIR/${cert_name}.days"
            if [[ -f "$days_file" ]]; then
                echo "hie_cert_expiry_days{certificate=\"$cert_name\",type=\"local\"} $(cat "$days_file")"
            fi
        done
        
        echo ""
        echo "# HELP hie_cert_check_timestamp_seconds Last certificate check timestamp"
        echo "# TYPE hie_cert_check_timestamp_seconds gauge"
        echo "hie_cert_check_timestamp_seconds $(date +%s)"
        
    } > "$metrics_file.tmp"
    
    mv "$metrics_file.tmp" "$metrics_file"
}

# =============================================================================
# REPORT
# =============================================================================

generate_report() {
    echo "========================================"
    echo "TLS Certificate Expiry Report"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""
    echo "Thresholds: Warning=${WARN_DAYS}d, Critical=${CRIT_DAYS}d, Urgent=${URGENT_DAYS}d"
    echo ""
    echo "## Remote Endpoints"
    printf "%-25s | %-35s | %s\n" "Name" "Endpoint" "Days"
    echo "--------------------------|-------------------------------------|------"
    for cert_name in "${!TLS_ENDPOINTS[@]}"; do
        local host_port="${TLS_ENDPOINTS[$cert_name]}"
        local days_file="$STATE_DIR/${cert_name}.days"
        local days="N/A"
        [[ -f "$days_file" ]] && days=$(cat "$days_file")
        printf "%-25s | %-35s | %s\n" "$cert_name" "$host_port" "$days"
    done
    echo ""
    echo "## Local Certificates"
    printf "%-25s | %s\n" "Name" "Days"
    echo "--------------------------|------"
    for cert_name in "${!LOCAL_CERTS[@]}"; do
        local days_file="$STATE_DIR/${cert_name}.days"
        local days="N/A"
        [[ -f "$days_file" ]] && days=$(cat "$days_file")
        printf "%-25s | %s\n" "$cert_name" "$days"
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local exit_code=0
    
    log_info "Starting certificate expiry check"
    
    check_remote_certs || exit_code=$?
    check_local_certs || [[ $? -gt $exit_code ]] && exit_code=$?
    
    output_metrics
    
    if [[ "${GENERATE_REPORT:-false}" == "true" ]] || [[ "${2:-}" == "--report" ]]; then
        generate_report
    fi
    
    case $exit_code in
        0) log_info "All certificates valid" ;;
        1) log_warn "Some certificates expiring soon" ;;
        *) log_error "Certificate issues require attention" ;;
    esac
    
    return $exit_code
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
