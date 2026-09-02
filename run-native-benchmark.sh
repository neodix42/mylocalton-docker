#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./run-native-benchmark.sh [ENV_FILE] [RESULT_DIR]
       ./run-native-benchmark.sh --self-test

Runs session-stats and the native load generator, samples host/container
resources for the complete run, and writes a machine-readable summary.

Defaults:
  ENV_FILE    .env.physical
  RESULT_DIR  benchmark-results/<UTC timestamp>

Run this script itself with sudo when Docker requires root access. Optional:
  BENCHMARK_HOST_SAMPLE_SECONDS=1
  BENCHMARK_DETAIL_SAMPLE_SECONDS=5
  BENCHMARK_THREAD_SAMPLE_SECONDS=5
  BENCHMARK_MAX_THREADS_PER_CONTAINER=32
  BENCHMARK_ACTOR_STATS_SAMPLE_SECONDS=30
  BENCHMARK_ACTOR_STATS_TIMEOUT_SECONDS=2 # must be less than sample cadence, max 5
  BENCHMARK_RECREATE_GENESIS=1   # force container recreation even when matching
  BENCHMARK_STRICT_GENESIS_REUSE=1 # fail instead of reconciling a mismatch
  BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED=0|1 # opt-in validator control; unset is a no-op
EOF
}

resolve_ext_messages_broadcast_setting() {
  local is_set=${1:-0} value=${2:-}
  if [[ $is_set == 0 ]]; then
    printf 'false\tnull\tnull\n'
    return 0
  fi
  case "$value" in
    0) printf 'true\t0\tfalse\n' ;;
    1) printf 'true\t1\ttrue\n' ;;
    *) return 2 ;;
  esac
}

extract_validator_config_json() {
  local input_file=$1 output_file=$2
  awk '
    { sub(/\r$/, "") }
    $0 == "---------" { inside = 1; next }
    $0 == "--------" && inside { complete = 1; exit }
    inside { print }
    END { if (!inside || !complete) exit 1 }
  ' "$input_file" |
    jq -e 'if type == "object" then . else error("validator config is not an object") end' \
      >"$output_file"
}

validator_config_ext_messages_broadcast_disabled() {
  jq -r '
    (.fullnodeconfig? // null) as $fullnode |
    if $fullnode == null then false
    elif ($fullnode | type) != "object" then error("fullnodeconfig is not an object")
    else ($fullnode.ext_messages_broadcast_disabled // false) as $disabled |
      if ($disabled | type) == "boolean" then $disabled
      else error("ext_messages_broadcast_disabled is not boolean")
      end
    end
  ' "$1"
}

validator_console_reported_exact_success() {
  awk '
    { sub(/\r$/, "") }
    { line[NR] = $0 }
    END {
      # Batch validator-engine-console writes this four-line connection
      # preamble to stdout before the command reply. Accept only that exact
      # shape and one exact success answer; duplicate or unrelated output is
      # a failed control operation.
      if (NR != 5 ||
          substr(line[1], 1, 14) != "connecting to " || length(line[1]) <= 14 ||
          substr(line[2], 1, 11) != "local key: " ||
          length(substr(line[2], 12)) != 64 || substr(line[2], 12) ~ /[^0-9A-Fa-f]/ ||
          substr(line[3], 1, 12) != "remote key: " ||
          length(substr(line[3], 13)) != 64 || substr(line[3], 13) ~ /[^0-9A-Fa-f]/ ||
          line[4] != "conn ready" || line[5] != "success") {
        exit 1
      }
    }
  ' "$1"
}

ext_messages_broadcast_exit_status() {
  local original_status=$1 cleanup_status=$2
  if (( original_status != 0 )); then
    printf '%s\n' "$original_status"
  elif (( cleanup_status != 0 )); then
    # A benchmark that otherwise passed must fail closed when the persistent
    # validator setting cannot be restored and verified.
    printf '4\n'
  else
    printf '0\n'
  fi
}

write_ext_messages_broadcast_provenance() {
  jq -n \
    --arg schema native-benchmark-ext-messages-broadcast-v1 \
    --arg environment_variable BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED \
    --arg artifact "$(basename "$ext_messages_broadcast_file")" \
    --argjson requested "$ext_messages_broadcast_requested" \
    --argjson requested_value "$ext_messages_broadcast_requested_value" \
    --argjson desired_disabled "$ext_messages_broadcast_desired_disabled" \
    --argjson applied "$ext_messages_broadcast_applied" \
    --argjson settle_seconds "$ext_messages_broadcast_settle_seconds" \
    --slurpfile before "$ext_messages_broadcast_before_record_file" \
    --slurpfile apply_control "$ext_messages_broadcast_apply_control_file" \
    --slurpfile after_apply "$ext_messages_broadcast_after_apply_record_file" \
    --slurpfile post_load "$ext_messages_broadcast_post_load_record_file" \
    --slurpfile restoration "$ext_messages_broadcast_restore_record_file" '
    def state_matches($state; $desired):
      $state != null and $state.capture_complete == true and $state.consistent == true and
      $state.get_config.effective_disabled == $desired and
      $state.disk_config.effective_disabled == $desired;
    ($before[0] // null) as $before_state |
    ($apply_control[0] // null) as $control |
    ($after_apply[0] // null) as $after_state |
    ($post_load[0] // null) as $post_state |
    ($restoration[0] // {attempted:false,valid:null}) as $restore |
    (if $requested == false then true
     else (($control.exact_success // false) and state_matches($after_state; $desired_disabled))
     end) as $application_valid |
    (if $requested == false then true
     elif $post_state == null then null
     else state_matches($post_state; $desired_disabled)
     end) as $post_load_valid |
    {
      $schema,$artifact,$environment_variable,$requested,$requested_value,$desired_disabled,
      applied:($applied == 1),settle_seconds:$settle_seconds,
      before:$before_state,apply:{control:$control,state:$after_state,valid:$application_valid},
      post_load:{state:$post_state,valid:$post_load_valid},restoration:$restore,
      lifecycle_valid:(
        if $requested == false then true
        elif $restore.attempted != true then null
        else
          ($application_valid and ($post_load_valid == true) and ($restore.valid == true) and
           (($restore.prior_failure // false) == false))
        end
      ),
      semantics:(if $requested == false then
        "unset is backward-compatible and performs no validator control query or configuration mutation"
      else
        "the requested 0|1 control is applied after genesis health and before pre-load snapshots; in-memory get-config and persisted config.json must agree, and cleanup restores disabled=false"
      end)
    }
  ' >"$ext_messages_broadcast_file"
}

ext_messages_broadcast_self_test() {
  command -v jq >/dev/null 2>&1
  local test_dir setting state_false state_true
  test_dir=$(mktemp -d)
  trap 'rm -rf -- "$test_dir"' RETURN

  setting=$(resolve_ext_messages_broadcast_setting 0 '')
  [[ $setting == $'false\tnull\tnull' ]]
  setting=$(resolve_ext_messages_broadcast_setting 1 0)
  [[ $setting == $'true\t0\tfalse' ]]
  setting=$(resolve_ext_messages_broadcast_setting 1 1)
  [[ $setting == $'true\t1\ttrue' ]]
  ! resolve_ext_messages_broadcast_setting 1 '' >/dev/null
  ! resolve_ext_messages_broadcast_setting 1 2 >/dev/null

  printf '%s\n' \
    'validator console preamble' \
    '---------' \
    '{' \
    '  "@type": "engine.validator.config",' \
    '  "fullnodeconfig": {' \
    '    "@type": "engine.validator.fullNodeConfig",' \
    '    "ext_messages_broadcast_disabled": true' \
    '  }' \
    '}' \
    '--------' >"$test_dir/get-config.txt"
  extract_validator_config_json "$test_dir/get-config.txt" "$test_dir/get-config.json"
  [[ $(validator_config_ext_messages_broadcast_disabled "$test_dir/get-config.json") == true ]]
  printf '{"@type":"engine.validator.config"}\n' >"$test_dir/default.json"
  [[ $(validator_config_ext_messages_broadcast_disabled "$test_dir/default.json") == false ]]
  printf '{"fullnodeconfig":{"ext_messages_broadcast_disabled":false}}\n' \
    >"$test_dir/explicit-false.json"
  [[ $(validator_config_ext_messages_broadcast_disabled "$test_dir/explicit-false.json") == false ]]
  printf '{"fullnodeconfig":{"ext_messages_broadcast_disabled":"false"}}\n' \
    >"$test_dir/nonboolean.json"
  ! validator_config_ext_messages_broadcast_disabled "$test_dir/nonboolean.json" >/dev/null 2>&1
  printf 'missing delimiters\n' >"$test_dir/invalid.txt"
  ! extract_validator_config_json "$test_dir/invalid.txt" "$test_dir/invalid.json"
  printf '%s\n' \
    'connecting to 127.0.0.1:43679' \
    'local key: 0000000000000000000000000000000000000000000000000000000000000000' \
    'remote key: 1111111111111111111111111111111111111111111111111111111111111111' \
    'conn ready' \
    'success' >"$test_dir/success.txt"
  validator_console_reported_exact_success "$test_dir/success.txt"
  cp "$test_dir/success.txt" "$test_dir/extra-success.txt"
  printf 'success\n' >>"$test_dir/extra-success.txt"
  ! validator_console_reported_exact_success "$test_dir/extra-success.txt"
  sed 's/^conn ready$/unexpected output/' "$test_dir/success.txt" \
    >"$test_dir/unexpected-success.txt"
  ! validator_console_reported_exact_success "$test_dir/unexpected-success.txt"
  printf 'success\n' >"$test_dir/bare-success.txt"
  ! validator_console_reported_exact_success "$test_dir/bare-success.txt"

  [[ $(ext_messages_broadcast_exit_status 0 0) == 0 ]]
  [[ $(ext_messages_broadcast_exit_status 0 1) == 4 ]]
  [[ $(ext_messages_broadcast_exit_status 3 0) == 3 ]]
  [[ $(ext_messages_broadcast_exit_status 3 1) == 3 ]]

  ext_messages_broadcast_file=$test_dir/provenance.json
  ext_messages_broadcast_before_record_file=$test_dir/before.json
  ext_messages_broadcast_after_apply_record_file=$test_dir/after-apply.json
  ext_messages_broadcast_post_load_record_file=$test_dir/post-load.json
  ext_messages_broadcast_apply_control_file=$test_dir/apply-control.json
  ext_messages_broadcast_restore_record_file=$test_dir/restore.json
  ext_messages_broadcast_settle_seconds=5
  state_false='{"capture_complete":true,"consistent":true,"get_config":{"effective_disabled":false},"disk_config":{"effective_disabled":false}}'
  state_true='{"capture_complete":true,"consistent":true,"get_config":{"effective_disabled":true},"disk_config":{"effective_disabled":true}}'

  printf 'null\n' >"$ext_messages_broadcast_before_record_file"
  printf 'null\n' >"$ext_messages_broadcast_after_apply_record_file"
  printf 'null\n' >"$ext_messages_broadcast_post_load_record_file"
  printf 'null\n' >"$ext_messages_broadcast_apply_control_file"
  printf '%s\n' '{"attempted":false,"valid":null}' >"$ext_messages_broadcast_restore_record_file"
  ext_messages_broadcast_requested=false
  ext_messages_broadcast_requested_value=null
  ext_messages_broadcast_desired_disabled=null
  ext_messages_broadcast_applied=0
  write_ext_messages_broadcast_provenance
  jq -e '
    .requested == false and .requested_value == null and .desired_disabled == null and
    .applied == false and .before == null and .apply.valid == true and
    .post_load.valid == true and .restoration.attempted == false and
    .lifecycle_valid == true
  ' "$ext_messages_broadcast_file" >/dev/null

  printf '%s\n' "$state_true" >"$ext_messages_broadcast_before_record_file"
  printf '%s\n' "$state_false" >"$ext_messages_broadcast_after_apply_record_file"
  printf '%s\n' "$state_false" >"$ext_messages_broadcast_post_load_record_file"
  printf '%s\n' '{"exact_success":true}' >"$ext_messages_broadcast_apply_control_file"
  printf '%s\n' '{"attempted":true,"valid":true,"prior_failure":false}' \
    >"$ext_messages_broadcast_restore_record_file"
  ext_messages_broadcast_requested=true
  ext_messages_broadcast_requested_value=0
  ext_messages_broadcast_desired_disabled=false
  ext_messages_broadcast_applied=1
  write_ext_messages_broadcast_provenance
  jq -e '
    .requested == true and .requested_value == 0 and .desired_disabled == false and
    .applied == true and .apply.valid == true and .post_load.valid == true and
    .restoration.valid == true and .lifecycle_valid == true
  ' "$ext_messages_broadcast_file" >/dev/null

  printf '%s\n' "$state_false" >"$ext_messages_broadcast_before_record_file"
  printf '%s\n' "$state_true" >"$ext_messages_broadcast_after_apply_record_file"
  printf '%s\n' "$state_true" >"$ext_messages_broadcast_post_load_record_file"
  ext_messages_broadcast_requested_value=1
  ext_messages_broadcast_desired_disabled=true
  printf '%s\n' '{"attempted":false,"valid":null}' \
    >"$ext_messages_broadcast_restore_record_file"
  write_ext_messages_broadcast_provenance
  jq -e '
    .requested == true and .requested_value == 1 and .desired_disabled == true and
    .apply.valid == true and .post_load.valid == true and .restoration.attempted == false and
    .lifecycle_valid == null
  ' "$ext_messages_broadcast_file" >/dev/null

  printf '%s\n' '{"attempted":true,"attempt":1,"valid":true,"prior_failure":false}' \
    >"$ext_messages_broadcast_restore_record_file"
  write_ext_messages_broadcast_provenance
  jq -e '
    .restoration.attempt == 1 and .restoration.valid == true and
    .restoration.prior_failure == false and .lifecycle_valid == true
  ' "$ext_messages_broadcast_file" >/dev/null

  # A failed first restore followed by a verified second restore remains an
  # invalid experiment even though the persistent setting is finally safe.
  printf '%s\n' '{"attempted":true,"attempt":2,"valid":true,"prior_failure":true}' \
    >"$ext_messages_broadcast_restore_record_file"
  write_ext_messages_broadcast_provenance
  jq -e '
    .restoration.attempt == 2 and .restoration.valid == true and
    .restoration.prior_failure == true and .lifecycle_valid == false
  ' "$ext_messages_broadcast_file" >/dev/null
}

# Keep transient Docker/container states distinct from a terminal generator
# exit. In particular, a collector started beside `compose up -d` must wait
# through container creation and a temporary failed inspection instead of
# treating either as the end of the load window.
actor_stats_container_action() {
  case "${1:-unknown}" in
    running) printf 'sample\n' ;;
    exited|dead) printf 'stop\n' ;;
    *) printf 'wait\n' ;;
  esac
}

actor_stats_container_state_self_test() {
  [[ $(actor_stats_container_action unknown) == wait ]]
  [[ $(actor_stats_container_action created) == wait ]]
  [[ $(actor_stats_container_action restarting) == wait ]]
  [[ $(actor_stats_container_action paused) == wait ]]
  [[ $(actor_stats_container_action removing) == wait ]]
  [[ $(actor_stats_container_action running) == sample ]]
  [[ $(actor_stats_container_action exited) == stop ]]
  [[ $(actor_stats_container_action dead) == stop ]]
}

actor_stats_sleep_seconds() {
  awk -v now="$1" -v wake="$2" '
    BEGIN {
      delay = (wake - now) / 1000
      printf "%.3f", (delay > 0.01 ? delay : 0.01)
    }
  '
}

actor_stats_sleep_seconds_self_test() {
  [[ $(actor_stats_sleep_seconds 1000 2500) == 1.500 ]]
  [[ $(actor_stats_sleep_seconds 1000 1000) == 0.010 ]]
  [[ $(actor_stats_sleep_seconds 2500 1000) == 0.010 ]]
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
benchmark_jq_dir=$script_dir/benchmark/jq

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --self-test) exec bash "$script_dir/benchmark/tests/native-benchmark-reporting-test.sh" ;;
  --self-test-actor-stats-container-state)
    actor_stats_container_state_self_test
    exit 0
    ;;
  --self-test-actor-stats-sleep)
    actor_stats_sleep_seconds_self_test
    exit 0
    ;;
  --self-test-ext-messages-broadcast)
    ext_messages_broadcast_self_test
    exit 0
    ;;
esac

env_file=${1:-.env.physical}
run_id=$(date -u +%Y%m%dT%H%M%SZ)
result_dir=${2:-benchmark-results/$run_id}
if [[ $env_file != /* ]]; then
  env_file=$script_dir/$env_file
fi
if [[ $result_dir != /* ]]; then
  result_dir=$script_dir/$result_dir
fi
host_sample_seconds=${BENCHMARK_HOST_SAMPLE_SECONDS:-1}
detail_sample_seconds=${BENCHMARK_DETAIL_SAMPLE_SECONDS:-5}
thread_sample_seconds=${BENCHMARK_THREAD_SAMPLE_SECONDS:-5}
max_threads_per_container=${BENCHMARK_MAX_THREADS_PER_CONTAINER:-32}
actor_stats_sample_seconds=${BENCHMARK_ACTOR_STATS_SAMPLE_SECONDS:-30}
actor_stats_timeout_seconds=${BENCHMARK_ACTOR_STATS_TIMEOUT_SECONDS:-2}
container_name=native-load-generator

if [[ ${BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED+x} == x ]]; then
  ext_messages_broadcast_setting_is_set=1
else
  ext_messages_broadcast_setting_is_set=0
fi
if ! IFS=$'\t' read -r ext_messages_broadcast_requested \
  ext_messages_broadcast_requested_value ext_messages_broadcast_desired_disabled < <(
    resolve_ext_messages_broadcast_setting "$ext_messages_broadcast_setting_is_set" \
      "${BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED:-}"
  ); then
  echo "BENCHMARK_EXT_MESSAGES_BROADCAST_DISABLED must be unset, 0, or 1" >&2
  exit 2
fi
ext_messages_broadcast_settle_seconds=5

for command_name in docker jq awk git getconf sed sort cut sha256sum timeout; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required command is not installed: $command_name" >&2
    exit 2
  }
done

docker compose version >/dev/null 2>&1 || {
  echo "Docker Compose v2 is required" >&2
  exit 2
}
docker info >/dev/null 2>&1 || {
  echo "cannot access Docker; run this script with sudo or configure Docker access" >&2
  exit 2
}
test -r "$env_file" || { echo "environment file is not readable: $env_file" >&2; exit 2; }
case "$host_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_HOST_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v seconds="$host_sample_seconds" 'BEGIN { exit !(seconds > 0) }' || {
  echo "BENCHMARK_HOST_SAMPLE_SECONDS must be greater than zero" >&2
  exit 2
}
case "$detail_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_DETAIL_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v seconds="$detail_sample_seconds" 'BEGIN { exit !(seconds > 0) }' || {
  echo "BENCHMARK_DETAIL_SAMPLE_SECONDS must be greater than zero" >&2
  exit 2
}
case "$thread_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_THREAD_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v seconds="$thread_sample_seconds" 'BEGIN { exit !(seconds > 0) }' || {
  echo "BENCHMARK_THREAD_SAMPLE_SECONDS must be greater than zero" >&2
  exit 2
}
case "$max_threads_per_container" in
  ''|*[!0-9]*)
    echo "BENCHMARK_MAX_THREADS_PER_CONTAINER must be a positive integer" >&2
    exit 2
    ;;
esac
if (( max_threads_per_container < 1 || max_threads_per_container > 256 )); then
  echo "BENCHMARK_MAX_THREADS_PER_CONTAINER must be between 1 and 256" >&2
  exit 2
fi
case "$actor_stats_sample_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_ACTOR_STATS_SAMPLE_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
case "$actor_stats_timeout_seconds" in
  ''|*[!0-9.]*|.*|*.)
    echo "BENCHMARK_ACTOR_STATS_TIMEOUT_SECONDS must be a positive number" >&2
    exit 2
    ;;
esac
awk -v sample="$actor_stats_sample_seconds" -v command_timeout="$actor_stats_timeout_seconds" '
  BEGIN { exit !(sample > 0 && command_timeout > 0 && command_timeout <= 5 && command_timeout < sample) }
' || {
  echo "actor-stat timeout must be positive, at most 5 seconds, and less than its sample cadence" >&2
  exit 2
}
actor_stats_host_guard_seconds=$(awk -v command_timeout="$actor_stats_timeout_seconds" \
  'BEGIN { printf "%.3f", command_timeout + 2 }')
test -r "$benchmark_jq_dir/native-benchmark-lib.jq" || {
  echo "benchmark jq library is missing: $benchmark_jq_dir/native-benchmark-lib.jq" >&2
  exit 2
}

# The benchmark uses fixed container names and its fresh-cycle companion
# deletes state for this exact project. Pin both selectors here as well so an
# inherited COMPOSE_FILE/COMPOSE_PROJECT_NAME cannot redirect the subsequent
# non-destructive run after the guarded deletion boundary.
compose=(docker compose -f "$script_dir/docker-compose.yaml" --project-directory "$script_dir" \
  --project-name mylocalton-desktop --env-file "$env_file")
compose_environment=$("${compose[@]}" config --environment)
ton_image=$(awk -F= '$1 == "TON_IMAGE" {sub(/^[^=]*=/, ""); print; exit}' <<<"$compose_environment")
ton_branch=$(awk -F= '$1 == "TON_BRANCH" {sub(/^[^=]*=/, ""); print; exit}' <<<"$compose_environment")
ton_image=${ton_image:-ghcr.io/corton-nommander/ton}
ton_branch=${ton_branch:-latest}
ton_base_image=$ton_image:$ton_branch
if ! docker image inspect "$ton_base_image" >/dev/null 2>&1; then
  echo "required TON benchmark base image is not available locally: $ton_base_image" >&2
  echo "build the matching TON source checkout first; see README.md (Native high-rate load)" >&2
  echo "run the documented Docker build from that checkout, including its VCS_REF label" >&2
  exit 2
fi
ton_base_revision=$(docker image inspect -f \
  '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$ton_base_image" 2>/dev/null || true)
if [[ -z $ton_base_revision || $ton_base_revision == '<no value>' || $ton_base_revision == unknown ]]; then
  echo "TON benchmark base image lacks source-revision provenance: $ton_base_image" >&2
  echo "rebuild it from the matching TON checkout with the VCS_REF command in README.md" >&2
  exit 2
fi

# Exercise the complete Compose provenance path before creating a result
# directory or starting a long run. Compose 2.39 requires one explicit service
# per `config --hash`; sorting keeps metadata deterministic across versions
# whose `config --services` order is unstable.
compose_config_sha256=$("${compose[@]}" --profile session-stats --profile native-load-generator config |
  sha256sum | awk '{print $1}')
if ! compose_services=$("${compose[@]}" --profile session-stats --profile native-load-generator \
  config --services); then
  echo "failed to enumerate resolved Compose services" >&2
  exit 2
fi
compose_services=$(sort <<<"$compose_services")
if ! compose_service_hash_lines=$(
  while IFS= read -r service; do
    [[ -n $service ]] || continue
    "${compose[@]}" --profile session-stats --profile native-load-generator \
      config --hash "$service" || exit 1
  done <<<"$compose_services"
); then
  echo "failed to collect one or more resolved Compose service hashes" >&2
  exit 2
fi
compose_service_hashes=$(jq -Rsc '
  [split("\n")[] | select(length > 0) | split(" ") |
   select(length >= 2) | {service:.[0],config_hash:.[1]}] | sort_by(.service)
' <<<"$compose_service_hash_lines")

if [[ -d "$result_dir" && -n $(find "$result_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
  if [[ $# -lt 2 ]]; then
    result_dir=${result_dir}-$$
  else
    echo "result directory is not empty: $result_dir" >&2
    exit 2
  fi
fi
mkdir -p "$result_dir"
result_dir=$(cd "$result_dir" && pwd)
container_stats_file=$result_dir/container-resources.jsonl
host_stats_file=$result_dir/host-resources.jsonl
cgroup_stats_file=$result_dir/cgroup-resources.jsonl
thread_stats_file=$result_dir/thread-resources.jsonl
device_stats_file=$result_dir/device-resources.jsonl
generator_log_file=$result_dir/native-load-generator.log
generator_summary_file=$result_dir/generator-summary.json
resource_summary_file=$result_dir/resource-summary.json
session_stats_summary_file=$result_dir/session-stats-summary.json
validator_session_stats_file=$result_dir/validator-session-stats.jsonl
validator_pipeline_summary_file=$result_dir/validator-pipeline-summary.json
validator_stats_before_file=$result_dir/validator-stats-before.txt
validator_stats_after_file=$result_dir/validator-stats-after.txt
validator_pool_summary_file=$result_dir/validator-pool-summary.json
validator_scheduling_log_file=$result_dir/validator-scheduling.log
validator_scheduling_log_summary_file=$result_dir/validator-scheduling-log-summary.json
validator_scheduling_summary_file=$result_dir/validator-scheduling-summary.json
validator_actor_stats_file=$result_dir/validator-actor-stats.jsonl
validator_actor_stats_pre_load_file=$result_dir/validator-actor-stats-pre-load.txt
validator_actor_stats_pre_load_metadata_file=$result_dir/validator-actor-stats-pre-load.json
validator_actor_stats_final_file=$result_dir/validator-actor-stats-final.txt
validator_actor_stats_final_metadata_file=$result_dir/validator-actor-stats-final.json
validator_actor_stats_summary_file=$result_dir/validator-actor-stats-summary.json
ext_messages_broadcast_file=$result_dir/validator-ext-messages-broadcast.json
ext_messages_broadcast_before_record_file=$result_dir/.validator-ext-messages-broadcast-before.json
ext_messages_broadcast_after_apply_record_file=$result_dir/.validator-ext-messages-broadcast-after-apply.json
ext_messages_broadcast_post_load_record_file=$result_dir/.validator-ext-messages-broadcast-post-load.json
ext_messages_broadcast_apply_control_file=$result_dir/.validator-ext-messages-broadcast-apply-control.json
ext_messages_broadcast_restore_record_file=$result_dir/.validator-ext-messages-broadcast-restore.json
runtime_file=$result_dir/container-runtime.json
image_metadata_file=$result_dir/image-metadata.json
metadata_file=$result_dir/run-metadata.json
summary_file=$result_dir/benchmark-summary.json
: >"$container_stats_file"
: >"$host_stats_file"
: >"$cgroup_stats_file"
: >"$thread_stats_file"
: >"$device_stats_file"
: >"$validator_actor_stats_file"
printf 'null\n' >"$ext_messages_broadcast_before_record_file"
printf 'null\n' >"$ext_messages_broadcast_after_apply_record_file"
printf 'null\n' >"$ext_messages_broadcast_post_load_record_file"
printf 'null\n' >"$ext_messages_broadcast_apply_control_file"
jq -n '{attempted:false,valid:null,semantics:"unset runs do not mutate validator configuration"}' \
  >"$ext_messages_broadcast_restore_record_file"

collector_pids=()
actor_stats_collector_pid=
interrupted=0
ext_messages_broadcast_restore_required=0
ext_messages_broadcast_applied=0
ext_messages_broadcast_restore_attempts=0
ext_messages_broadcast_restore_had_failure=0

run_validator_console_command() {
  local command_text=$1 output_file=$2 error_file=$3
  timeout --signal=TERM --kill-after=1s 18s docker exec genesis sh -c '
    config=/var/ton-work/db/config.json
    internal_ip=$(hostname -I)
    internal_ip=${internal_ip%% *}
    control_port=$(jq -r ".control[0].port // empty" "$config")
    test -n "$internal_ip" && test -n "$control_port"
    exec timeout --signal=TERM --kill-after=1s 15s validator-engine-console \
      -k /var/ton-work/db/client \
      -p /var/ton-work/db/server.pub \
      -a "$internal_ip:$control_port" \
      -c "$1"
  ' sh "$command_text" >"$output_file" 2>"$error_file"
}

capture_ext_messages_broadcast_state() {
  local phase=$1 record_file=$2
  local prefix=$result_dir/validator-ext-messages-broadcast-$phase
  local get_config_raw_file=$prefix-get-config.txt
  local get_config_file=$prefix-get-config.json
  local get_config_error_file=$prefix-get-config.stderr.log
  local disk_config_file=$prefix-disk-config.json
  local disk_config_error_file=$prefix-disk-config.stderr.log
  local captured_at get_config_raw_sha256 get_config_sha256 disk_config_sha256
  local get_config_effective disk_config_effective

  captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_validator_console_command get-config "$get_config_raw_file" "$get_config_error_file" || return
  extract_validator_config_json "$get_config_raw_file" "$get_config_file" || return
  timeout --signal=TERM --kill-after=1s 15s \
    docker cp genesis:/var/ton-work/db/config.json "$disk_config_file" \
    >/dev/null 2>"$disk_config_error_file" || return

  get_config_effective=$(validator_config_ext_messages_broadcast_disabled "$get_config_file") || return
  disk_config_effective=$(validator_config_ext_messages_broadcast_disabled "$disk_config_file") || return
  get_config_raw_sha256=$(sha256sum "$get_config_raw_file" | awk '{print $1}')
  get_config_sha256=$(sha256sum "$get_config_file" | awk '{print $1}')
  disk_config_sha256=$(sha256sum "$disk_config_file" | awk '{print $1}')
  jq -n \
    --arg captured_at "$captured_at" \
    --arg phase "$phase" \
    --arg get_config_raw_artifact "$(basename "$get_config_raw_file")" \
    --arg get_config_artifact "$(basename "$get_config_file")" \
    --arg get_config_stderr_artifact "$(basename "$get_config_error_file")" \
    --arg get_config_raw_sha256 "$get_config_raw_sha256" \
    --arg get_config_sha256 "$get_config_sha256" \
    --argjson get_config_effective "$get_config_effective" \
    --arg disk_config_artifact "$(basename "$disk_config_file")" \
    --arg disk_config_stderr_artifact "$(basename "$disk_config_error_file")" \
    --arg disk_config_sha256 "$disk_config_sha256" \
    --argjson disk_config_effective "$disk_config_effective" \
    '{$captured_at,$phase,capture_complete:true,
      get_config:{raw_artifact:$get_config_raw_artifact,artifact:$get_config_artifact,
        stderr_artifact:$get_config_stderr_artifact,raw_sha256:$get_config_raw_sha256,
        sha256:$get_config_sha256,effective_disabled:$get_config_effective},
      disk_config:{artifact:$disk_config_artifact,stderr_artifact:$disk_config_stderr_artifact,
        sha256:$disk_config_sha256,effective_disabled:$disk_config_effective},
      consistent:($get_config_effective == $disk_config_effective)}' >"$record_file"
}

ext_messages_broadcast_state_matches() {
  local record_file=$1 desired=$2
  jq -e --argjson desired "$desired" '
    .capture_complete == true and .consistent == true and
    .get_config.effective_disabled == $desired and
    .disk_config.effective_disabled == $desired
  ' "$record_file" >/dev/null
}

set_ext_messages_broadcast_disabled() {
  local requested_value=$1 label=$2 record_file=$3
  local output_file=$result_dir/validator-ext-messages-broadcast-$label-command.stdout
  local error_file=$result_dir/validator-ext-messages-broadcast-$label-command.stderr.log
  local started_at finished_at command_exit_code=0 exact_success=false
  started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if run_validator_console_command \
    "set-ext-messages-broadcast-disabled $requested_value" "$output_file" "$error_file"; then
    command_exit_code=0
  else
    command_exit_code=$?
  fi
  if (( command_exit_code == 0 )) && validator_console_reported_exact_success "$output_file"; then
    exact_success=true
  fi
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --arg command "set-ext-messages-broadcast-disabled $requested_value" \
    --arg stdout_artifact "$(basename "$output_file")" \
    --arg stderr_artifact "$(basename "$error_file")" \
    --argjson requested_value "$requested_value" \
    --argjson command_exit_code "$command_exit_code" \
    --argjson exact_success "$exact_success" \
    '{$started_at,$finished_at,$command,$requested_value,$command_exit_code,$exact_success,
      $stdout_artifact,$stderr_artifact}' >"$record_file" || return
  [[ $exact_success == true ]]
}

apply_ext_messages_broadcast_setting() {
  [[ $ext_messages_broadcast_requested == true ]] || return 0
  echo "Capturing validator external-message broadcast configuration before opt-in control"
  capture_ext_messages_broadcast_state before "$ext_messages_broadcast_before_record_file" || {
    write_ext_messages_broadcast_provenance
    echo "failed to capture validator configuration before external-message broadcast control" >&2
    return 1
  }

  # Runtime propagation precedes config.json persistence in validator-engine.
  # Mark restoration pending before the call because even an error response may
  # leave the live FullNode setting changed.
  ext_messages_broadcast_restore_required=1
  if ! set_ext_messages_broadcast_disabled "$ext_messages_broadcast_requested_value" apply \
    "$ext_messages_broadcast_apply_control_file"; then
    write_ext_messages_broadcast_provenance
    echo "validator did not report exact success for external-message broadcast control" >&2
    return 1
  fi
  ext_messages_broadcast_applied=1
  sleep "$ext_messages_broadcast_settle_seconds" || return 1
  if ! capture_ext_messages_broadcast_state after-apply \
    "$ext_messages_broadcast_after_apply_record_file" ||
     ! ext_messages_broadcast_state_matches "$ext_messages_broadcast_after_apply_record_file" \
       "$ext_messages_broadcast_desired_disabled"; then
    write_ext_messages_broadcast_provenance
    echo "validator in-memory and persisted external-message broadcast settings did not match the request" >&2
    return 1
  fi
  write_ext_messages_broadcast_provenance
}

restore_ext_messages_broadcast_setting() {
  [[ $ext_messages_broadcast_restore_required == 1 ]] || return 0
  local attempt_label control_record_file state_record_file
  local command_valid=false settle_valid=false state_valid=false restore_valid=false
  ext_messages_broadcast_restore_attempts=$((ext_messages_broadcast_restore_attempts + 1))
  attempt_label=restore-attempt-$ext_messages_broadcast_restore_attempts
  control_record_file=$result_dir/.validator-ext-messages-broadcast-$attempt_label-control.json
  state_record_file=$result_dir/.validator-ext-messages-broadcast-$attempt_label-state.json
  printf 'null\n' >"$control_record_file"
  printf 'null\n' >"$state_record_file"

  echo "Restoring validator external-message broadcasting before exit" >&2
  if set_ext_messages_broadcast_disabled 0 "$attempt_label" "$control_record_file"; then
    command_valid=true
  fi
  if sleep "$ext_messages_broadcast_settle_seconds"; then
    settle_valid=true
  fi
  if [[ $settle_valid == true ]] &&
     capture_ext_messages_broadcast_state "$attempt_label" "$state_record_file" &&
     ext_messages_broadcast_state_matches "$state_record_file" false; then
    state_valid=true
  fi
  if [[ $command_valid == true && $state_valid == true ]]; then
    restore_valid=true
  else
    ext_messages_broadcast_restore_had_failure=1
  fi
  if ! jq -n \
    --argjson attempted true \
    --argjson attempt "$ext_messages_broadcast_restore_attempts" \
    --argjson prior_failure "$ext_messages_broadcast_restore_had_failure" \
    --argjson command_valid "$command_valid" \
    --argjson settle_valid "$settle_valid" \
    --argjson state_valid "$state_valid" \
    --argjson valid "$restore_valid" \
    --slurpfile control "$control_record_file" \
    --slurpfile state "$state_record_file" \
    '{$attempted,$attempt,prior_failure:($prior_failure == 1),$command_valid,$settle_valid,$state_valid,$valid,
      requested_disabled:false,control:($control[0] // null),state:($state[0] // null),
      semantics:"cleanup always restores the safe default disabled=false; a prior failed attempt remains visible and invalidates an otherwise successful experiment"}' \
    >"$ext_messages_broadcast_restore_record_file"; then
    ext_messages_broadcast_restore_had_failure=1
    return 1
  fi
  if ! write_ext_messages_broadcast_provenance; then
    ext_messages_broadcast_restore_had_failure=1
    return 1
  fi
  if [[ $restore_valid == true ]]; then
    ext_messages_broadcast_restore_required=0
  fi
  [[ $restore_valid == true ]]
}

patch_ext_messages_broadcast_reports() {
  local temp_file
  if [[ -s ${metadata_file:-} ]]; then
    temp_file=$result_dir/.run-metadata-ext-messages-broadcast.json
    jq --slurpfile configuration "$ext_messages_broadcast_file" \
      '.ext_messages_broadcast = $configuration[0]' "$metadata_file" >"$temp_file" &&
      mv -- "$temp_file" "$metadata_file" || return
  fi
  if [[ -s ${summary_file:-} ]]; then
    temp_file=$result_dir/.benchmark-summary-ext-messages-broadcast.json
    jq --slurpfile configuration "$ext_messages_broadcast_file" '
      .ext_messages_broadcast = $configuration[0] |
      .run.ext_messages_broadcast = $configuration[0]
    ' "$summary_file" >"$temp_file" && mv -- "$temp_file" "$summary_file" || return
  fi
}

stop_collectors() {
  local pid
  for pid in "${collector_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${collector_pids[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
  collector_pids=()
}

stop_actor_stats_collector() {
  if [[ -n ${actor_stats_collector_pid:-} ]]; then
    kill "$actor_stats_collector_pid" 2>/dev/null || true
    wait "$actor_stats_collector_pid" 2>/dev/null || true
    actor_stats_collector_pid=
  fi
}

wait_actor_stats_collector() {
  if [[ -n ${actor_stats_collector_pid:-} ]]; then
    wait "$actor_stats_collector_pid" 2>/dev/null || true
    actor_stats_collector_pid=
  fi
}

cleanup_collectors() {
  stop_collectors
  stop_actor_stats_collector
}

cleanup_benchmark_on_exit() {
  local original_status=$?
  local cleanup_status=0 final_status
  trap - EXIT
  set +e
  cleanup_collectors
  if ! restore_ext_messages_broadcast_setting; then
    cleanup_status=1
    # One bounded retry handles a transient console/readback failure while the
    # recorded prior failure still invalidates an otherwise successful run.
    restore_ext_messages_broadcast_setting || true
  fi
  if ! patch_ext_messages_broadcast_reports; then
    cleanup_status=1
  fi
  final_status=$(ext_messages_broadcast_exit_status "$original_status" "$cleanup_status")
  exit "$final_status"
}

handle_signal() {
  interrupted=1
  echo "interrupt received; stopping native load generator" >&2
  docker stop --timeout 10 "$container_name" >/dev/null 2>&1 || true
}

trap handle_signal INT TERM
write_ext_messages_broadcast_provenance
trap cleanup_benchmark_on_exit EXIT

capture_validator_stats() {
  local output_file=$1
  timeout 15s docker exec genesis sh -c '
    config=/var/ton-work/db/config.json
    internal_ip=$(hostname -I)
    internal_ip=${internal_ip%% *}
    control_port=$(jq -r ".control[0].port // empty" "$config")
    test -n "$internal_ip" && test -n "$control_port"
    exec validator-engine-console \
      -k /var/ton-work/db/client \
      -p /var/ton-work/db/server.pub \
      -a "$internal_ip:$control_port" \
      -c getstats
  ' >"$output_file" 2>>"$result_dir/validator-stats.stderr.log"
}

capture_validator_actor_stats_raw() {
  local output_file=$1
  # The inner timeout terminates validator-engine-console inside the container,
  # so a timed-out sample cannot overlap the next query. The slightly longer
  # outer timeout is only a guard against a stuck Docker client.
  timeout --signal=TERM --kill-after=1s "${actor_stats_host_guard_seconds}s" \
    docker exec genesis sh -c '
      config=/var/ton-work/db/config.json
      internal_ip=$(hostname -I)
      internal_ip=${internal_ip%% *}
      control_port=$(jq -r ".control[0].port // empty" "$config")
      test -n "$internal_ip" && test -n "$control_port"
      exec timeout --signal=TERM --kill-after=1s "$1" validator-engine-console \
        -k /var/ton-work/db/client \
        -p /var/ton-work/db/server.pub \
        -a "$internal_ip:$control_port" \
        -c get-actor-stats
    ' sh "${actor_stats_timeout_seconds}s" \
    >"$output_file" 2>>"$result_dir/validator-actor-stats.stderr.log"
}

capture_validator_actor_stats_record() {
  local raw_file=$1 record_file=$2 phase=$3 sequence=$4
  local started_at finished_at started_ms finished_ms duration_seconds exit_code output_bytes
  local target_epoch_ms=${5:-null} target_offset_seconds=null
  local actor_types='{"overlay_impl":null,"decryptor_async":null}'
  local overlay_impl=null decryptor_async=null
  started_at=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  started_ms=$(date +%s%3N)
  printf '[%s] phase=%s sequence=%s\n' "$started_at" "$phase" "$sequence" \
    >>"$result_dir/validator-actor-stats.stderr.log"
  if capture_validator_actor_stats_raw "$raw_file"; then
    exit_code=0
  else
    exit_code=$?
  fi
  finished_at=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  finished_ms=$(date +%s%3N)
  duration_seconds=$(awk -v start="$started_ms" -v finish="$finished_ms" \
    'BEGIN { printf "%.3f", (finish - start) / 1000 }')
  if [[ $target_epoch_ms =~ ^[0-9]+$ ]]; then
    target_offset_seconds=$(awk -v start="$started_ms" -v target="$target_epoch_ms" \
      'BEGIN { printf "%.3f", (start - target) / 1000 }')
  else
    target_epoch_ms=null
  fi
  output_bytes=$(wc -c <"$raw_file" 2>/dev/null || echo 0)
  if (( exit_code == 0 )); then
    actor_types=$(jq -L "$benchmark_jq_dir" -Rs '
      include "native-benchmark-lib";
      validator_actor_stats_actor_types
    ' "$raw_file" 2>/dev/null || printf '{"overlay_impl":null,"decryptor_async":null}\n')
    overlay_impl=$(jq -c '
      if (.overlay_impl | type) == "object" and .overlay_impl.actor_type != null
      then .overlay_impl else null end
    ' <<<"$actor_types" 2>/dev/null || echo null)
    decryptor_async=$(jq -c '
      if (.decryptor_async | type) == "object" and .decryptor_async.actor_type != null
      then .decryptor_async else null end
    ' <<<"$actor_types" 2>/dev/null || echo null)
  fi
  jq -cn \
    --arg schema native-benchmark-validator-actor-stats-v1 \
    --arg phase "$phase" \
    --argjson sequence "$sequence" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --argjson started_at_epoch_ms "$started_ms" \
    --argjson finished_at_epoch_ms "$finished_ms" \
    --argjson command_duration_seconds "$duration_seconds" \
    --argjson command_timeout_seconds "$actor_stats_timeout_seconds" \
    --argjson command_exit_code "$exit_code" \
    --argjson output_bytes "$output_bytes" \
    --argjson target_epoch_ms "$target_epoch_ms" \
    --argjson target_offset_seconds "$target_offset_seconds" \
    --argjson overlay_impl "$overlay_impl" \
    --argjson decryptor_async "$decryptor_async" \
    '{$schema,$phase,$sequence,$started_at,$finished_at,$started_at_epoch_ms,
      $finished_at_epoch_ms,$command_duration_seconds,$command_timeout_seconds,
      $command_exit_code,$output_bytes,$target_epoch_ms,$target_offset_seconds,
      timed_out:($command_exit_code == 124 or $command_exit_code == 137),
      query_completed:($command_exit_code == 0),
      parsed:(($overlay_impl != null) or ($decryptor_async != null)),
      parsed_overlay_impl:($overlay_impl != null),
      parsed_decryptor_async:($decryptor_async != null),
      $overlay_impl,$decryptor_async}' >"$record_file"
}

read_generator_measure_end_epoch_ms() {
  docker logs --tail 100 "$container_name" 2>/dev/null | jq -Rsr '
    [split("\n")[] | fromjson? |
     select(.schema == "native-load-v2" and (.measure_end_unix_ms // null) != null)] |
    (last.measure_end_unix_ms // empty)
  ' 2>/dev/null || true
}

read_actor_stats_generator_container_state() {
  local state
  if state=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null); then
    case "$state" in
      created|running|paused|restarting|removing|exited|dead)
        printf '%s\n' "$state"
        ;;
      *)
        printf 'unknown\n'
        ;;
    esac
  else
    # A replacement container may be briefly absent by name, and a Docker
    # client call may fail transiently. Neither observation proves the load
    # generator stopped.
    printf 'unknown\n'
  fi
}

collect_validator_actor_stats() {
  local sequence=0 sample_raw sample_record now_ms next_periodic_ms next_discovery_ms
  local interval_ms timeout_ms measure_end_ms= measure_end_captured=0 wake_ms sleep_seconds
  local container_state container_action previous_state= startup_deadline_ms
  sample_raw=$result_dir/.validator-actor-stats-sample.txt
  sample_record=$result_dir/.validator-actor-stats-sample.json
  interval_ms=$(awk -v seconds="$actor_stats_sample_seconds" \
    'BEGIN { printf "%.0f", seconds * 1000 }')
  timeout_ms=$(awk -v seconds="$actor_stats_timeout_seconds" \
    'BEGIN { printf "%.0f", seconds * 1000 }')

  # `compose up -d` and the first background inspection are not atomic. Wait
  # for an explicit running state rather than using a false/failed inspection
  # as the loop condition. A terminal state before startup is a real early
  # generator exit; the deadline only protects the wrapper from an unavailable
  # Docker daemon or a container that remains stuck in a transitional state.
  now_ms=$(date +%s%3N)
  startup_deadline_ms=$((now_ms + 60000))
  while :; do
    container_state=$(read_actor_stats_generator_container_state)
    container_action=$(actor_stats_container_action "$container_state")
    if [[ $container_state != "$previous_state" ]]; then
      printf '[%s] phase=collector event=startup_state state=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$container_state" \
        >>"$result_dir/validator-actor-stats.stderr.log"
      previous_state=$container_state
    fi
    case "$container_action" in
      sample)
        break
        ;;
      stop)
        printf '[%s] phase=collector event=stopped_before_running state=%s\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$container_state" \
          >>"$result_dir/validator-actor-stats.stderr.log"
        rm -f -- "$sample_raw" "$sample_record"
        return 0
        ;;
    esac
    now_ms=$(date +%s%3N)
    if (( now_ms >= startup_deadline_ms )); then
      printf '[%s] phase=collector event=startup_wait_timeout state=%s timeout_seconds=60\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$container_state" \
        >>"$result_dir/validator-actor-stats.stderr.log"
      rm -f -- "$sample_raw" "$sample_record"
      return 0
    fi
    sleep 0.1
  done

  printf '[%s] phase=collector event=running_observed\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
    >>"$result_dir/validator-actor-stats.stderr.log"
  now_ms=$(date +%s%3N)
  next_periodic_ms=$((now_ms + interval_ms))
  next_discovery_ms=$now_ms
  while :; do
    container_state=$(read_actor_stats_generator_container_state)
    container_action=$(actor_stats_container_action "$container_state")
    case "$container_action" in
      stop)
        break
        ;;
      wait)
        # Once running has been observed, an inspection failure, pause, or
        # restart is not evidence of termination. Keep one serialized
        # collector alive until Docker reports an actual terminal state.
        sleep 0.25
        continue
        ;;
    esac

    now_ms=$(date +%s%3N)
    if [[ -z $measure_end_ms ]] && (( now_ms >= next_discovery_ms )); then
      measure_end_ms=$(read_generator_measure_end_epoch_ms)
      if ! [[ $measure_end_ms =~ ^[0-9]+$ ]]; then
        measure_end_ms=
      fi
      next_discovery_ms=$((now_ms + 5000))
    fi

    if [[ -n $measure_end_ms ]] && (( measure_end_captured == 0 && now_ms >= measure_end_ms )); then
      sequence=$((sequence + 1))
      capture_validator_actor_stats_record \
        "$sample_raw" "$sample_record" measure_end "$sequence" "$measure_end_ms"
      jq -c . "$sample_record" >>"$validator_actor_stats_file"
      measure_end_captured=1
      now_ms=$(date +%s%3N)
      next_periodic_ms=$((now_ms + interval_ms))
    elif (( now_ms >= next_periodic_ms )); then
      # Do not start an ordinary sample when the scheduled measure-end query is
      # less than one command-timeout away; one serialized measure-end sample
      # is both cheaper and more precisely aligned.
      if [[ -n $measure_end_ms ]] && (( measure_end_captured == 0 &&
           measure_end_ms > now_ms && measure_end_ms - now_ms <= timeout_ms )); then
        next_periodic_ms=$measure_end_ms
      else
        sequence=$((sequence + 1))
        capture_validator_actor_stats_record \
          "$sample_raw" "$sample_record" periodic "$sequence"
        jq -c . "$sample_record" >>"$validator_actor_stats_file"
        now_ms=$(date +%s%3N)
        next_periodic_ms=$((now_ms + interval_ms))
      fi
    fi

    now_ms=$(date +%s%3N)
    wake_ms=$((now_ms + 2000))
    if (( next_periodic_ms < wake_ms )); then
      wake_ms=$next_periodic_ms
    fi
    if [[ -z $measure_end_ms ]] && (( next_discovery_ms < wake_ms )); then
      wake_ms=$next_discovery_ms
    elif [[ -n $measure_end_ms ]] && (( measure_end_captured == 0 && measure_end_ms < wake_ms )); then
      wake_ms=$measure_end_ms
    fi
    sleep_seconds=$(actor_stats_sleep_seconds "$now_ms" "$wake_ms")
    container_state=$(read_actor_stats_generator_container_state)
    container_action=$(actor_stats_container_action "$container_state")
    case "$container_action" in
      sample) sleep "$sleep_seconds" ;;
      stop) break ;;
      wait) sleep 0.25 ;;
    esac
  done
  rm -f -- "$sample_raw" "$sample_record"
}

parse_validator_stat() {
  local input_file=$1 stat_name=$2 line
  line=$(grep -F "$stat_name" "$input_file" 2>/dev/null | tail -n 1 || true)
  if [[ -z $line ]]; then
    printf '{}\n'
    return
  fi
  awk '
    BEGIN { printf "{"; separator = "" }
    {
      for (i = 1; i <= NF; ++i) {
        token = $i
        gsub(/[,;]/, "", token)
        count = split(token, parts, ":")
        if (count == 2 && parts[1] ~ /^[A-Za-z_][A-Za-z0-9_]*$/ &&
            parts[2] ~ /^[0-9]+([.][0-9]+)?$/) {
          printf "%s\"%s\":%s", separator, parts[1], parts[2]
          separator = ","
        }
      }
    }
    END { print "}" }
  ' <<<"$line"
}

collect_host_stats() {
  local label total idle iowait delta_total delta_idle delta_iowait cpu_percent iowait_percent
  local mem_total_kib mem_available_kib per_cpu_file per_cpu_json
  declare -A previous_total=() previous_idle=() previous_iowait=()
  while read -r label total idle iowait; do
    previous_total[$label]=$total
    previous_idle[$label]=$idle
    previous_iowait[$label]=$iowait
  done < <(awk '/^cpu[0-9]* / {
    total = 0
    for (i = 2; i <= NF; i++) total += $i
    printf "%s %.0f %.0f %.0f\n", $1, total, $5 + $6, $6
  }' /proc/stat)
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sleep "$host_sample_seconds"
    per_cpu_file=$(mktemp "${TMPDIR:-/tmp}/native-benchmark-cpu.XXXXXX")
    cpu_percent=0
    iowait_percent=0
    while read -r label total idle iowait; do
      delta_total=$((total - ${previous_total[$label]:-$total}))
      delta_idle=$((idle - ${previous_idle[$label]:-$idle}))
      delta_iowait=$((iowait - ${previous_iowait[$label]:-$iowait}))
      printf '%s\t%s\t%s\t%s\n' "$label" "$delta_total" "$delta_idle" "$delta_iowait" \
        >>"$per_cpu_file"
      previous_total[$label]=$total
      previous_idle[$label]=$idle
      previous_iowait[$label]=$iowait
    done < <(awk '/^cpu[0-9]* / {
      total = 0
      for (i = 2; i <= NF; i++) total += $i
      printf "%s %.0f %.0f %.0f\n", $1, total, $5 + $6, $6
    }' /proc/stat)
    read -r cpu_percent iowait_percent < <(awk -F '\t' '$1 == "cpu" {
      if ($2 > 0) printf "%.3f %.3f\n", 100 * ($2 - $3) / $2, 100 * $4 / $2;
      else print "0 0"; exit
    }' "$per_cpu_file")
    per_cpu_json=$(jq -Rsc '
      [split("\n")[] | select(length > 0) | split("\t") |
       select(.[0] != "cpu") |
       {cpu:(.[0] | ltrimstr("cpu") | tonumber),
        cpu_percent:(if (.[1] | tonumber) > 0
                     then 100 * ((.[1] | tonumber) - (.[2] | tonumber)) / (.[1] | tonumber)
                     else 0 end),
        iowait_percent:(if (.[1] | tonumber) > 0
                        then 100 * (.[3] | tonumber) / (.[1] | tonumber)
                        else 0 end)}]
    ' "$per_cpu_file")
    rm -f -- "$per_cpu_file"
    mem_total_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
    mem_available_kib=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    jq -cn \
      --arg sampled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson sampled_at_epoch "$(date +%s)" \
      --argjson cpu_percent "$cpu_percent" \
      --argjson iowait_percent "$iowait_percent" \
      --argjson memory_used_bytes "$(((mem_total_kib - mem_available_kib) * 1024))" \
      --argjson memory_total_bytes "$((mem_total_kib * 1024))" \
      --arg load_average "$(cut -d' ' -f1-3 /proc/loadavg)" \
      --arg cpu_pressure "$(read_flat_file /proc/pressure/cpu)" \
      --arg io_pressure "$(read_flat_file /proc/pressure/io)" \
      --arg memory_pressure "$(read_flat_file /proc/pressure/memory)" \
      --argjson per_cpu "$per_cpu_json" \
      '{schema:"native-benchmark-host-resource-v2",$sampled_at,$sampled_at_epoch,
        $cpu_percent,$iowait_percent,$memory_used_bytes,$memory_total_bytes,
        $load_average,$cpu_pressure,$io_pressure,$memory_pressure,$per_cpu}' \
      >>"$host_stats_file"
  done
}

read_cgroup_value() {
  local file=$1 key=$2
  if [[ -r $file ]]; then
    awk -v key="$key" '$1 == key {print $2; found=1; exit} END {if (!found) print 0}' "$file"
  else
    echo 0
  fi
}

read_numeric_file() {
  local file=$1 value
  if [[ -r $file ]]; then
    read -r value <"$file" || value=0
    [[ $value =~ ^[0-9]+$ ]] || value=0
    echo "$value"
  else
    echo 0
  fi
}

read_flat_file() {
  local file=$1 value
  if [[ -r $file ]]; then
    value=$(<"$file")
    printf '%s' "${value//$'\n'/;}"
  fi
}

collect_cgroup_and_device_stats() {
  local sampled_at sampled_at_epoch name pid relative cgroup_dir cpu_stat memory_events
  local io_values device stat_file sector_size
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sampled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sampled_at_epoch=$(date +%s)
    for name in genesis "$container_name" session-stats; do
      pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || echo 0)
      [[ $pid =~ ^[0-9]+$ ]] || pid=0
      if (( pid <= 0 )) || [[ ! -r /proc/$pid/cgroup ]]; then
        continue
      fi
      relative=$(awk -F: '$1 == "0" {print $3; exit}' "/proc/$pid/cgroup")
      cgroup_dir=/sys/fs/cgroup$relative
      [[ -r $cgroup_dir/cpu.stat ]] || continue
      cpu_stat=$cgroup_dir/cpu.stat
      memory_events=$cgroup_dir/memory.events
      io_values=$(awk '
        { for (i = 2; i <= NF; ++i) {
            split($i, pair, "=")
            if (pair[1] == "rbytes") read_bytes += pair[2]
            else if (pair[1] == "wbytes") write_bytes += pair[2]
            else if (pair[1] == "rios") read_ios += pair[2]
            else if (pair[1] == "wios") write_ios += pair[2]
          }
        }
        END {printf "%.0f %.0f %.0f %.0f\n", read_bytes, write_bytes, read_ios, write_ios}
      ' "$cgroup_dir/io.stat" 2>/dev/null || echo '0 0 0 0')
      read -r cgroup_read_bytes cgroup_write_bytes cgroup_read_ios cgroup_write_ios <<<"$io_values"
      jq -cn \
        --arg schema native-benchmark-cgroup-resource-v1 \
        --arg sampled_at "$sampled_at" \
        --argjson sampled_at_epoch "$sampled_at_epoch" \
        --arg container "$name" \
        --arg cgroup_path "$relative" \
        --arg cpuset_cpus_effective "$(read_flat_file "$cgroup_dir/cpuset.cpus.effective")" \
        --arg cpu_max "$(read_flat_file "$cgroup_dir/cpu.max")" \
        --arg memory_max "$(read_flat_file "$cgroup_dir/memory.max")" \
        --argjson pid "$pid" \
        --argjson cpu_usage_usec "$(read_cgroup_value "$cpu_stat" usage_usec)" \
        --argjson cpu_user_usec "$(read_cgroup_value "$cpu_stat" user_usec)" \
        --argjson cpu_system_usec "$(read_cgroup_value "$cpu_stat" system_usec)" \
        --argjson cpu_nr_periods "$(read_cgroup_value "$cpu_stat" nr_periods)" \
        --argjson cpu_nr_throttled "$(read_cgroup_value "$cpu_stat" nr_throttled)" \
        --argjson cpu_throttled_usec "$(read_cgroup_value "$cpu_stat" throttled_usec)" \
        --argjson memory_current "$(read_numeric_file "$cgroup_dir/memory.current")" \
        --argjson memory_peak "$(read_numeric_file "$cgroup_dir/memory.peak")" \
        --argjson memory_oom "$(read_cgroup_value "$memory_events" oom)" \
        --argjson memory_oom_kill "$(read_cgroup_value "$memory_events" oom_kill)" \
        --argjson io_read_bytes "$cgroup_read_bytes" \
        --argjson io_write_bytes "$cgroup_write_bytes" \
        --argjson io_read_operations "$cgroup_read_ios" \
        --argjson io_write_operations "$cgroup_write_ios" \
        --arg cpu_pressure "$(read_flat_file "$cgroup_dir/cpu.pressure")" \
        --arg io_pressure "$(read_flat_file "$cgroup_dir/io.pressure")" \
        --arg memory_pressure "$(read_flat_file "$cgroup_dir/memory.pressure")" \
        '{$schema,$sampled_at,$sampled_at_epoch,$container,$pid,$cgroup_path,
          $cpuset_cpus_effective,$cpu_max,$memory_max,
          $cpu_usage_usec,$cpu_user_usec,$cpu_system_usec,$cpu_nr_periods,
          $cpu_nr_throttled,$cpu_throttled_usec,$memory_current,$memory_peak,
          $memory_oom,$memory_oom_kill,$io_read_bytes,$io_write_bytes,
          $io_read_operations,$io_write_operations,$cpu_pressure,$io_pressure,
          $memory_pressure}' >>"$cgroup_stats_file"
    done
    if command -v lsblk >/dev/null 2>&1; then
      while read -r device; do
        stat_file=/sys/block/$device/stat
        [[ -r $stat_file ]] || continue
        sector_size=$(cat "/sys/block/$device/queue/hw_sector_size" 2>/dev/null || echo 512)
        read -r read_ios read_merges read_sectors read_ticks write_ios write_merges \
          write_sectors write_ticks in_flight io_ticks weighted_io_ticks _ <"$stat_file"
        jq -cn \
          --arg schema native-benchmark-device-resource-v1 \
          --arg sampled_at "$sampled_at" \
          --argjson sampled_at_epoch "$sampled_at_epoch" \
          --arg device "$device" \
          --argjson sector_size_bytes "$sector_size" \
          --argjson read_operations "$read_ios" \
          --argjson read_bytes "$((read_sectors * sector_size))" \
          --argjson read_time_ms "$read_ticks" \
          --argjson write_operations "$write_ios" \
          --argjson write_bytes "$((write_sectors * sector_size))" \
          --argjson write_time_ms "$write_ticks" \
          --argjson in_flight "$in_flight" \
          --argjson io_time_ms "$io_ticks" \
          --argjson weighted_io_time_ms "$weighted_io_ticks" \
          '{$schema,$sampled_at,$sampled_at_epoch,$device,$sector_size_bytes,
            $read_operations,$read_bytes,$read_time_ms,$write_operations,
            $write_bytes,$write_time_ms,$in_flight,$io_time_ms,
            $weighted_io_time_ms}' >>"$device_stats_file"
      done < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')
    fi
    sleep "$detail_sample_seconds"
  done
}

collect_thread_stats() {
  local clock_ticks sample_ns previous_sample_ns=0 interval_ns name pid task_dir tid stat_line stat_tail ticks processor comm
  local key delta_ticks thread_file threads_json total_threads
  local -a stat_fields
  declare -A previous_ticks=()
  clock_ticks=$(getconf CLK_TCK)
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sample_ns=$(date +%s%N)
    interval_ns=$((previous_sample_ns > 0 ? sample_ns - previous_sample_ns : 0))
    for name in genesis "$container_name" session-stats; do
      pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null || echo 0)
      [[ $pid =~ ^[0-9]+$ ]] || pid=0
      (( pid > 0 )) || continue
      thread_file=$(mktemp "${TMPDIR:-/tmp}/native-benchmark-threads.XXXXXX")
      total_threads=0
      for task_dir in /proc/$pid/task/[0-9]*; do
        [[ -r $task_dir/stat ]] || continue
        tid=${task_dir##*/}
        read -r stat_line <"$task_dir/stat" || stat_line=
        stat_tail=${stat_line##*) }
        [[ -n $stat_tail ]] || continue
        read -ra stat_fields <<<"$stat_tail"
        ((${#stat_fields[@]} >= 37)) || continue
        ticks=$((${stat_fields[11]} + ${stat_fields[12]}))
        processor=${stat_fields[36]}
        key=$pid:$tid
        ((total_threads += 1))
        if [[ -n ${previous_ticks[$key]+present} && $previous_sample_ns -gt 0 ]]; then
          delta_ticks=$((ticks - previous_ticks[$key]))
          read -r comm <"$task_dir/comm" || comm=unknown
          comm=${comm//$'\t'/ }
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$delta_ticks" "$name" "$pid" "$tid" \
            "${processor:-0}" "$comm" >>"$thread_file"
        fi
        previous_ticks[$key]=$ticks
      done
      threads_json=$(sort -t $'\t' -k1,1nr "$thread_file" | sed -n "1,${max_threads_per_container}p" |
        jq -Rsc --argjson clock_ticks "$clock_ticks" --argjson interval_ns "$interval_ns" '
          [split("\n")[] | select(length > 0) | split("\t") |
           {container:.[1],pid:(.[2] | tonumber),tid:(.[3] | tonumber),
            thread_name:.[5],processor:(.[4] | tonumber),
            cpu_percent:(if $interval_ns > 0 and (.[0] | tonumber) >= 0
                         then 100 * (.[0] | tonumber) * 1000000000 /
                              ($clock_ticks * $interval_ns)
                         else 0 end)}]
        ')
      rm -f -- "$thread_file"
      jq -cn \
        --arg schema native-benchmark-thread-resource-v1 \
        --arg sampled_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson sampled_at_epoch "$(date +%s)" \
        --arg container "$name" --argjson pid "$pid" \
        --argjson total_threads "$total_threads" \
        --argjson retained_threads "$max_threads_per_container" \
        --argjson interval_ns "$interval_ns" \
        --argjson threads "$threads_json" \
        '{$schema,$sampled_at,$sampled_at_epoch,$container,$pid,$total_threads,
          retained_thread_limit:$retained_threads,
          sample_interval_seconds:($interval_ns / 1000000000),$threads}' \
        >>"$thread_stats_file"
    done
    previous_sample_ns=$sample_ns
    sleep "$thread_sample_seconds"
  done
}

collect_container_stats() {
  local sampled_at_epoch
  # Do not add another sleep here: `docker stats --no-stream` already takes a
  # counter interval. Repeating it yields roughly two-second portable samples.
  while docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; do
    sampled_at_epoch=$(date +%s)
    docker stats --no-stream --format '{{json .}}' \
      genesis "$container_name" session-stats 2>>"$result_dir/docker-stats.stderr.log" |
      awk -v sampled_at_epoch="$sampled_at_epoch" '{
        sub(/}$/, ",\"schema\":\"native-benchmark-container-resource-v1\",\"sampled_at_epoch\":" sampled_at_epoch "}")
        print
      }' >>"$container_stats_file"
  done
}

images_prebuilt=${BENCHMARK_IMAGES_PREBUILT:-0}
if [[ $images_prebuilt != 0 && $images_prebuilt != 1 ]]; then
  echo "BENCHMARK_IMAGES_PREBUILT must be 0 or 1" >&2
  exit 2
fi
compose_build_args=(--build)
if [[ $images_prebuilt == 1 ]]; then
  # The guarded fresh-cycle runner builds both derived images before deleting
  # state. Avoid hashing/building the same contexts three more times after the
  # destructive boundary; Compose still verifies that the tagged images exist
  # when it creates the containers below.
  compose_build_args=()
  echo "Using derived images prebuilt by the guarded fresh-cycle runner"
  for prebuilt_service in genesis "$container_name"; do
    prebuilt_image=$("${compose[@]}" --profile native-load-generator config --images "$prebuilt_service" | tail -n 1)
    prebuilt_revision=$(docker image inspect -f \
      '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
      "$prebuilt_image" 2>/dev/null || true)
    if [[ -z $prebuilt_image || $prebuilt_revision != "$ton_base_revision" ]]; then
      echo "prebuilt $prebuilt_service image is missing or does not match TON revision $ton_base_revision" >&2
      exit 2
    fi
  done
else
  echo "Building the genesis image from local $ton_base_image before deciding reuse"
  "${compose[@]}" build genesis
fi

genesis_health=$(docker inspect -f \
  '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
  genesis 2>/dev/null || true)
recreate_genesis=${BENCHMARK_RECREATE_GENESIS:-0}
strict_genesis_reuse=${BENCHMARK_STRICT_GENESIS_REUSE:-0}
genesis_matches=false
if [[ $genesis_health == "true healthy" && $recreate_genesis != 1 ]]; then
  desired_genesis_hash=$("${compose[@]}" config --hash genesis | awk '$1 == "genesis" {print $2}')
  running_genesis_hash=$(docker inspect -f \
    '{{index .Config.Labels "com.docker.compose.config-hash"}}' genesis 2>/dev/null || true)
  desired_genesis_image=$("${compose[@]}" config --images genesis | tail -n 1)
  desired_genesis_image_id=$(docker image inspect -f '{{.Id}}' "$desired_genesis_image" 2>/dev/null || true)
  running_genesis_image_id=$(docker inspect -f '{{.Image}}' genesis 2>/dev/null || true)
  if [[ -n $desired_genesis_hash && $running_genesis_hash == "$desired_genesis_hash" &&
        -n $desired_genesis_image_id && $running_genesis_image_id == "$desired_genesis_image_id" ]]; then
    genesis_matches=true
  elif [[ $strict_genesis_reuse == 1 ]]; then
    echo "healthy genesis does not match $env_file or the current local image" >&2
    echo "strict reuse is enabled; unset BENCHMARK_STRICT_GENESIS_REUSE to reconcile the container" >&2
    exit 2
  else
    echo "Healthy genesis does not match $env_file or the current local image." >&2
    echo "Recreating the container with matching runtime configuration; named/bind volumes are preserved." >&2
  fi
fi

if [[ $genesis_matches == true ]]; then
  echo "Reusing the matching, already-healthy genesis container; starting session-stats only"
  "${compose[@]}" --profile session-stats up -d "${compose_build_args[@]}" --no-deps session-stats
else
  echo "Starting/recreating genesis and session-stats with $env_file"
  "${compose[@]}" --profile session-stats up -d "${compose_build_args[@]}" --force-recreate genesis session-stats
fi

if [[ $images_prebuilt != 1 ]]; then
  echo "Building the native-load-generator image before opening the benchmark window"
  "${compose[@]}" --profile native-load-generator build "$container_name"
fi

genesis_health=$(docker inspect -f \
  '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
  genesis 2>/dev/null || true)
if [[ $genesis_health != "true healthy" ]]; then
  echo "genesis must be running and healthy before benchmark validator controls are applied" >&2
  exit 2
fi
if ! apply_ext_messages_broadcast_setting; then
  if [[ $interrupted -eq 1 ]]; then
    exit 130
  fi
  exit 2
fi

# Snapshot cumulative ExtMessagePool counters immediately around the load.
# The delta exposes whether the pool scanned non-executable messages, formed
# the intended per-source runs, or repeatedly delayed/reactivated nonce heads.
if ! capture_validator_stats "$validator_stats_before_file"; then
  : >"$validator_stats_before_file"
fi

# The validator's session-stats log contains one structured record per
# collation and validation query. Remember the current end only after the image
# build, so pull/compile time cannot contaminate the benchmark distributions.
validator_session_stats_start_line=$(docker exec genesis sh -c \
  'if [ -f /var/ton-work/db/log.session-stats ]; then wc -l < /var/ton-work/db/log.session-stats; else echo 0; fi' \
  2>/dev/null || echo 0)
if ! [[ $validator_session_stats_start_line =~ ^[0-9]+$ ]]; then
  validator_session_stats_start_line=0
fi

capture_validator_actor_stats_record \
  "$validator_actor_stats_pre_load_file" "$validator_actor_stats_pre_load_metadata_file" pre_load 0
echo "Starting a fresh native-load-generator container"
"${compose[@]}" --profile native-load-generator up -d --force-recreate --no-deps "$container_name"

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
started_epoch=$(date +%s)

collect_container_stats &
collector_pids+=("$!")
collect_host_stats &
collector_pids+=("$!")
collect_cgroup_and_device_stats &
collector_pids+=("$!")
collect_thread_stats &
collector_pids+=("$!")
collect_validator_actor_stats &
actor_stats_collector_pid=$!
docker logs --follow "$container_name" &
collector_pids+=("$!")

echo "Native load is running; live generator JSON follows"

set +e
generator_container_exit_code=$(docker wait "$container_name" 2>"$result_dir/docker-wait.stderr.log")
wait_status=$?
set -e
if [[ $wait_status -ne 0 || ! $generator_container_exit_code =~ ^[0-9]+$ ]]; then
  generator_container_exit_code=125
fi
benchmark_exit_code=$generator_container_exit_code
if [[ $interrupted -eq 1 ]]; then
  benchmark_exit_code=130
fi

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
finished_epoch=$(date +%s)
stop_collectors
wait_actor_stats_collector
docker logs "$container_name" >"$generator_log_file" 2>&1 || true
capture_validator_actor_stats_record \
  "$validator_actor_stats_final_file" "$validator_actor_stats_final_metadata_file" post_drain 0
jq -L "$benchmark_jq_dir" -s \
  --slurpfile pre_load "$validator_actor_stats_pre_load_metadata_file" \
  --slurpfile final "$validator_actor_stats_final_metadata_file" \
  --argjson sample_interval_seconds "$actor_stats_sample_seconds" \
  --argjson command_timeout_seconds "$actor_stats_timeout_seconds" \
  --argjson host_guard_seconds "$actor_stats_host_guard_seconds" \
  --argjson load_window_seconds "$((finished_epoch - started_epoch))" \
  --arg pre_load_raw_artifact "$(basename "$validator_actor_stats_pre_load_file")" \
  --arg final_raw_artifact "$(basename "$validator_actor_stats_final_file")" '
  include "native-benchmark-lib";
  validator_actor_stats_summary(.; $pre_load[0]; $final[0]; {
    sample_interval_seconds:$sample_interval_seconds,
    command_timeout_seconds:$command_timeout_seconds,
    command_kill_grace_seconds:1,
    host_guard_seconds:$host_guard_seconds,
    load_window_seconds:$load_window_seconds,
    pre_load_raw_artifact:$pre_load_raw_artifact,
    final_raw_artifact:$final_raw_artifact,
    cadence_semantics:"serialized start-to-start cadence; a slow query consumes its interval and calls never overlap"
  })
' "$validator_actor_stats_file" >"$validator_actor_stats_summary_file"
if ! capture_validator_stats "$validator_stats_after_file"; then
  : >"$validator_stats_after_file"
fi
if [[ $ext_messages_broadcast_requested == true ]]; then
  if ! capture_ext_messages_broadcast_state post-load \
    "$ext_messages_broadcast_post_load_record_file" ||
     ! ext_messages_broadcast_state_matches "$ext_messages_broadcast_post_load_record_file" \
       "$ext_messages_broadcast_desired_disabled"; then
    echo "validator external-message broadcast setting changed before post-load capture" >&2
    if (( benchmark_exit_code == 0 )); then
      benchmark_exit_code=4
    fi
  fi
  write_ext_messages_broadcast_provenance
  if ! restore_ext_messages_broadcast_setting; then
    echo "failed to restore and verify validator external-message broadcasting" >&2
    if (( benchmark_exit_code == 0 )); then
      benchmark_exit_code=4
    fi
    # Retry immediately so a failed first cleanup does not leave the persistent
    # flag changed throughout report generation. The EXIT handler remains the
    # final fallback for this and every earlier failure path.
    if ! restore_ext_messages_broadcast_setting; then
      exit "$benchmark_exit_code"
    fi
  fi
fi
docker logs --since "$started_at" genesis 2>&1 |
  awk '/consensus_schedule_summary/' >"$validator_scheduling_log_file" || true
jq -Rsc '
  def kv_fields:
    [split(" ")[] | select(contains("=")) | split("=") |
      select(length == 2) |
      .[0] as $key | .[1] as $value |
      {($key): (($value | tonumber?) // $value)}] | add // {};
  [split("\n")[] | select(contains("consensus_schedule_summary")) | kv_fields] as $rows |
  {
    semantics:"cumulative BlockProducer/Simplex scheduling snapshots filtered from genesis logs; zero records means the configured validator verbosity suppressed INFO scheduling summaries, while validator-pipeline-summary still contains structured consensus events",
    records:($rows | length),
    last_by_component:($rows | sort_by(.chain,.component) | group_by(.chain,.component) |
      map({chain:.[0].chain,component:.[0].component,last:.[-1]}))
  }
' "$validator_scheduling_log_file" >"$validator_scheduling_log_summary_file"

scheduler_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_native_scheduler")
scheduler_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_native_scheduler")
batch_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_batch_admission")
batch_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_batch_admission")
transport_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_native_transport")
transport_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_native_transport")
reconciliation_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_native_reconciliation")
reconciliation_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_native_reconciliation")
pending_before=$(parse_validator_stat "$validator_stats_before_file" "total.ext_msg_native_pending")
pending_after=$(parse_validator_stat "$validator_stats_after_file" "total.ext_msg_native_pending")
jq -L "$benchmark_jq_dir" -n \
  --argjson scheduler_before "$scheduler_before" \
  --argjson scheduler_after "$scheduler_after" \
  --argjson batch_before "$batch_before" \
  --argjson batch_after "$batch_after" \
  --argjson transport_before "$transport_before" \
  --argjson transport_after "$transport_after" \
  --argjson reconciliation_before "$reconciliation_before" \
  --argjson reconciliation_after "$reconciliation_after" \
  --argjson pending_before "$pending_before" \
  --argjson pending_after "$pending_after" '
  include "native-benchmark-lib";
  def delta($before; $after; $exclude):
    reduce ($after | keys_unsorted[]) as $key ({};
      if ($exclude | index($key)) != null then .
      else .[$key] = (($after[$key] // 0) - ($before[$key] // 0))
      end);
  validator_pool_cleanup_acceptance($reconciliation_after; $pending_after) as $cleanup |
  native_transport_summary($transport_before; $transport_after) as $native_transport |
  {
    semantics:"validator-engine cumulative ExtMessagePool counters sampled immediately before and after generator execution; scheduler delta should show near one scanned message per selected message and source runs approaching the configured run target",
    scheduler:{
      capture_complete:(($scheduler_before | length) > 0 and ($scheduler_after | length) > 0),
      before:$scheduler_before,
      after:$scheduler_after,
      delta:delta($scheduler_before; $scheduler_after; ["max_run_size"]),
      observed_max_run_size:($scheduler_after.max_run_size // null)
    },
    batch_admission:{
      capture_complete:(($batch_before | length) > 0 and ($batch_after | length) > 0),
      before:$batch_before,
      after:$batch_after,
      delta:delta($batch_before; $batch_after; []),
      shard_state_cache:native_admission_shard_cache_summary($batch_before; $batch_after)
    },
    native_transport:$native_transport,
    canonical_reconciliation:{
      semantics:"local candidate acceptance only tracks source/nonce hints; irreversible native prefix cleanup is authorized by shard-client-confirmed masterchain-referenced account state",
      capture_complete:(($reconciliation_before | length) > 0 and ($reconciliation_after | length) > 0),
      clean_after:(($reconciliation_after | length) > 0 and (($reconciliation_after.pending_sources // -1) == 0)),
      before:$reconciliation_before,
      after:$reconciliation_after,
      delta:delta($reconciliation_before; $reconciliation_after; ["pending_sources","last_mc_seqno","last_shard_seqno"])
    },
    native_pending:{
      capture_complete:(($pending_before | length) > 0 and ($pending_after | length) > 0),
      clean_after:(($pending_after | length) > 0 and (($pending_after.messages // -1) == 0)),
      before:$pending_before,
      after:$pending_after
    },
    cleanup_acceptance:($cleanup + {
      semantics:"a usable run must capture validator cleanup telemetry, leave no locally accepted source awaiting canonical reconciliation, and leave no native message in the validator pool"
    })
  }
' >"$validator_pool_summary_file"

generator_measure_start=$(jq -Rs \
  '[split("\n")[] | fromjson? | select(.schema == "native-load-v2" and .final == true)] |
   (last as $final |
    if ($final.measure_start_unix_ms // null) != null
    then ($final.measure_start_unix_ms / 1000)
    else ($final.measure_start_unix_s // null)
    end)' "$generator_log_file")
generator_measure_end=$(jq -Rs \
  '[split("\n")[] | fromjson? | select(.schema == "native-load-v2" and .final == true)] |
   (last as $final |
    if ($final.measure_end_unix_ms // null) != null
    then ($final.measure_end_unix_ms / 1000)
    else ($final.measure_end_unix_s // null)
    end)' "$generator_log_file")

if ! jq -en --argjson start "$generator_measure_start" --argjson end "$generator_measure_end" \
  '$start != null and $end != null and $start < $end' >/dev/null; then
  echo "generator did not publish a valid measured-window boundary" >&2
  benchmark_exit_code=125
fi

validator_session_stats_first_line=$((validator_session_stats_start_line + 1))
if ! docker exec genesis sh -c \
  'file=/var/ton-work/db/log.session-stats; first=$1; old=$2
   if [ ! -f "$file" ]; then exit 0; fi
   current=$(wc -l < "$file")
   if [ "$current" -lt "$old" ]; then first=1; fi
   tail -n "+$first" "$file"' sh "$validator_session_stats_first_line" \
  "$validator_session_stats_start_line" >"$validator_session_stats_file" 2>/dev/null; then
  : >"$validator_session_stats_file"
fi

# Keep the raw JSONL for detailed inspection and publish robust distributions
# for the fields needed to classify the limiting stage.  The file is parsed as
# text so one partial final line cannot invalidate an otherwise complete run.
jq -L "$benchmark_jq_dir" -Rsc \
  --argjson measure_start "$generator_measure_start" \
  --argjson measure_end "$generator_measure_end" '
  include "native-benchmark-lib";
  def numeric:
    if type == "number" then .
    elif type == "string" then (tonumber? // null)
    else null end;
  def distribution:
    map(numeric) | map(select(. != null)) | sort as $v |
    if ($v | length) == 0 then
      {samples:0,avg:null,p50:null,p95:null,p99:null,max:null}
    else
      ($v | length) as $n |
      {samples:$n,
       avg:($v | add / $n),
       p50:$v[((($n - 1) * 0.50) | floor)],
       p95:$v[((($n - 1) * 0.95) | floor)],
       p99:$v[((($n - 1) * 0.99) | floor)],
       max:$v[-1]}
    end;
  def stage_distribution($rows; $name):
    [$rows[] |
      ((.work_time_real_stats? // "") |
       (capture("(?:^| )" + $name + "=(?<value>[-+0-9.eE]+)")? | .value) |
       tonumber?) |
      select(. != null)] |
    distribution;
  def native_work_counter_values($rows; $name):
    [$rows[] |
      ((.work_time_real_stats? // "") |
       (capture("(?:^| )" + $name + "=(?<value>(?:[-+0-9.eE]+|true|false))")? | .value) |
       stat_counter_value) |
      select(. != null)];
  def native_work_counter_sum($rows; $name):
    native_work_counter_values($rows; $name) | add // 0;
  def native_work_counter_max($rows; $name):
    native_work_counter_values($rows; $name) | max // 0;
  def native_work_counter_min_positive($rows; $name):
    native_work_counter_values($rows; $name) | map(select(. > 0)) | min // 0;
  def collated_summary($rows):
    ($rows | map(.block_stats.transactions? // 0) | add // 0) as $transfers |
    ($rows | map(.bytes? // 0) | add // 0) as $block_bytes |
    ($rows | map(.collated_data_bytes? // 0) | add // 0) as $collated_bytes |
    ($rows | map(.block_limits.bytes? // 0) | add // 0) as $estimated_bytes |
    {
      blocks:($rows | length),
      transfers:$transfers,
      avg_transfers_per_block:(if ($rows | length) > 0 then $transfers / ($rows | length) else null end),
      max_transfers_per_block:($rows | map(.block_stats.transactions? // 0) | max // null),
      total_actual_block_bytes:$block_bytes,
      total_collated_data_bytes:$collated_bytes,
      total_estimated_block_bytes:$estimated_bytes,
      actual_block_bytes_per_transfer:(if $transfers > 0 then $block_bytes / $transfers else null end),
      collated_data_bytes_per_transfer:(if $transfers > 0 then $collated_bytes / $transfers else null end),
      estimated_block_bytes_per_transfer:(if $transfers > 0 then $estimated_bytes / $transfers else null end),
      actual_block_bytes:($rows | map(.bytes?) | distribution),
      collated_data_bytes:($rows | map(.collated_data_bytes?) | distribution),
      estimated_block_bytes:($rows | map(.block_limits.bytes?) | distribution),
      estimator_gap_bytes:($rows | map(
        if (.bytes? | type) == "number" and (.block_limits.bytes? | type) == "number"
        then .bytes - .block_limits.bytes
        else null
        end
      ) | distribution),
      native_fast_path_counters:{
        invocations:native_work_counter_sum($rows; "native_fast_path_invocations"),
        microbatches:native_work_counter_sum($rows; "native_microbatches"),
        input:native_work_counter_sum($rows; "native_microbatch_input"),
        accepted:native_work_counter_sum($rows; "native_microbatch_accepted"),
        delayed:native_work_counter_sum($rows; "native_microbatch_delayed"),
        permanent:native_work_counter_sum($rows; "native_microbatch_permanent"),
        unique_accounts:native_work_counter_sum($rows; "native_microbatch_unique_accounts"),
        max_microbatch_input:native_work_counter_max($rows; "native_microbatch_max_input"),
        max_microbatch_unique_accounts:native_work_counter_max($rows; "native_microbatch_max_unique_accounts"),
        account_cells:native_work_counter_sum($rows; "native_account_cells_built"),
        staged_dict_sets:native_work_counter_sum($rows; "native_staged_dict_sets"),
        state_accounts_installed:native_work_counter_sum($rows; "native_state_accounts_installed"),
        checkpoint_base_snapshots:native_work_counter_sum(
          $rows; "native_stat_checkpoint_base_snapshots"
        ),
        checkpoint_rebuilds:native_work_counter_sum($rows; "native_stat_checkpoint_rebuilds"),
        checkpoint_coalescing:native_checkpoint_coalescing_summary($rows),
        fragment_refill_waits:native_work_counter_sum($rows; "native_fragment_refill_waits"),
        fragment_refill_timeouts:native_work_counter_sum($rows; "native_fragment_refill_timeouts"),
        fragment_refill_messages:native_work_counter_sum($rows; "native_fragment_refill_messages"),
        post_commit_idle_waits:native_work_counter_sum($rows; "native_post_commit_idle_waits"),
        post_commit_idle_timeouts:native_work_counter_sum($rows; "native_post_commit_idle_timeouts"),
        fragment_capacity_fills:native_work_counter_sum($rows; "native_fragment_capacity_fills"),
        hard_preflight_failures:native_work_counter_sum($rows; "native_hard_preflight_failures"),
        size_guard_deferrals:native_work_counter_sum($rows; "native_size_guard_deferrals"),
        size_guard_reserve_bytes:native_work_counter_max($rows; "native_size_guard_reserve_bytes"),
        size_guard_max_estimated_bytes:native_work_counter_max(
          $rows; "native_size_guard_max_estimated_bytes"
        ),
        size_guard_max_estimator_gap_bytes:native_work_counter_max(
          $rows; "native_size_guard_estimator_gap_bytes"
        ),
        size_guard_min_positive_serialized_margin_bytes:native_work_counter_min_positive(
          $rows; "native_size_guard_serialized_margin_bytes"
        ),
        size_guard_max_serialized_oversize_bytes:native_work_counter_max(
          $rows; "native_size_guard_serialized_oversize_bytes"
        ),
        canonical_roots_reused:native_work_counter_sum($rows; "native_canonical_root_reused"),
        canonical_accounts_reused:native_work_counter_sum($rows; "native_canonical_accounts_reused"),
        deadline_seals:native_work_counter_sum($rows; "native_deadline_seals"),
        deadline_deferred:native_work_counter_sum($rows; "native_deadline_deferred"),
        deadline_first_fragment_commits:native_work_counter_sum(
          $rows; "native_deadline_first_fragment_commits"
        )
      },
      total_time_s:($rows | map(.total_time?) | distribution),
      work_time_s:($rows | map(.work_time?) | distribution),
      cpu_work_time_s:($rows | map(.cpu_work_time?) | distribution),
      wait_externals_time_s:($rows | map(.wait_externals_time?) | distribution),
      external_wait_breakdown:collation_external_wait_summary($rows),
      stages_real_s:{
        preinit:stage_distribution($rows; "preinit"),
        native_prepare:stage_distribution($rows; "native_prepare"),
        native_execute:stage_distribution($rows; "native_execute"),
        native_commit:stage_distribution($rows; "native_commit"),
        native_account_cell_build:stage_distribution($rows; "native_account_cell_build"),
        native_staged_dict_set:stage_distribution($rows; "native_staged_dict_set"),
        native_stat_checkpoint_rebuild:stage_distribution($rows; "native_stat_checkpoint_rebuild"),
        native_proof_preflight:stage_distribution($rows; "native_proof_preflight"),
        native_state_install:stage_distribution($rows; "native_state_install"),
        native_canonical_dict_install:stage_distribution($rows; "native_canonical_dict_install"),
        native_batch_serialize:stage_distribution($rows; "native_batch_serialize"),
        final_storage_stat:stage_distribution($rows; "final_storage_stat"),
        combine_account_transactions:stage_distribution($rows; "combine_account_transactions"),
        create_shard_state:stage_distribution($rows; "create_shard_state"),
        create_state_merkle_update:stage_distribution($rows; "create_state_merkle_update"),
        create_block:stage_distribution($rows; "create_block"),
        create_collated_data:stage_distribution($rows; "create_collated_data"),
        create_block_candidate:stage_distribution($rows; "create_block_candidate")
      }
    };
  def validated_summary($rows):
    {
      blocks:($rows | length),
      accepted:($rows | map(select(.valid? == true)) | length),
      rejected:($rows | map(select(.valid? == false)) | length),
      total_time_s:($rows | map(.total_time?) | distribution),
      work_time_s:($rows | map(.work_time?) | distribution),
      actual_time_s:($rows | map(.actual_time?) | distribution),
      cpu_work_time_s:($rows | map(.cpu_work_time?) | distribution),
      actual_block_bytes:($rows | map(.bytes?) | distribution),
      collated_data_bytes:($rows | map(.collated_data_bytes?) | distribution),
      stages_real_s:{
        unpack_block_candidate:stage_distribution($rows; "unpack_block_candidate"),
        process_mc_state:stage_distribution($rows; "process_mc_state"),
        native_batch_replay:stage_distribution($rows; "native_batch_replay"),
        unpack_state:stage_distribution($rows; "unpack_state"),
        validate_block_tlb:stage_distribution($rows; "validate_block_tlb"),
        unpack_block_data:stage_distribution($rows; "unpack_block_data"),
        precheck_account_updates:stage_distribution($rows; "precheck_account_updates"),
        precheck_account_transactions:stage_distribution($rows; "precheck_account_transactions"),
        check_new_state:stage_distribution($rows; "check_new_state")
      }
    };
  def consensus_summary($rows):
    ($rows | map(.ts) | map(select(. != null)) | sort) as $timestamps |
    {
      events:($rows | length),
      first_event_unix_s:($timestamps[0] // null),
      last_event_unix_s:($timestamps[-1] // null),
      collate_started:([$rows[] | select(.event["@type"] == "consensus.stats.collateStarted")] | length),
      collate_finished:([$rows[] | select(.event["@type"] == "consensus.stats.collateFinished")] | length),
      collated_empty:([$rows[] | select(.event["@type"] == "consensus.stats.collatedEmpty")] | length),
      candidate_received:([$rows[] | select(.event["@type"] == "consensus.stats.candidateReceived")] | length),
      local_candidates:([$rows[] |
        select(.event["@type"] == "consensus.stats.candidateReceived" and .event.is_collator == true)] | length),
      validation_started:([$rows[] | select(.event["@type"] == "consensus.stats.validationStarted")] | length),
      validation_finished:([$rows[] | select(.event["@type"] == "consensus.stats.validationFinished")] | length),
      skip_votes:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.voted" and
               .event.vote["@type"] == "consensus.simplex.skipVote")] | length),
      skip_certificates:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.certObserved" and
               .event.vote["@type"] == "consensus.simplex.skipVote")] | length),
      notarize_votes:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.voted" and
               .event.vote["@type"] == "consensus.simplex.notarizeVote")] | length),
      finalize_votes:([$rows[] |
        select(.event["@type"] == "consensus.simplex.stats.voted" and
               .event.vote["@type"] == "consensus.simplex.finalizeVote")] | length)
    };
  [split("\n")[] | fromjson?] as $records |
  [$records[] | select(.block_stats? != null)] as $collated |
  [$records[] | select(.validated_at? != null)] as $validated |
  [$collated[] | select((.block_id.workchain? // .block_id.workchain_id? // -1) == 0)] as $wc_collated |
  [$collated[] | select((.block_id.workchain? // .block_id.workchain_id? // 0) == -1)] as $mc_collated |
  [$validated[] | select((.block_id.workchain? // .block_id.workchain_id? // -1) == 0)] as $wc_validated |
  [$validated[] | select((.block_id.workchain? // .block_id.workchain_id? // 0) == -1)] as $mc_validated |
  [$wc_collated[] |
    select($measure_start != null and $measure_end != null and
           (.collated_at? // -1) >= $measure_start and (.collated_at? // -1) < $measure_end)] as $measured_collated |
  [$wc_validated[] |
    select($measure_start != null and $measure_end != null and
           (.validated_at? // -1) >= $measure_start and (.validated_at? // -1) < $measure_end)] as $measured_validated |
  [$mc_collated[] |
    select($measure_start != null and $measure_end != null and
           (.collated_at? // -1) >= $measure_start and (.collated_at? // -1) < $measure_end)] as $measured_mc_collated |
  [$mc_validated[] |
    select($measure_start != null and $measure_end != null and
           (.validated_at? // -1) >= $measure_start and (.validated_at? // -1) < $measure_end)] as $measured_mc_validated |
  [$records[] | select(.["@type"] == "consensus.stats.events")] as $consensus_records |
  (reduce $consensus_records[] as $record ({};
    (($record.events | map(select(.event["@type"] == "consensus.stats.id")) | first? |
       .event.workchain?) //
     ($record.events |
       map(select(.event["@type"] == "consensus.stats.candidateReceived" and
                  .event.block["@type"] == "consensus.stats.block")) |
       first? | .event.block.id.workchain?)) as $workchain |
    if $workchain != null then .[$record.id] = $workchain else . end)) as $session_workchains |
  [$consensus_records[] as $record |
    $record.events[] |
    {session_id:$record.id,workchain:($session_workchains[$record.id] // null),ts:.ts,event:.event}] as $events |
  [$events[] | select(.workchain == 0)] as $bc_events |
  [$events[] | select(.workchain == -1)] as $mc_events |
  [$bc_events[] | select($measure_start != null and $measure_end != null and
                         .ts >= $measure_start and .ts < $measure_end)] as $measured_bc_events |
  [$mc_events[] | select($measure_start != null and $measure_end != null and
                         .ts >= $measure_start and .ts < $measure_end)] as $measured_mc_events |
  {
    semantics:"validator candidate session records captured directly from genesis; basechain transaction counts are native transfers for this isolated single-validator benchmark; proof-checked generator metrics remain authoritative for canonical selection",
    raw_records:($records | length),
    consensus_unmapped_events:([$events[] | select(.workchain == null)] | length),
    measured_window_unix_s:{start:$measure_start,end:$measure_end},
    all_run:{
      collated_basechain:collated_summary($wc_collated),
      validated_basechain:validated_summary($wc_validated),
      collated_masterchain:collated_summary($mc_collated),
      validated_masterchain:validated_summary($mc_validated),
      consensus_basechain:consensus_summary($bc_events),
      consensus_masterchain:consensus_summary($mc_events)
    },
    measured:{
      collated_basechain:collated_summary($measured_collated),
      validated_basechain:validated_summary($measured_validated),
      collated_masterchain:collated_summary($measured_mc_collated),
      validated_masterchain:validated_summary($measured_mc_validated),
      consensus_basechain:consensus_summary($measured_bc_events),
      consensus_masterchain:consensus_summary($measured_mc_events)
    }
  }
' "$validator_session_stats_file" >"$validator_pipeline_summary_file"

# INFO scheduling summaries are optional at normal validator verbosity. The
# structured consensus event stream is always captured by log.session-stats,
# so derive cadence and wall-time telemetry from it without enabling noisy
# global logging. This does not claim to expose internal wake/timer reasons.
jq -Rsc \
  --argjson measure_start "$generator_measure_start" \
  --argjson measure_end "$generator_measure_end" \
  --slurpfile info "$validator_scheduling_log_summary_file" '
  def distribution:
    map(select(type == "number")) | sort as $values |
    if ($values | length) == 0 then
      {samples:0,avg:null,p50:null,p95:null,p99:null,max:null}
    else
      ($values | length) as $count |
      {samples:$count,avg:($values | add / $count),
       p50:$values[((($count - 1) * 0.50) | floor)],
       p95:$values[((($count - 1) * 0.95) | floor)],
       p99:$values[((($count - 1) * 0.99) | floor)],max:$values[-1]}
    end;
  def intervals($timestamps):
    ($timestamps | sort) as $values |
    [range(1; $values | length) | $values[.] - $values[. - 1]] | distribution;
  def event_duration($rows; $start_type; $finish_type; $id_field):
    [$rows[] |
      select(.event["@type"] == $start_type or .event["@type"] == $finish_type) |
      {key:(.session_id + ":" + ((.event[$id_field].slot? // .event.target_slot? // -1) | tostring)),
       type:.event["@type"],ts:.ts}] |
    sort_by(.key,.ts) | group_by(.key) |
    map((map(select(.type == $start_type)) | first? | .ts) as $start |
        (map(select(.type == $finish_type)) | last? | .ts) as $finish |
        select($start != null and $finish != null and $finish >= $start) |
        $finish - $start) | distribution;
  def summarize($rows):
    [$rows[] | select(.event["@type"] == "consensus.stats.collateStarted") | .ts] as $collate |
    [$rows[] | select(.event["@type"] == "consensus.stats.blockAccepted") | .ts] as $accepted |
    {
      events:($rows | length),
      first_event_unix_s:($rows | map(.ts) | min // null),
      last_event_unix_s:($rows | map(.ts) | max // null),
      collate_started:($collate | length),
      collate_finished:([$rows[] | select(.event["@type"] == "consensus.stats.collateFinished")] | length),
      collated_empty:([$rows[] | select(.event["@type"] == "consensus.stats.collatedEmpty")] | length),
      candidates_received:([$rows[] | select(.event["@type"] == "consensus.stats.candidateReceived")] | length),
      blocks_accepted:($accepted | length),
      skip_votes:([$rows[] | select(.event["@type"] == "consensus.simplex.stats.voted" and
                                     .event.vote["@type"] == "consensus.simplex.skipVote")] | length),
      notarize_votes:([$rows[] | select(.event["@type"] == "consensus.simplex.stats.voted" and
                                         .event.vote["@type"] == "consensus.simplex.notarizeVote")] | length),
      finalize_votes:([$rows[] | select(.event["@type"] == "consensus.simplex.stats.voted" and
                                         .event.vote["@type"] == "consensus.simplex.finalizeVote")] | length),
      collate_start_interval_s:intervals($collate),
      accepted_block_interval_s:intervals($accepted),
      collation_wall_s:event_duration($rows; "consensus.stats.collateStarted";
                                      "consensus.stats.collateFinished"; "id"),
      validation_wall_s:event_duration($rows; "consensus.stats.validationStarted";
                                       "consensus.stats.validationFinished"; "id")
    };
  [split("\n")[] | fromjson? | select(.["@type"] == "consensus.stats.events")] as $sessions |
  (reduce $sessions[] as $record ({};
    (($record.events |
      map(select(.event["@type"] == "consensus.stats.candidateReceived" and
                 .event.block["@type"] == "consensus.stats.block")) |
      first? | .event.block.id.workchain?) // null) as $workchain |
    if $workchain != null then .[$record.id] = $workchain else . end)) as $workchains |
  [$sessions[] as $session | $session.events[] |
    {session_id:$session.id,workchain:($workchains[$session.id] // null),ts:.ts,event:.event}] as $events |
  [$events[] | select($measure_start != null and $measure_end != null and
                       .ts >= $measure_start and .ts < $measure_end)] as $measured |
  {
    provenance:{
      primary_source:"validator /var/ton-work/db/log.session-stats consensus.stats.events",
      source_is_structured:true,
      timestamp_precision:"floating-point Unix seconds emitted by validator consensus instrumentation",
      workchain_assignment:"inferred from candidateReceived block id for each consensus session",
      limitations:[
        "does not expose internal actor wake reasons, timer deadlines, or pending-work gauges",
        "events from sessions without a candidateReceived record remain unmapped",
        "measured window uses event timestamp >= start and < end"
      ],
      optional_info_log_records:($info[0].records // 0)
    },
    measured_window_unix_s:{start:$measure_start,end:$measure_end},
    unmapped_events:([$events[] | select(.workchain == null)] | length),
    all_run:{
      basechain:summarize([$events[] | select(.workchain == 0)]),
      masterchain:summarize([$events[] | select(.workchain == -1)])
    },
    measured:{
      basechain:summarize([$measured[] | select(.workchain == 0)]),
      masterchain:summarize([$measured[] | select(.workchain == -1)])
    },
    info_log_last_by_component:($info[0].last_by_component // [])
  }
' "$validator_session_stats_file" >"$validator_scheduling_summary_file"

if jq -e '
  (.measured_window_unix_s.start != null) and
  (.measured_window_unix_s.end != null) and
  (.measured_window_unix_s.start < .measured_window_unix_s.end) and
  (.all_run.collated_basechain.blocks > 0) and
  (.measured.collated_basechain.blocks == 0)
' "$validator_pipeline_summary_file" >/dev/null; then
  echo "validator telemetry contained basechain candidates but the measured slice was empty" >&2
  benchmark_exit_code=125
fi

# Let Session Stats import the tail of the validator log before querying the
# independent canonical summary.  Its importer deliberately ignores the most
# recent lag window, so querying immediately would undercount the run tail.
session_stats_settle_seconds=$(docker inspect session-stats |
  jq -r '.[0].Config.Env as $env |
    (($env[] | select(startswith("SESSION_STATS_IMPORT_INTERVAL_SECONDS=")) |
      split("=")[1] | tonumber) // 60) +
    (($env[] | select(startswith("SESSION_STATS_IMPORT_LAG_SECONDS=")) |
      split("=")[1] | tonumber) // 15) + 2' 2>/dev/null || echo 77)
if ! [[ $session_stats_settle_seconds =~ ^[0-9]+$ ]]; then
  session_stats_settle_seconds=77
fi
echo "Waiting ${session_stats_settle_seconds}s for Session Stats to import the run tail"
sleep "$session_stats_settle_seconds"

elapsed_seconds=$((finished_epoch - started_epoch))
if [[ $elapsed_seconds -lt 1 ]]; then
  elapsed_seconds=1
fi
session_stats_base='http://127.0.0.1:18000/api/stats_single?stat=BLOCK_APPLIED_native_transfers'
# Session Stats persists imported validator samples in minute buckets. Query
# whole source buckets so a run that starts or finishes mid-minute is not
# silently undercounted. The generator's proof-checked follower remains the
# authoritative source for exact run boundaries and one-second TPS; this API
# independently corroborates canonical totals and per-block packing.
session_stats_query_start_epoch=$((started_epoch / 60 * 60))
session_stats_query_end_epoch=$(((finished_epoch / 60 + 1) * 60))
session_stats_query_start=$(date -u -d "@$session_stats_query_start_epoch" +%Y-%m-%dT%H:%M:%SZ)
session_stats_query_end=$(date -u -d "@$session_stats_query_end_epoch" +%Y-%m-%dT%H:%M:%SZ)
session_stats_range="start=$session_stats_query_start&end=$session_stats_query_end&window_size=60&total_range=1"
session_stats_window_seconds=60
session_stats_query_elapsed_seconds=$((session_stats_query_end_epoch - session_stats_query_start_epoch))
session_stats_rate_file=$result_dir/session-stats-canonical-rate.json
session_stats_sum_file=$result_dir/session-stats-canonical-sum.json
if ! docker exec session-stats python -c \
  'import sys, urllib.request; sys.stdout.buffer.write(urllib.request.urlopen(sys.argv[1], timeout=30).read())' \
  "$session_stats_base&mode=rate&$session_stats_range" >"$session_stats_rate_file" \
  2>>"$result_dir/session-stats-api.stderr.log"; then
  printf '[]\n' >"$session_stats_rate_file"
fi
if ! docker exec session-stats python -c \
  'import sys, urllib.request; sys.stdout.buffer.write(urllib.request.urlopen(sys.argv[1], timeout=30).read())' \
  "$session_stats_base&mode=sum&$session_stats_range" >"$session_stats_sum_file" \
  2>>"$result_dir/session-stats-api.stderr.log"; then
  printf '[]\n' >"$session_stats_sum_file"
fi
jq -n \
  --arg start "$started_at" \
  --arg end "$finished_at" \
  --arg query_start "$session_stats_query_start" \
  --arg query_end "$session_stats_query_end" \
  --argjson elapsed_seconds "$elapsed_seconds" \
  --argjson query_elapsed_seconds "$session_stats_query_elapsed_seconds" \
  --argjson rate_window_seconds "$session_stats_window_seconds" \
  --slurpfile rates "$session_stats_rate_file" \
  --slurpfile sums "$session_stats_sum_file" '
    ($rates[0] | if type == "array" then . else [] end) as $rate_rows |
    ($sums[0] | if type == "array" then . else [] end) as $sum_rows |
    ($sum_rows | map(.wc // 0) | add // 0) as $canonical |
    {
      semantics: "Session Stats minute-bucketed consensus-selected native transfers in basechain blocks anchored by masterchain; use the generator follower for exact run-boundary and one-second TPS",
      requested_run_range: {$start,$end,$elapsed_seconds},
      database_query_range: {
        start:$query_start,
        end:$query_end,
        elapsed_seconds:$query_elapsed_seconds,
        source_resolution_seconds:$rate_window_seconds,
        left_padding_seconds:(($start | fromdateiso8601) - ($query_start | fromdateiso8601)),
        right_padding_seconds:(($query_end | fromdateiso8601) - ($end | fromdateiso8601)),
        boundary_rule:"whole persisted minute buckets intersecting the run; padded totals are corroboration only"
      },
      rate_samples: ($rate_rows | length),
      max_minute_average_canonical_tps: ($rate_rows | map(.wc // 0) | max),
      max_native_transfers_per_block: ($rate_rows | map(.wc_max // 0) | max),
      canonical_transfers: $canonical,
      padded_range_average_canonical_tps: ($canonical / $query_elapsed_seconds)
    }
  ' >"$session_stats_summary_file"

jq -L "$benchmark_jq_dir" -Rs '
  include "native-benchmark-lib";
  [split("\n")[] | fromjson? | select(.schema == "native-load-v2")] as $records |
  ($records | map(select(.final == true)) | last) as $final |
  {
    records: ($records | length),
    max_offered_tps: ($records | map(.offered_tps // 0) | max),
    max_sign_tps: ($records | map(.sign_tps // 0) | max),
    max_wire_tps: ($records | map(.wire_tps // 0) | max),
    max_wire_query_tps: ($records | map(.wire_query_tps // 0) | max),
    max_wire_batch_size: ($records | map(.wire_batch_max_size // 0) | max),
    max_wire_batch_source_run: ($records | map(.wire_batch_source_run_max_size // 0) | max),
    max_source_issue_burst:($records | map(.source_issue_burst_max_size // 0) | max),
    max_active_tasks_per_source:($records | map(.max_active_tasks_per_source // 0) | max),
    max_clients_at_cwnd_cap:($records | map(.clients_at_cwnd_cap // 0) | max),
    max_clients_at_query_cap:($records | map(.clients_at_query_cap // 0) | max),
    max_sources_at_canonical_backlog_cap:($records |
      map(.sources_at_canonical_backlog_cap // 0) | max),
    max_mempool_accept_tps: ($records | map(.mempool_accept_tps // 0) | max),
    max_canonical_tps: ($records | map(
      .canonical_chain_measure_peak_1s_tps // .canonical_tps // .measured_canonical_tps // 0
    ) | max),
    max_canonical_tps_semantics: "maximum transfers assigned to one fully contained canonical block gen_utime second; final canonical_gen_utime_bucket_* fields define exact integer boundaries",
    max_canonical_follower_discovery_tps: ($records | map(
      .canonical_follower_discovery_tps // 0
    ) | max),
    canonical_follower_discovery_tps_semantics: "observer catch-up speed; not blockchain production TPS",
    max_canonical_follower_block_discovery_rate: ($records | map(
      .canonical_follower_block_discovery_rate // 0
    ) | max),
    max_canonical_backlog: ($records | map(.canonical_backlog // 0) | max),
    max_canonical_follower_lag_blocks: (
      $final.canonical_follower_max_lag_blocks //
      ($records | map(.canonical_follower_lag_blocks // 0) | max)
    ),
    canonical_backpressure_seconds: ($final.canonical_backpressure_s // null),
    canonical_backpressure_engaged: (($final.canonical_backpressure_s // 0) > 0),
    measured_canonical_backpressure_seconds: ($final.measure_canonical_backpressure_s // null),
    measured_canonical_backpressure_fraction: ($final.measure_canonical_backpressure_fraction // null),
    ingress_capacity_valid: (
      if $final == null then null else ($final.ingress_capacity_valid // false) end
    ),
    chain_capacity_valid: (
      if $final == null then null else ($final.chain_capacity_valid // false) end
    ),
    chain_correctness_valid: (
      if $final == null then null else ($final.chain_correctness_valid // false) end
    ),
    canonical_observer_invalid_or_lagging_at_end: (
      (($final.canonical_follower_errors // 0) > 0) or
      (($final.canonical_follower_retry_exhausted // 0) > 0) or
      (($final.canonical_follower_reorgs // 0) > 0) or
      (($final.canonical_follower_lag_blocks // 0) > 0) or
      ($final != null and
       ($final | has("canonical_follower_final_catchup_complete")) and
       $final.canonical_follower_final_catchup_complete != true)
    ),
    canonical_follower_transient_timeouts: ($final.canonical_follower_transient_timeouts // 0),
    canonical_follower_transient_liteserver_timeouts: (
      $final.canonical_follower_transient_liteserver_timeouts // 0
    ),
    canonical_follower_transient_not_ready: (
      $final.canonical_follower_transient_not_ready // 0
    ),
    canonical_follower_transient_cancellations: ($final.canonical_follower_transient_cancellations // 0),
    canonical_follower_transient_retries: ($final.canonical_follower_transient_retries // 0),
    canonical_follower_transient_recoveries: ($final.canonical_follower_transient_recoveries // 0),
    canonical_follower_reconnects: ($final.canonical_follower_reconnects // 0),
    canonical_follower_fatal_errors: ($final.canonical_follower_fatal_errors // 0),
    canonical_follower_retry_exhausted: ($final.canonical_follower_retry_exhausted // 0),
    measured_offered_avg_tps: ($final.steady_offered_avg_tps // null),
    offer_target_attainment_ratio: ($final.offer_target_attainment_ratio // null),
    offer_target_attained: field_or_null($final; "offer_target_attained"),
    canonical_overdrive_ratio: ($final.canonical_overdrive_ratio // null),
    measured_admission_avg_tps: ($final.steady_mempool_accept_avg_tps // null),
    measured_canonical_chain_avg_tps: ($final.canonical_chain_measure_avg_tps // null),
    measured_offer_cohort_observed_avg_tps: (
      $final.canonical_measured_offer_cohort_observed_avg_tps // null
    ),
    canonical_gen_utime_window:(if $final == null then null else {
      start_unix_s:($final.canonical_gen_utime_bucket_start_unix_s // null),
      end_unix_s:($final.canonical_gen_utime_bucket_end_unix_s // null),
      duration_s:($final.canonical_gen_utime_bucket_duration_s // null),
      boundary_rule:"whole [gen_utime,gen_utime+1) buckets fully contained in the millisecond measurement window"
    } end),
    task_errors_by_reason:($final.task_errors_by_reason // null),
    retries_by_reason:($final.retries_by_reason // null),
    retry_policy:(if $final == null then null else {
      retry_exhausted:($final.retry_exhausted // 0),
      retry_horizon_exhausted:($final.retry_horizon_exhausted // 0),
      retry_exhausted_sources:($final.retry_exhausted_sources // 0),
      canonical_state_lag_retry_exhausted:($final.canonical_state_lag_retry_exhausted // 0),
      retry_horizon_s:($final.retry_horizon_s // null),
      canonical_state_lag_retry_backoff_ms:(
        $final.canonical_state_lag_retry_backoff_ms // null
      ),
      canonical_state_lag_retry_max_backoff_ms:(
        $final.canonical_state_lag_retry_max_backoff_ms // null
      )
    } end),
    adaptive_cwnd:(if $final == null then null else {
      configured_global_cap:($final.adaptive_max_cwnd // 0),
      effective_global_cap:($final.effective_cwnd_cap // null),
      initial_window:($final.initial_congestion_window // null),
      final_window:($final.congestion_window // null),
      sampled_peak:($final.congestion_window_sampled_peak // null),
      max_clients_at_cap:($records | map(.clients_at_cwnd_cap // 0) | max),
      cap_limited_acks:($final.cwnd_cap_limited_acks // 0),
      semantics:"message-count admission window; independent from the unresolved/proof max_inflight bound"
    } end),
    admission_query_credit:(if $final == null then null else {
      configured_per_client:($final.submit_max_queries_per_client // 0),
      final_inflight:($final.admission_queries_inflight // 0),
      sampled_clients_at_cap_peak:($final.clients_at_query_cap_sampled_peak // null),
      max_clients_at_cap:($records | map(.clients_at_query_cap // 0) | max),
      stalls:($final.query_credit_stalls // 0),
      max_per_client:($final.max_per_client_admission_queries // 0),
      semantics:"per persistent-client cap on concurrent native admission RPCs; zero preserves unlimited behavior, and counters exclude anchor/state scans"
    } end),
    ready_source_scheduler:(if $final == null then null else {
      head_blocked_ready_notifications:($final.head_blocked_ready_notifications // 0),
      legacy_head_blocked_ready_scans:($final.head_blocked_ready_scans // 0),
      queue_pushes:($final.ready_source_queue_pushes // 0),
      stale_entries:($final.ready_source_queue_stale_entries // 0),
      excluded_rotations:($final.ready_source_queue_excluded_rotations // 0),
      max_depth:($final.ready_source_queue_max_depth // 0)
    } end),
    histogram_overflow:{
      rtt:($final.rtt_ms | if . == null then null else
        {overflow:(.overflow // null),lower_bound_ms:(.overflow_lower_bound_ms // null),
         p50_in_overflow:field_or_null(.; "p50_in_overflow"),
         p95_in_overflow:field_or_null(.; "p95_in_overflow"),
         p99_in_overflow:field_or_null(.; "p99_in_overflow")} end),
      signing:($final.sign_ms | if . == null then null else
        {overflow:(.overflow // null),lower_bound_ms:(.overflow_lower_bound_ms // null),
         p50_in_overflow:field_or_null(.; "p50_in_overflow"),
         p95_in_overflow:field_or_null(.; "p95_in_overflow"),
         p99_in_overflow:field_or_null(.; "p99_in_overflow")} end),
      anchor:($final.anchor_latency_sample_ms | if . == null then null else
        {overflow:(.overflow // null),lower_bound_ms:(.overflow_lower_bound_ms // null),
         p50_in_overflow:field_or_null(.; "p50_in_overflow"),
         p95_in_overflow:field_or_null(.; "p95_in_overflow"),
         p99_in_overflow:field_or_null(.; "p99_in_overflow")} end)
    },
    generator_benchmark_result_valid: (
      if $final == null then null else $final.benchmark_result_valid end
    ),
    valid_canonical_run: (
      $final != null and
      ($final.benchmark_result_valid == true) and
      ($final.canonical_result_valid == true) and
      ($final.interrupted == false) and
      ($final.drain_timed_out == false) and
      (($final.canonical_follower_errors // 0) == 0) and
      (($final.canonical_follower_retry_exhausted // 0) == 0) and
      (($final.canonical_follower_final_catchup_complete // false) == true) and
      (($final.canonical_follower_reorgs // 0) == 0) and
      (($final.canonical_follower_lag_blocks // -1) == 0) and
      (($final.canonical_hash_conflicts // 0) == 0) and
      (($final.duplicate_nonce_conflicts // 0) == 0) and
      (($final.external_nonce_conflicts // 0) == 0) and
      (($final.nonce_gaps // -1) == 0) and
      (($final.canonical_backlog_after_drain // -1) == 0) and
      (($final.canonical_total_backlog_after_drain // -1) == 0) and
      ($final.canonical_measured_offers_after_drain == $final.steady_offered)
    ),
    capacity_acceptance:capacity_acceptance($final),
    generator_reported_invalid_reasons:(if $final == null then null else {
      correctness:($final.correctness_invalid_reasons // []),
      run_completion:($final.run_incomplete_reasons // []),
      ingress_capacity:($final.ingress_capacity_invalid_reasons // []),
      chain_capacity:($final.chain_capacity_invalid_reasons // [])
    } end),
    final: $final
  }
' "$generator_log_file" >"$generator_summary_file"

if [[ $generator_container_exit_code -eq 0 ]] &&
   ! jq -e '.final != null' "$generator_summary_file" >/dev/null; then
  echo "generator exited successfully without a final native-load-v2 record" >&2
  benchmark_exit_code=125
elif [[ $generator_container_exit_code -eq 0 ]] &&
     ! jq -e '.valid_canonical_run == true' "$generator_summary_file" >/dev/null; then
  echo "generator exited successfully but canonical benchmark validation failed" >&2
  benchmark_exit_code=3
fi
if [[ $generator_container_exit_code -eq 0 ]] &&
   ! jq -e '.cleanup_acceptance.valid == true' "$validator_pool_summary_file" >/dev/null; then
  echo "generator exited successfully but validator canonical cleanup validation failed" >&2
  benchmark_exit_code=3
fi
if jq -e '.canonical_observer_invalid_or_lagging_at_end == true' "$generator_summary_file" >/dev/null; then
  echo "warning: canonical follower ended invalid or behind the anchored shard tip; do not use this run as a chain ceiling" >&2
elif jq -e '.canonical_backpressure_engaged == true' "$generator_summary_file" >/dev/null; then
  echo "notice: the canonical backlog guard throttled offers; this can indicate chain saturation or transient observer lag, so compare follower lag, block rate, and canonical backlog before classifying the ceiling" >&2
fi
if jq -e '.valid_canonical_run == true and .chain_capacity_valid != true' \
  "$generator_summary_file" >/dev/null; then
  echo "notice: the run is canonically correct but not a valid chain-capacity result; do not claim a TPS ceiling from it" >&2
fi

jq -L "$benchmark_jq_dir" -s \
  --argjson host_vcpus "$(getconf _NPROCESSORS_ONLN)" \
  --argjson host_memory_bytes "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)" '
  include "native-benchmark-lib";
  def percent: sub("%$"; "") | tonumber;
  def bytes:
    capture("^(?<value>[0-9.]+)(?<unit>[A-Za-z]+)$") as $m |
    ($m.value | tonumber) *
    ({B:1,kB:1000,KB:1000,KiB:1024,MB:1000000,MiB:1048576,
      GB:1000000000,GiB:1073741824,TB:1000000000000,TiB:1099511627776}[$m.unit]);
  group_by(.Name) |
  map(
    (map(.CPUPerc | percent)) as $cpu |
    (map((.MemUsage | split(" / ")[0]) | bytes)) as $memory |
    (map((.NetIO | split(" / ")[0]) | bytes)) as $net_rx |
    (map((.NetIO | split(" / ")[1]) | bytes)) as $net_tx |
    (map((.BlockIO | split(" / ")[0]) | bytes)) as $block_read |
    (map((.BlockIO | split(" / ")[1]) | bytes)) as $block_write |
    (map(.sampled_at_epoch) | sort) as $sample_times |
    (($sample_times[-1] // 0) - ($sample_times[0] // 0)) as $sample_span |
    ($net_rx | monotonic_counter_delta) as $net_rx_delta |
    ($net_tx | monotonic_counter_delta) as $net_tx_delta |
    ($block_read | monotonic_counter_delta) as $block_read_delta |
    ($block_write | monotonic_counter_delta) as $block_write_delta |
    {
      name: .[0].Name,
      samples: length,
      avg_cpu_percent: (($cpu | add) / ($cpu | length)),
      max_cpu_percent: ($cpu | max),
      avg_cpu_cores: ((($cpu | add) / ($cpu | length)) / 100),
      max_cpu_cores: (($cpu | max) / 100),
      avg_cpu_host_percent: ((($cpu | add) / ($cpu | length)) / $host_vcpus),
      max_cpu_host_percent: (($cpu | max) / $host_vcpus),
      avg_memory_bytes: (($memory | add) / ($memory | length)),
      max_memory_bytes: ($memory | max),
      avg_memory_host_percent: (
        (($memory | add) / ($memory | length)) * 100 / $host_memory_bytes
      ),
      max_memory_host_percent: (($memory | max) * 100 / $host_memory_bytes),
      io_sample_span_seconds:$sample_span,
      net_rx_bytes_delta:$net_rx_delta,
      net_tx_bytes_delta:$net_tx_delta,
      block_read_bytes_delta:$block_read_delta,
      block_write_bytes_delta:$block_write_delta,
      avg_net_rx_bytes_per_second:(if $sample_span > 0 then $net_rx_delta / $sample_span else null end),
      avg_net_tx_bytes_per_second:(if $sample_span > 0 then $net_tx_delta / $sample_span else null end),
      avg_block_read_bytes_per_second:(if $sample_span > 0 then $block_read_delta / $sample_span else null end),
      avg_block_write_bytes_per_second:(if $sample_span > 0 then $block_write_delta / $sample_span else null end)
    }
  )
' "$container_stats_file" >"$result_dir/container-resource-summary.json"

jq -s '
  if length == 0 then
    {samples:0,avg_cpu_percent:null,max_cpu_percent:null,
     avg_iowait_percent:null,max_iowait_percent:null,
     avg_memory_used_bytes:null,max_memory_used_bytes:null,per_cpu:[]}
  else
    {
      samples: length,
      avg_cpu_percent: (map(.cpu_percent) | add / length),
      max_cpu_percent: (map(.cpu_percent) | max),
      avg_iowait_percent: (map(.iowait_percent // 0) | add / length),
      max_iowait_percent: (map(.iowait_percent // 0) | max),
      avg_memory_used_bytes: (map(.memory_used_bytes) | add / length),
      max_memory_used_bytes: (map(.memory_used_bytes) | max),
      memory_total_bytes: (last.memory_total_bytes),
      per_cpu:([.[] | .per_cpu[]?] | sort_by(.cpu) | group_by(.cpu) |
        map({cpu:.[0].cpu,samples:length,
             avg_cpu_percent:(map(.cpu_percent) | add / length),
             max_cpu_percent:(map(.cpu_percent) | max),
             avg_iowait_percent:(map(.iowait_percent) | add / length),
             max_iowait_percent:(map(.iowait_percent) | max)}))
    }
  end
' "$host_stats_file" >"$result_dir/host-resource-summary.json"

jq -L "$benchmark_jq_dir" -s '
  include "native-benchmark-lib";
  def pressure_avg10($text; $kind):
    (($text // "") | capture("(?:^|;)" + $kind + " avg10=(?<value>[0-9.]+)")? |
      .value | tonumber?) // 0;
  sort_by(.container,.sampled_at_epoch) | group_by(.container) |
  map(
    (map(.sampled_at_epoch) | sort) as $times |
    (($times[-1] // 0) - ($times[0] // 0)) as $span |
    (map(.cpu_usage_usec) | monotonic_counter_delta) as $cpu_usage |
    (map(.cpu_nr_periods) | monotonic_counter_delta) as $periods |
    (map(.cpu_nr_throttled) | monotonic_counter_delta) as $throttled_periods |
    (map(.cpu_throttled_usec) | monotonic_counter_delta) as $throttled_usec |
    {
      name:.[0].container,samples:length,sample_span_seconds:$span,
      cgroup_path:.[-1].cgroup_path,
      cpuset_cpus_effective:.[-1].cpuset_cpus_effective,
      cpu_max:.[-1].cpu_max,memory_max:.[-1].memory_max,
      avg_cpu_cores:(if $span > 0 then $cpu_usage / 1000000 / $span else null end),
      cpu_usage_seconds:($cpu_usage / 1000000),
      cpu_periods:$periods,cpu_throttled_periods:$throttled_periods,
      cpu_throttled_period_fraction:(if $periods > 0 then $throttled_periods / $periods else 0 end),
      cpu_throttled_seconds:($throttled_usec / 1000000),
      max_memory_current_bytes:(map(.memory_current) | max // null),
      max_memory_peak_bytes:(map(.memory_peak) | max // null),
      oom_events_delta:(map(.memory_oom) | monotonic_counter_delta),
      oom_kill_events_delta:(map(.memory_oom_kill) | monotonic_counter_delta),
      io_read_bytes_delta:(map(.io_read_bytes) | monotonic_counter_delta),
      io_write_bytes_delta:(map(.io_write_bytes) | monotonic_counter_delta),
      io_read_operations_delta:(map(.io_read_operations) | monotonic_counter_delta),
      io_write_operations_delta:(map(.io_write_operations) | monotonic_counter_delta),
      max_cpu_pressure_some_avg10:(map(pressure_avg10(.cpu_pressure; "some")) | max // null),
      max_io_pressure_some_avg10:(map(pressure_avg10(.io_pressure; "some")) | max // null),
      max_io_pressure_full_avg10:(map(pressure_avg10(.io_pressure; "full")) | max // null),
      max_memory_pressure_some_avg10:(map(pressure_avg10(.memory_pressure; "some")) | max // null)
    }
  )
' "$cgroup_stats_file" >"$result_dir/cgroup-resource-summary.json"

jq -L "$benchmark_jq_dir" -s '
  include "native-benchmark-lib";
  sort_by(.device,.sampled_at_epoch) | group_by(.device) |
  map(
    (map(.sampled_at_epoch) | sort) as $times |
    (($times[-1] // 0) - ($times[0] // 0)) as $span |
    (map(.read_bytes) | monotonic_counter_delta) as $read_bytes |
    (map(.write_bytes) | monotonic_counter_delta) as $write_bytes |
    {
      device:.[0].device,samples:length,sample_span_seconds:$span,
      read_bytes_delta:$read_bytes,write_bytes_delta:$write_bytes,
      read_operations_delta:(map(.read_operations) | monotonic_counter_delta),
      write_operations_delta:(map(.write_operations) | monotonic_counter_delta),
      io_busy_seconds:((map(.io_time_ms) | monotonic_counter_delta) / 1000),
      weighted_io_seconds:((map(.weighted_io_time_ms) | monotonic_counter_delta) / 1000),
      max_in_flight:(map(.in_flight) | max // null),
      avg_read_bytes_per_second:(if $span > 0 then $read_bytes / $span else null end),
      avg_write_bytes_per_second:(if $span > 0 then $write_bytes / $span else null end)
    }
  )
' "$device_stats_file" >"$result_dir/device-resource-summary.json"

jq -s '
  [.[].threads[]?] | sort_by(.container,.thread_name,.tid) |
  group_by([.container,.thread_name,.tid]) |
  map({container:.[0].container,thread_name:.[0].thread_name,tid:.[0].tid,
       samples:length,avg_cpu_percent:(map(.cpu_percent) | add / length),
       max_cpu_percent:(map(.cpu_percent) | max),
       last_processor:.[-1].processor}) |
  sort_by(-.max_cpu_percent) | .[:64]
' "$thread_stats_file" >"$result_dir/thread-resource-summary.json"

jq -n \
  --slurpfile containers "$result_dir/container-resource-summary.json" \
  --slurpfile host "$result_dir/host-resource-summary.json" \
  --slurpfile cgroups "$result_dir/cgroup-resource-summary.json" \
  --slurpfile devices "$result_dir/device-resource-summary.json" \
  --slurpfile threads "$result_dir/thread-resource-summary.json" \
  '{containers:$containers[0],host:$host[0],cgroups:$cgroups[0],
    devices:$devices[0],thread_hotspots:$threads[0]}' >"$resource_summary_file"

docker inspect genesis "$container_name" session-stats |
  jq '[.[] | {
    name: (.Name | ltrimstr("/")),
    image: .Config.Image,
    image_id: .Image,
    state: .State.Status,
    health: (.State.Health.Status // null),
    oom_killed: (.State.OOMKilled // false),
    restart_count: (.RestartCount // 0),
    exit_code: (.State.ExitCode // null),
    started_at: (.State.StartedAt // null),
    finished_at: (.State.FinishedAt // null),
    cpuset: .HostConfig.CpusetCpus,
    nano_cpus: .HostConfig.NanoCpus,
    memory_limit_bytes: .HostConfig.Memory,
    mounts:[.Mounts[]? | {type:.Type,source:.Source,destination:.Destination,rw:.RW}],
    benchmark_environment: [.Config.Env[] | select(test(
      "^(GENESIS_VERBOSITY|TON_SIMPLEX_[^=]+|TON_NATIVE_[^=]+|NATIVE_LOAD_[^=]+|SIMPLEX_[^=]+|BLOCK_(SIZE|GAS|LIMIT)[^=]*)="
    ))]
  }]' >"$runtime_file"

image_metadata_jsonl=$result_dir/image-metadata.jsonl
: >"$image_metadata_jsonl"
while read -r image_id; do
  [[ -n $image_id ]] || continue
  docker image inspect "$image_id" 2>/dev/null | jq '.[] | {
    image_id:.Id,
    repo_tags:(.RepoTags // []),
    repo_digests:(.RepoDigests // []),
    created:(.Created // null),
    architecture:(.Architecture // null),
    os:(.Os // null),
    size_bytes:(.Size // null),
    oci_labels:{
      created:(.Config.Labels["org.opencontainers.image.created"] // null),
      revision:(.Config.Labels["org.opencontainers.image.revision"] // null),
      source:(.Config.Labels["org.opencontainers.image.source"] // null),
      version:(.Config.Labels["org.opencontainers.image.version"] // null)
    }
  }' >>"$image_metadata_jsonl"
done < <(jq -r 'map(.image_id) | unique[]' "$runtime_file")
jq -s '.' "$image_metadata_jsonl" >"$image_metadata_file"

env_sha256=$(sha256sum "$env_file" | awk '{print $1}')
# The documented invocation uses sudo. Scope Git's ownership exception to this
# one checkout so root captures provenance instead of silently treating a
# dubious-ownership failure as a clean tree.
benchmark_git=(git -c "safe.directory=$script_dir" -C "$script_dir")
git_revision=$("${benchmark_git[@]}" rev-parse HEAD 2>/dev/null || true)
git_root=$("${benchmark_git[@]}" rev-parse --show-toplevel 2>/dev/null || true)
git_branch=$("${benchmark_git[@]}" branch --show-current 2>/dev/null || true)
git_describe=$("${benchmark_git[@]}" describe --always --dirty --tags 2>/dev/null || true)
git_status=$("${benchmark_git[@]}" status --porcelain=v1 --untracked-files=normal 2>/dev/null ||
  printf '%s' '__git_status_unavailable__')
git_dirty=$(if [[ -z $git_status ]]; then echo false; else echo true; fi)
git_status_sha256=$(printf '%s' "$git_status" | sha256sum | awk '{print $1}')
git_diff_sha256=$({
  "${benchmark_git[@]}" diff --binary HEAD 2>/dev/null || printf '%s' '__git_diff_unavailable__'
} | sha256sum | awk '{print $1}')
docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
compose_version=$(docker compose version --short 2>/dev/null || true)
docker_cgroup_driver=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || true)
docker_cgroup_version=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || true)
if command -v lscpu >/dev/null 2>&1; then
  cpu_topology=$(lscpu -J 2>/dev/null || echo '{}')
else
  cpu_topology='{}'
fi
smt_active=$(read_numeric_file /sys/devices/system/cpu/smt/active)
numa_nodes=$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | wc -l)
if [[ $git_dirty == true ]]; then
  reproducibility_reasons='["source_tree_dirty"]'
else
  reproducibility_reasons='[]'
fi
if ! jq -e 'length > 0 and all(.[]; (.repo_digests | length) > 0)' "$image_metadata_file" >/dev/null; then
  reproducibility_reasons=$(jq -cn --argjson reasons "$reproducibility_reasons" \
    '$reasons + ["one_or_more_images_lack_registry_digest"]')
fi
if ! jq -e 'length > 0 and all(.[];
  .oci_labels.revision != null and .oci_labels.revision != "unknown" and
  (.oci_labels.revision | length) > 0)' "$image_metadata_file" >/dev/null; then
  reproducibility_reasons=$(jq -cn --argjson reasons "$reproducibility_reasons" \
    '$reasons + ["one_or_more_images_lack_source_revision_label"]')
fi
jq -n \
  --arg schema native-benchmark-run-v2 \
  --arg run_id "$run_id" \
  --arg started_at "$started_at" \
  --arg finished_at "$finished_at" \
  --arg env_file "$env_file" \
  --arg env_sha256 "$env_sha256" \
  --arg git_revision "$git_revision" \
  --arg git_root "$git_root" \
  --arg git_branch "$git_branch" \
  --arg git_describe "$git_describe" \
  --arg git_status_sha256 "$git_status_sha256" \
  --arg git_diff_sha256 "$git_diff_sha256" \
  --argjson git_dirty "$git_dirty" \
  --arg compose_config_sha256 "$compose_config_sha256" \
  --argjson compose_service_hashes "$compose_service_hashes" \
  --arg docker_version "$docker_version" \
  --arg compose_version "$compose_version" \
  --arg docker_cgroup_driver "$docker_cgroup_driver" \
  --arg docker_cgroup_version "$docker_cgroup_version" \
  --arg kernel "$(uname -srmo)" \
  --arg cpu_model "$(awk -F: '/model name/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)" \
  --argjson host_vcpus "$(getconf _NPROCESSORS_ONLN)" \
  --argjson host_memory_bytes "$(awk '/^MemTotal:/ {print $2 * 1024; exit}' /proc/meminfo)" \
  --argjson cpu_topology "$cpu_topology" \
  --argjson smt_active "$smt_active" \
  --argjson numa_nodes "$numa_nodes" \
  --argjson elapsed_seconds "$((finished_epoch - started_epoch))" \
  --argjson generator_container_exit_code "$generator_container_exit_code" \
  --argjson benchmark_exit_code "$benchmark_exit_code" \
  --argjson interrupted "$interrupted" \
  --slurpfile containers "$runtime_file" \
  --slurpfile images "$image_metadata_file" \
  --slurpfile ext_messages_broadcast "$ext_messages_broadcast_file" \
  --argjson reproducibility_reasons "$reproducibility_reasons" \
  '{$schema,$run_id,$started_at,$finished_at,$elapsed_seconds,$env_file,$env_sha256,
    $git_revision,$git_dirty,
    source:{root:$git_root,revision:$git_revision,branch:$git_branch,describe:$git_describe,
            dirty:$git_dirty,status_sha256:$git_status_sha256,diff_sha256:$git_diff_sha256},
    compose:{config_sha256:$compose_config_sha256,service_hashes:$compose_service_hashes,
             version:$compose_version},
    docker:{version:$docker_version,cgroup_driver:$docker_cgroup_driver,
            cgroup_version:$docker_cgroup_version},
    $kernel,$cpu_model,$host_vcpus,$host_memory_bytes,
    host_topology:{smt_active:($smt_active == 1),numa_nodes:$numa_nodes,lscpu:$cpu_topology},
    $generator_container_exit_code,$benchmark_exit_code,
    interrupted:($interrupted == 1),containers:$containers[0],images:$images[0],
    ext_messages_broadcast:$ext_messages_broadcast[0],
    reproducibility:{valid:($reproducibility_reasons | length == 0),
                     reasons:$reproducibility_reasons,
                     semantics:"separate from proof correctness and capacity validity; dirty source or unpinned images make the run difficult to reproduce but do not alter canonical proof results"}}' >"$metadata_file"

jq -n \
  --slurpfile run "$metadata_file" \
  --slurpfile generator "$generator_summary_file" \
  --slurpfile resources "$resource_summary_file" \
  --slurpfile session_stats "$session_stats_summary_file" \
  --slurpfile validator_pipeline "$validator_pipeline_summary_file" \
  --slurpfile validator_pool "$validator_pool_summary_file" \
  --slurpfile validator_scheduling "$validator_scheduling_summary_file" \
  --slurpfile validator_actor_stats "$validator_actor_stats_summary_file" \
  --slurpfile ext_messages_broadcast "$ext_messages_broadcast_file" \
  '{run:$run[0],generator:$generator[0],session_stats:$session_stats[0],
    validator_pipeline:$validator_pipeline[0],validator_pool:$validator_pool[0],
    validator_scheduling:$validator_scheduling[0],
    validator_actor_stats:$validator_actor_stats[0],
    ext_messages_broadcast:$ext_messages_broadcast[0],
    resources:$resources[0],
    acceptance:($generator[0].capacity_acceptance + {
      validator_cleanup_valid:$validator_pool[0].cleanup_acceptance.valid,
      validator_cleanup_invalid_reasons:$validator_pool[0].cleanup_acceptance.invalid_reasons,
      reproducible:$run[0].reproducibility.valid,
      reproducibility_reasons:$run[0].reproducibility.reasons,
      semantics:"proof correctness, run completion, ingress capacity, chain capacity, validator canonical cleanup, and reproducibility are independent acceptance dimensions"
    })}' \
  >"$summary_file"

echo "Benchmark summary: $summary_file"
jq . "$summary_file"

if [[ $interrupted -eq 1 ]]; then
  exit 130
fi
exit "$benchmark_exit_code"
