#!/usr/bin/env bash
# ==============================================================================
# stress_test.sh - CPU stress test to validate CloudWatch alarms
#
# Saturates all CPU cores for a configurable duration to trigger the
# "cpu-high" CloudWatch alarm. Use this to verify the full alerting pipeline:
#   CPU spike → CloudWatch metric → alarm → SNS → email notification
#
# Usage:
#   ./stress_test.sh              # Default: 360 seconds (6 minutes)
#   ./stress_test.sh 120          # Custom: 120 seconds
#
# Why 360 seconds default? The CPU alarm evaluates 5 consecutive 60-second
# periods (= 5 minutes). 6 minutes gives a 1-minute buffer to ensure the
# alarm state actually transitions before the load stops.
#
# How it works: spawns one `yes > /dev/null` process per CPU core. `yes`
# outputs "y" in an infinite loop - simple, effective, and doesn't require
# installing stress-ng or similar tools.
#
# IMPORTANT: This WILL make your instance unresponsive during the test.
# SSH sessions may lag. That's expected - it's a stress test.
#
# COST: the compute module pins cpu_credits = "standard" precisely because of
# this script. T3 instances default to "unlimited", where exhausting your CPU
# credits is billed rather than throttled - the default would turn this test
# into a charge. If you change that setting, do not run this.
# ==============================================================================
set -euo pipefail

DURATION=${1:-360}
NUM_CORES=$(nproc)

echo "=== Homelab Stress Test ==="
echo "Duration: ${DURATION}s"
echo "CPU cores: ${NUM_CORES}"
echo "Starting at: $(date)"
echo ""
echo "This will max out all ${NUM_CORES} cores for ${DURATION} seconds."
echo "Your CloudWatch CPU alarm should fire within ~6 minutes."
echo "Press Ctrl+C to stop early."
echo ""

# --- Spawn CPU-burning workers ---
# One `yes` process per core ensures 100% utilization across all CPUs.
# We track PIDs so we can clean them up when the duration expires.
pids=()

# Clean up on ANY exit, not just the happy path.
#
# This matters more than it looks. A non-interactive shell sets SIGINT and
# SIGQUIT to ignore for commands it starts asynchronously - that is POSIX, not a
# bash quirk - so the `yes` workers below do not die on Ctrl+C. Without this
# trap, the banner's own advice to "press Ctrl+C to stop early" killed the
# script and left every worker running, saturating the CPU with nothing left to
# stop it. Verified by sending SIGINT to the process group: the script exits,
# the workers survive. SIGTERM is not ignored, which is what the trap sends.
cleanup() {
    local pid
    # Guard the expansion: the trap can fire before any worker exists, and an
    # unguarded "${pids[@]}" under `set -u` is an error on older bash.
    if [[ ${#pids[@]} -gt 0 ]]; then
        for pid in "${pids[@]}"; do
            kill -TERM "$pid" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT INT TERM

for ((i = 0; i < NUM_CORES; i++)); do
    yes > /dev/null 2>&1 &
    pids+=("$!")
done

echo "Burning CPU on PIDs: ${pids[*]}"
echo "If this is interrupted, confirm nothing is left: pgrep -x yes"

# --- Wait, then clean up ---
# The EXIT trap does the killing, so there is exactly one cleanup path whether
# this finishes, is interrupted, or fails.
sleep "$DURATION"

echo ""
echo "Stress test complete at: $(date)"
echo "Check CloudWatch - you should see the alarm transition to ALARM state."
echo "SNS notification should arrive in your inbox shortly."
