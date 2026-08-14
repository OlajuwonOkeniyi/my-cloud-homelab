#!/usr/bin/env bash
# ==============================================================================
# stress_test.sh — CPU stress test to validate CloudWatch alarms
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
# outputs "y" in an infinite loop — simple, effective, and doesn't require
# installing stress-ng or similar tools.
#
# IMPORTANT: This WILL make your instance unresponsive during the test.
# SSH sessions may lag. That's expected — it's a stress test.
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
for ((i = 0; i < NUM_CORES; i++)); do
    yes > /dev/null 2>&1 &
    pids+=($!)
done

echo "Burning CPU on PIDs: ${pids[*]}"

# --- Wait, then clean up ---
# sleep for the duration, then kill all the workers.
# `|| true` handles the case where a process already exited (e.g., OOM-killed).
sleep "$DURATION"

for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
done

echo ""
echo "Stress test complete at: $(date)"
echo "Check CloudWatch — you should see the alarm transition to ALARM state."
echo "SNS notification should arrive in your inbox shortly."
