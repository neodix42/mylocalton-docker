#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
env_file=${1:-.env.physical}

# shellcheck source=native-payment-lanes-profile.sh
source "$script_dir/native-payment-lanes-profile.sh"

if [[ $env_file != /* ]]; then
  env_file=$script_dir/../$env_file
fi
test -r "$env_file" || {
  echo "environment file is not readable: $env_file" >&2
  exit 2
}

cat >&2 <<'EOF'
Starting the fixed two-lane Phase-A native payment-lane profile.
The guarded fresh-cycle runner below deletes only the benchmark Compose
project's allowlisted containers, network, and volumes. Do not use this helper
against a state that must be retained.
EOF

native_payment_lanes_profile_env "$script_dir/run-fresh-native-cycle.sh" "$env_file"
