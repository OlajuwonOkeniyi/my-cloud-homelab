#!/usr/bin/env bash
# ==============================================================================
# health_check.sh - Lightweight uptime monitor for the homelab app
#
# Pings the Flask app's /health endpoint and logs the result to a CSV file.
# Designed to run every 5 minutes via cron (see /etc/cron.d/homelab-health).
#
# Output: /opt/homelab/logs/uptime.csv
#   Format: timestamp,status_code,response_time_ms,healthy
#
# On failure, also writes to syslog (which CloudWatch Agent ships to AWS),
# so you'll see UNHEALTHY entries in CloudWatch Logs even if the CSV is lost.
#
# Note: set -e is intentionally NOT used here - we want the script to continue
# logging even if curl fails (that's the whole point of a health check).
# ==============================================================================
set -uo pipefail

LOG_DIR="/opt/homelab/logs"
LOG_FILE="$LOG_DIR/uptime.csv"
ENDPOINT="http://127.0.0.1:5000/health"
TIMEOUT=5  # seconds - if the app can't respond in 5s, something is wrong

# --- Initialize CSV with header if this is the first run ---
if [[ ! -f "$LOG_FILE" ]]; then
    mkdir -p "$LOG_DIR"
    echo "timestamp,status_code,response_time_ms,healthy" > "$LOG_FILE"
fi

# --- Probe the health endpoint ---
# Capture the HTTP status code; discard the response body. When the connection
# never completes, curl writes 000 for %{http_code} on its own.
#
# There is deliberately no `|| echo "000"` here. curl writes 000 AND exits
# non-zero in that case, so the fallback appended a second 000 to curl's own and
# every failed check recorded the status as 000000 - the one value this file
# exists to capture was the one value it got wrong, and only on the runs that
# mattered. Reproduced against a closed port before and after the change.
start_time=$(date +%s%N)
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$ENDPOINT" 2>/dev/null)
end_time=$(date +%s%N)

# If curl produced nothing at all - killed, or not installed - there is no code
# to record, so supply the same 000 it would have written.
if [[ -z "$http_code" ]]; then
    http_code="000"
fi

# --- Calculate response time ---
# Nanosecond precision from date, converted to milliseconds for readability
elapsed_ms=$(( (end_time - start_time) / 1000000 ))

# --- Evaluate result ---
if [[ "$http_code" == "200" ]]; then
    healthy="true"
else
    healthy="false"
    # Push to syslog so CloudWatch catches it - this is our alerting path
    # for issues that aren't CPU-related (app crash, port conflict, etc.)
    logger -t homelab-health "UNHEALTHY: status=$http_code response_time=${elapsed_ms}ms"
fi

# --- Append to CSV ---
timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "${timestamp},${http_code},${elapsed_ms},${healthy}" >> "$LOG_FILE"

# --- Log rotation ---
# Keep the file from growing forever. At 5-min intervals, 10000 lines ≈ 35 days.
# When we hit the limit, keep the most recent 5000 lines (≈ 17 days of history).
# This is crude but effective - no logrotate dependency needed.
if [[ $(wc -l < "$LOG_FILE") -gt 10000 ]]; then
    tail -n 5000 "$LOG_FILE" > "$LOG_FILE.tmp"
    mv "$LOG_FILE.tmp" "$LOG_FILE"
fi
