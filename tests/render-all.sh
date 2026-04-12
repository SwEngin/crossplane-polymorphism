#!/usr/bin/env bash
# Render all test compositions locally using crossplane render.
# Requires: crossplane CLI and Docker Desktop running.
#
# Usage: ./tests/render-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FUNCTIONS="$SCRIPT_DIR/functions.yaml"
PASS=0
FAIL=0

render() {
  local label="$1" xr="$2" composition="$3"
  printf "%-40s " "$label"
  if output=$(crossplane render "$xr" "$composition" "$FUNCTIONS" 2>&1); then
    echo "✓ PASS"
    PASS=$((PASS + 1))
    if [[ "${VERBOSE:-}" == "1" ]]; then
      echo "$output"
      echo "---"
    fi
  else
    echo "✗ FAIL"
    FAIL=$((FAIL + 1))
    echo "$output" >&2
  fi
}

echo "=== Crossplane Render Tests ==="
echo ""

render "Azure + S3Proxy" \
  "$SCRIPT_DIR/xr-azure-s3proxy.yaml" \
  "$ROOT_DIR/package/apis/compositions/azure/composition.yaml"

render "Azure + native blob" \
  "$SCRIPT_DIR/xr-azure-native.yaml" \
  "$ROOT_DIR/package/apis/compositions/azure/composition.yaml"

render "Azure + new RG" \
  "$SCRIPT_DIR/xr-azure-newrg.yaml" \
  "$ROOT_DIR/package/apis/compositions/azure/composition.yaml"

render "Ceph" \
  "$SCRIPT_DIR/xr-ceph.yaml" \
  "$ROOT_DIR/package/apis/compositions/ceph/composition.yaml"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
