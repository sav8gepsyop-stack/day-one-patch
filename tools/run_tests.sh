#!/usr/bin/env bash
# Runs every automated check headless: unit tests, the solo end-to-end run, and a real
# 2-player host + client session over ENet on localhost.
# Usage: tools/run_tests.sh [path-to-godot-4.4-binary]
set -euo pipefail
GODOT="${1:-${GODOT:-godot}}"
cd "$(dirname "$0")/.."
LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

echo "== import"
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

echo "== unit tests"
"$GODOT" --headless --path . --script res://tests/run_tests.gd

echo "== solo end-to-end"
timeout 240 "$GODOT" --headless --path . -- --solo --autotest=solo | tee "$LOG_DIR/solo.log" | grep -E "ok |AUTOTEST|deflected|roast resolved"
grep -q "AUTOTEST PASS" "$LOG_DIR/solo.log"

echo "== co-op host + client (ENet, localhost)"
timeout 240 "$GODOT" --headless --path . -- --host --autotest=host --name=Host > "$LOG_DIR/host.log" 2>&1 &
HOST_PID=$!
sleep 3
timeout 240 "$GODOT" --headless --path . -- --join=127.0.0.1 --autotest=client --name=Client > "$LOG_DIR/client.log" 2>&1 || true
wait "$HOST_PID" || true
grep -hE "ok |AUTOTEST" "$LOG_DIR/host.log" "$LOG_DIR/client.log"
grep -q "AUTOTEST PASS" "$LOG_DIR/host.log"
grep -q "AUTOTEST PASS" "$LOG_DIR/client.log"
if grep -hE "SCRIPT ERROR|^ERROR" "$LOG_DIR"/*.log; then
  echo "Runtime errors found in logs"; exit 1
fi
echo "ALL CHECKS PASSED"
