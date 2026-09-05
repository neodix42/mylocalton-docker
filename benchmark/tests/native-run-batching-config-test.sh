#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "required command is not installed: jq" >&2; exit 2; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

for env_file in .env .env.desktop .env.devnet .env.laptop .env.physical; do
  grep -qx 'NATIVE_LOAD_NATIVE_RUN_BATCHING=0' "$repo_dir/$env_file"
done
grep -Fqx '      - NATIVE_LOAD_NATIVE_RUN_BATCHING=${NATIVE_LOAD_NATIVE_RUN_BATCHING:-0}' \
  "$repo_dir/docker-compose.yaml"

# Execute the real entrypoint logic against a fake generator. Only its absolute
# image paths are replaced; no Docker, network, keys, or load are required.
sed -e "s|/usr/local/bin/native-load-generator|$scratch/generator|g" \
    -e "s|/usr/local/lib/native-load-generator/payment-lanes.sh|$repo_dir/native-load-generator/payment-lanes.sh|g" \
    "$repo_dir/native-load-generator/entrypoint.sh" >"$scratch/entrypoint.sh"
cat >"$scratch/generator" <<'GENERATOR'
#!/bin/sh
set -eu
if [ "${1:-}" = --help ]; then
  cat "$TEST_GENERATOR_HELP"
else
  printf '%s\n' "$@" >"$TEST_GENERATOR_ARGS"
fi
GENERATOR
chmod +x "$scratch/generator"
printf '{}\n' >"$scratch/config.json"
printf 'fixture only\n' >"$scratch/source-0.pk"
cat >"$scratch/help-base" <<'HELP'
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
cat "$scratch/help-base" >"$scratch/help-v5"
printf '%s\n' --native-signed-runs --native-signed-run-size >>"$scratch/help-v5"
cat "$scratch/help-v5" >"$scratch/help-batching"
printf '%s\n' --native-run-batching >>"$scratch/help-batching"
cat "$scratch/help-base" >"$scratch/help-batching-without-v5"
printf '%s\n' --native-run-batching >>"$scratch/help-batching-without-v5"
cat "$scratch/help-v5" >"$scratch/help-wrong-flag"
printf '%s\n' --native-run-batching-other >>"$scratch/help-wrong-flag"

run_case() {
  local expected_status=$1 help_file=$2 status=0
  shift 2
  rm -f "$scratch/args"
  env -i PATH="$PATH" \
    NATIVE_LOAD_GLOBAL_CONFIG="$scratch/config.json" \
    NATIVE_LOAD_WALLET_DIR="$scratch" \
    TEST_GENERATOR_HELP="$scratch/$help_file" \
    TEST_GENERATOR_ARGS="$scratch/args" \
    "$@" sh "$scratch/entrypoint.sh" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
  if [[ $status != "$expected_status" ]]; then
    cat "$scratch/stderr" >&2
    echo "entrypoint returned $status, expected $expected_status ($*)" >&2
    exit 1
  fi
  if [[ $expected_status == 0 ]]; then
    [[ -s $scratch/args ]]
  else
    [[ ! -e $scratch/args ]]
  fi
}

# An old scalar or signed-run image must still work when batching is absent/off.
run_case 0 help-base
! grep -qx -- '--native-run-batching' "$scratch/args"
! grep -qx -- '--native-signed-runs' "$scratch/args"
run_case 0 help-v5 NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 NATIVE_LOAD_NATIVE_RUN_BATCHING=0
! grep -qx -- '--native-run-batching' "$scratch/args"
grep -qx -- '--native-signed-runs' "$scratch/args"
run_case 0 help-batching NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1
! grep -qx -- '--native-run-batching' "$scratch/args"

run_case 0 help-batching NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 NATIVE_LOAD_NATIVE_RUN_BATCHING=1 NATIVE_LOAD_SUBMIT_BATCH_SIZE=4
[[ $(grep -cx -- '--native-run-batching' "$scratch/args") == 1 ]]
grep -qx -- '--native-signed-runs' "$scratch/args"
awk 'previous == "--native-signed-run-size" && $0 == "16" {found=1} {previous=$0} END {exit !found}' "$scratch/args"
run_case 2 help-v5 NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 NATIVE_LOAD_NATIVE_RUN_BATCHING=1
grep -Fq 'requires a native-load-generator image with --native-run-batching' "$scratch/stderr"
run_case 2 help-wrong-flag NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 NATIVE_LOAD_NATIVE_RUN_BATCHING=1
run_case 2 help-batching NATIVE_LOAD_NATIVE_TRANSFER_RUNS=0 NATIVE_LOAD_NATIVE_RUN_BATCHING=1
grep -Fq 'requires NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1' "$scratch/stderr"
run_case 2 help-batching-without-v5 NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 NATIVE_LOAD_NATIVE_RUN_BATCHING=1
grep -Fq 'requires a v5-capable native-load-generator image' "$scratch/stderr"
for invalid_mode in 2 true false garbage; do
  run_case 2 help-batching NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 NATIVE_LOAD_NATIVE_RUN_BATCHING="$invalid_mode"
  grep -Fq 'NATIVE_LOAD_NATIVE_RUN_BATCHING must be 0 or 1' "$scratch/stderr"
done

# Requested mode must be proven by both boolean fields. New controls must also
# prove disabled mode; historical controls with neither field stay compatible.
jq -n -e -L "$script_dir/../jq" '
  include "native-benchmark-lib";
  {native_run_batching_requested:true,native_run_batching_enabled:true,
   native_signed_runs_enabled:true} as $on |
  {chain_correctness_valid:true,run_complete:true,
   ingress_capacity_valid:true,ingress_capacity_invalid_reasons:[],
   chain_capacity_valid:false,chain_capacity_invalid_reasons:["existing_capacity_failure"]} as $acceptance |
  native_run_batching_acceptance($on | .native_run_batching_enabled = false; true) as $bad |
  with_native_run_batching_acceptance($acceptance; $bad) as $rejected |
  (native_run_batching_acceptance($on; true) | .valid and .enforced and .telemetry_complete) and
  (native_run_batching_acceptance({}; false) | .valid and (.enforced | not) and (.telemetry_available | not)) and
  (native_run_batching_acceptance({native_run_batching_requested:false,native_run_batching_enabled:false}; false) |
    .valid and .enforced and .telemetry_complete and .requested == false and .enabled == false) and
  ([{}, null, ($on | del(.native_run_batching_requested)),
    ($on | del(.native_run_batching_enabled)), ($on | .native_run_batching_requested = false),
    ($on | .native_run_batching_enabled = false), ($on | .native_run_batching_requested = "true"),
    ($on | .native_run_batching_enabled = "true"), ($on | .native_signed_runs_enabled = false)] |
    all(.[]; native_run_batching_acceptance(.; true) |
      .valid == false and (.invalid_reasons | length > 0))) and
  ([$on, {native_run_batching_requested:false},
    {native_run_batching_requested:false,native_run_batching_enabled:true}] |
    all(.[]; native_run_batching_acceptance(.; false) | .valid == false)) and
  $rejected.ingress_capacity_valid == false and $rejected.chain_capacity_valid == false and
  $rejected.chain_correctness_valid and $rejected.run_complete and
  ($rejected.chain_capacity_invalid_reasons | index("existing_capacity_failure") != null) and
  ($rejected.chain_capacity_invalid_reasons | index("native_run_batching_effective_mode_mismatch") != null) and
  (with_native_run_batching_acceptance($acceptance; native_run_batching_acceptance($on; true)) |
    .chain_capacity_valid == false and .chain_capacity_invalid_reasons == ["existing_capacity_failure"] and
    .ingress_capacity_valid == true)
' >/dev/null
