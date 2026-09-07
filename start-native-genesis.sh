#!/usr/bin/env bash
# Operator startup: refresh from the registry, rebuild local wrappers, then start/update only genesis.
# Compose may recreate genesis for a new image; existing volumes remain. Do not run during paired benchmarks.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
env_file="$script_dir/.env"
receipt="$script_dir/.native-images.json"
usage() {
  cat <<'HELP'
Usage: bash start-native-genesis.sh [--env-file FILE] [--receipt FILE]

Pull the current configured TON registry image, build genesis and the native
load generator from one digest, then start/update only genesis. The generator
is prepared but never launched. Compose may recreate genesis for a new image;
existing volumes are preserved. Run before a benchmark, then use strict image
reuse throughout the paired measurements.
HELP
}
while (($#)); do
  case "$1" in
    --env-file|--receipt)
      (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
      if [[ "$1" == --env-file ]]; then env_file=$2; else receipt=$2; fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
bash "$script_dir/prepare-native-images.sh" --env-file "$env_file" --receipt "$receipt"
docker compose --project-directory "$script_dir" --env-file "$env_file" \
  --profile native-load-generator up -d --no-deps --no-build --pull never genesis
printf 'Genesis started. Wait for it to be healthy and advancing blocks before exporting client materials.\n'
