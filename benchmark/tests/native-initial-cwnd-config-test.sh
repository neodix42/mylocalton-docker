#!/usr/bin/env bash
set -Eeuo pipefail
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
sed -e "s|/usr/local/bin/native-load-generator|$scratch/generator|g" \
    -e "s|/usr/local/lib/native-load-generator/payment-lanes.sh|$repo_dir/native-load-generator/payment-lanes.sh|g" \
    "$repo_dir/native-load-generator/entrypoint.sh" >"$scratch/entrypoint.sh"
cat >"$scratch/generator" <<'GENERATOR'
#!/bin/sh
set -eu
if [ "${1:-}" = --help ]; then cat "$TEST_HELP"; else printf '%s\n' "$@" >"$TEST_ARGS"; fi
GENERATOR
chmod +x "$scratch/generator"
printf '{}\n' >"$scratch/config.json"
printf 'fixture only\n' >"$scratch/source-0.pk"
cat >"$scratch/base-help" <<'HELP'
--submit-batch-size
--submit-source-run-size
--submit-coalesce-ms
--submit-max-queries-per-client
--canonical-poll-seconds
--canonical-query-timeout
--adaptive-initial-rtt-seconds
--adaptive-max-cwnd
--retry-horizon-seconds
--canonical-state-lag-retry-backoff-ms
--canonical-state-lag-retry-max-backoff-ms
HELP
cp "$scratch/base-help" "$scratch/new-help"
printf '%s\n' '--adaptive-initial-cwnd VALUE' >>"$scratch/new-help"
cp "$scratch/base-help" "$scratch/wrong-help"
printf '%s\n' '--adaptive-initial-cwnd-other' >>"$scratch/wrong-help"
cp "$scratch/base-help" "$scratch/actual-help"
# Exact td::OptionParser syntax captured from the real generator image.
printf '%s\n' '  --adaptive-initial-cwnd<arg>   Global initial adaptive admission window' >>"$scratch/actual-help"
cp "$scratch/base-help" "$scratch/wrong-arg-help"
printf '%s\n' '  --adaptive-initial-cwnd-other<arg>  Different option' >>"$scratch/wrong-arg-help"
cp "$scratch/base-help" "$scratch/wrong-tail-help"
printf '%s\n' '  --adaptive-initial-cwnd<arg>-other  Different option' >>"$scratch/wrong-tail-help"

run_case() {
  local expected=$1 help=$2 status=0
  shift 2
  rm -f "$scratch/args"
  env -i PATH="$PATH" NATIVE_LOAD_GLOBAL_CONFIG="$scratch/config.json" \
    NATIVE_LOAD_WALLET_DIR="$scratch" TEST_HELP="$scratch/$help" TEST_ARGS="$scratch/args" \
    "$@" sh "$scratch/entrypoint.sh" >"$scratch/out" 2>"$scratch/err" || status=$?
  if [[ $status != "$expected" ]]; then cat "$scratch/err" >&2; exit 1; fi
  if [[ $expected == 0 ]]; then [[ -s $scratch/args ]]; else [[ ! -e $scratch/args ]]; fi
}
# The optional flag must never break historical prebuilt images at default zero.
run_case 0 base-help
! grep -qx -- --adaptive-initial-cwnd "$scratch/args"
run_case 0 base-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=0
! grep -qx -- --adaptive-initial-cwnd "$scratch/args"
run_case 0 new-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768
[[ $(grep -cx -- --adaptive-initial-cwnd "$scratch/args") == 1 ]]
awk 'previous == "--adaptive-initial-cwnd" && $0 == "32768" {found=1} {previous=$0} END {exit !found}' "$scratch/args"
run_case 0 actual-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768
[[ $(grep -cx -- --adaptive-initial-cwnd "$scratch/args") == 1 ]]
awk 'previous == "--adaptive-initial-cwnd" && $0 == "32768" {found=1} {previous=$0} END {exit !found}' "$scratch/args"
run_case 2 wrong-arg-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768
run_case 2 wrong-tail-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768
run_case 2 base-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768
run_case 2 wrong-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=32768
for value in -1 1.5 NaN garbage 4294967296 99999999999999999999999999; do
  run_case 2 new-help NATIVE_LOAD_ADAPTIVE_INITIAL_CWND="$value"
done
grep -Fqx '      - NATIVE_LOAD_ADAPTIVE_INITIAL_CWND=${NATIVE_LOAD_ADAPTIVE_INITIAL_CWND:-0}' "$repo_dir/docker-compose.yaml"
printf 'initial cwnd entrypoint configuration tests passed\n'
