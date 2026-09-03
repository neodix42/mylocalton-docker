#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)

# shellcheck source=../../docker/scripts/native-transfer-runs-config.sh
source "$repo_dir/docker/scripts/native-transfer-runs-config.sh"
# shellcheck source=../../docker/scripts/native-payment-lanes-config.sh
source "$repo_dir/docker/scripts/native-payment-lanes-config.sh"

assert_effective_config() {
  local expected_version=$1 expected_capabilities=$2
  resolve_native_payment_lanes_config
  [[ $NATIVE_PAYMENT_LANES_EFFECTIVE_VERSION == "$expected_version" ]]
  [[ $NATIVE_PAYMENT_LANES_EFFECTIVE_CAPABILITIES == "$expected_capabilities" ]]
}

VERSION_CAPABILITIES=14
NATIVE_TRANSFER_RUNS_ENABLED=0
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15
NATIVE_TRANSFER_RUNS_CAPABILITY=1024
NATIVE_PAYMENT_LANES_ENABLED=0
NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16
NATIVE_PAYMENT_LANES_CAPABILITY=2048
NATIVE_PAYMENT_LANE_DEPTH=1
ACTUAL_MIN_SPLIT=0
MIN_SPLIT=0
MAX_SPLIT=4
assert_effective_config 14 0

NATIVE_TRANSFER_RUNS_ENABLED=1
assert_effective_config 15 1024

NATIVE_PAYMENT_LANES_ENABLED=1
ACTUAL_MIN_SPLIT=1
MIN_SPLIT=1
MAX_SPLIT=1
assert_effective_config 16 3072

NATIVE_TRANSFER_RUNS_ENABLED=0
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_TRANSFER_RUNS_ENABLED=1
MAX_SPLIT=2
! resolve_native_payment_lanes_config >/dev/null 2>&1
MAX_SPLIT=1
NATIVE_PAYMENT_LANES_GLOBAL_VERSION=15
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16
NATIVE_PAYMENT_LANES_CAPABILITY=1024
! resolve_native_payment_lanes_config >/dev/null 2>&1
NATIVE_PAYMENT_LANES_CAPABILITY=2048
NATIVE_PAYMENT_LANE_DEPTH=2
! resolve_native_payment_lanes_config >/dev/null 2>&1

for env_file in .env .env.desktop .env.devnet .env.laptop .env.physical; do
  grep -qx 'NATIVE_PAYMENT_LANES_ENABLED=0' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANES_GLOBAL_VERSION=16' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANES_CAPABILITY=2048' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANE_DEPTH=1' "$repo_dir/$env_file"
  grep -qx 'NATIVE_PAYMENT_LANE_WALLET_RETRIES=128' "$repo_dir/$env_file"
  grep -qx 'NATIVE_LOAD_PAYMENT_LANE_DEPTH=0' "$repo_dir/$env_file"
done

grep -Fqx 'VERSION_CAPABILITIES capCreateStats capBounceMsgBody or capReportVersion or capShortDequeue or 64 or 128 or NATIVE_PROTOCOL_CAPABILITIES or config.version!' \
  "$repo_dir/docker/scripts/gen-zerostate.fif"
grep -Fq 'native payment lanes require ACTUAL_MIN_SPLIT, MIN_SPLIT, and MAX_SPLIT' \
  "$repo_dir/docker/scripts/native-payment-lanes-config.sh"
grep -Fq 'native_payment_lanes_wait_for_shards' "$repo_dir/native-load-generator/entrypoint.sh"
grep -Fq -- '--native-payment-lane-depth' "$repo_dir/native-load-generator/entrypoint.sh"
grep -Fq 'native-payment-lanes-config.sh' "$repo_dir/Dockerfile"
grep -Fq 'payment-lanes.sh' "$repo_dir/native-load-generator/Dockerfile"

bash -n "$repo_dir/docker/scripts/start-genesis.sh"
bash -n "$repo_dir/docker/scripts/native-payment-lanes-config.sh"
sh -n "$repo_dir/native-load-generator/entrypoint.sh"
sh -n "$repo_dir/native-load-generator/payment-lanes.sh"
