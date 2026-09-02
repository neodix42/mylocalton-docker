#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd "$script_dir/../.." && pwd)

# shellcheck source=../../docker/scripts/native-transfer-runs-config.sh
source "$repo_dir/docker/scripts/native-transfer-runs-config.sh"

assert_effective_config() {
  local expected_version=$1 expected_capability=$2
  resolve_native_transfer_runs_config
  [[ $NATIVE_TRANSFER_RUNS_EFFECTIVE_VERSION == "$expected_version" ]]
  [[ $NATIVE_TRANSFER_RUNS_EFFECTIVE_CAPABILITY == "$expected_capability" ]]
}

VERSION_CAPABILITIES=14
NATIVE_TRANSFER_RUNS_ENABLED=0
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15
NATIVE_TRANSFER_RUNS_CAPABILITY=1024
assert_effective_config 14 0

VERSION_CAPABILITIES=13
NATIVE_TRANSFER_RUNS_ENABLED=0
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=999
NATIVE_TRANSFER_RUNS_CAPABILITY=1
assert_effective_config 13 0

VERSION_CAPABILITIES=14
NATIVE_TRANSFER_RUNS_ENABLED=1
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15
NATIVE_TRANSFER_RUNS_CAPABILITY=1024
assert_effective_config 15 1024

NATIVE_TRANSFER_RUNS_ENABLED=2
! resolve_native_transfer_runs_config >/dev/null 2>&1
NATIVE_TRANSFER_RUNS_ENABLED=1
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=14
! resolve_native_transfer_runs_config >/dev/null 2>&1
NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15
NATIVE_TRANSFER_RUNS_CAPABILITY=512
! resolve_native_transfer_runs_config >/dev/null 2>&1

for env_file in .env .env.desktop .env.devnet .env.laptop .env.physical; do
  grep -qx 'VERSION_CAPABILITIES=14' "$repo_dir/$env_file"
  grep -qx 'NATIVE_TRANSFER_RUNS_ENABLED=0' "$repo_dir/$env_file"
  grep -qx 'NATIVE_TRANSFER_RUNS_GLOBAL_VERSION=15' "$repo_dir/$env_file"
  grep -qx 'NATIVE_TRANSFER_RUNS_CAPABILITY=1024' "$repo_dir/$env_file"
  grep -qx 'NATIVE_LOAD_NATIVE_TRANSFER_RUNS=0' "$repo_dir/$env_file"
  grep -qx 'NATIVE_LOAD_NATIVE_TRANSFER_RUN_SIZE=16' "$repo_dir/$env_file"
done

grep -Fqx 'VERSION_CAPABILITIES capCreateStats capBounceMsgBody or capReportVersion or capShortDequeue or 64 or 128 or NATIVE_TRANSFER_RUNS_CONFIG_CAPABILITY or config.version!' \
  "$repo_dir/docker/scripts/gen-zerostate.fif"
grep -Fq 'NATIVE_LOAD_NATIVE_TRANSFER_RUNS=1 requires a v5-capable native-load-generator image' \
  "$repo_dir/native-load-generator/entrypoint.sh"

bash -n "$repo_dir/docker/scripts/start-genesis.sh"
bash -n "$repo_dir/docker/scripts/native-transfer-runs-config.sh"
sh -n "$repo_dir/native-load-generator/entrypoint.sh"
