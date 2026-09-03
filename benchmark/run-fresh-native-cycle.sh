#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
docker_repo=$(cd "$script_dir/.." && pwd)
ton_repo=${TON_SOURCE_REPO:-/home/neodix/gitProjects/corton-nommander-ton-sidechain}
env_file=${1:-.env.physical}

if [[ $env_file != /* ]]; then
  env_file=$docker_repo/$env_file
fi

for command_name in docker git jq awk sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required command is not installed: $command_name" >&2
    exit 2
  }
done

test -r "$env_file" || { echo "environment file is not readable: $env_file" >&2; exit 2; }
test -d "$ton_repo/.git" || { echo "TON source repository is missing: $ton_repo" >&2; exit 2; }

compose_file=$docker_repo/docker-compose.yaml
project_name=mylocalton-desktop
compose=(docker compose -f "$compose_file" --project-directory "$docker_repo" \
  --project-name "$project_name" --env-file "$env_file")
compose_environment=$("${compose[@]}" config --environment)
ton_image=$(awk -F= '$1 == "TON_IMAGE" {sub(/^[^=]*=/, ""); print; exit}' <<<"$compose_environment")
ton_branch=$(awk -F= '$1 == "TON_BRANCH" {sub(/^[^=]*=/, ""); print; exit}' <<<"$compose_environment")
ton_image=${ton_image:-ghcr.io/corton-nommander/ton}
ton_branch=${ton_branch:-latest}

compose_model=$("${compose[@]}" --profile session-stats --profile native-load-generator config --format json)
if ! jq -e '
  ([.services.genesis.volumes[] | select(.target == "/var/ton-work/db")]) as $db_mount |
  .name == "mylocalton-desktop" and
  (.services | keys | sort) == ["file-server","genesis","native-load-generator","session-stats"] and
  (.volumes | keys | sort) == ["native-load-wallets","session-stats-data","shared-data","ton-db-val0"] and
  ($db_mount | length) == 1 and
  $db_mount[0].type == "volume" and
  $db_mount[0].source == "ton-db-val0"
' <<<"$compose_model" >/dev/null; then
  echo "refusing destructive fresh cycle: resolved Compose model is outside the benchmark allowlist" >&2
  exit 2
fi

# `down --remove-orphans -v` also acts on existing resources carrying this
# project label. Refuse the destructive boundary if the live project contains
# anything outside the same explicit allowlist validated in the desired model.
if ! existing_containers=$(docker ps -a \
  --filter "label=com.docker.compose.project=$project_name" \
  --format '{{.Names}}\t{{.Label "com.docker.compose.service"}}'); then
  echo "refusing destructive fresh cycle: cannot inventory existing project containers" >&2
  exit 2
fi
while IFS=$'\t' read -r container_name service_name; do
  [[ -n $container_name ]] || continue
  case "$service_name" in
    file-server|genesis|native-load-generator|session-stats) ;;
    *)
      echo "refusing destructive fresh cycle: unexpected project container $container_name ($service_name)" >&2
      exit 2
      ;;
  esac
done <<<"$existing_containers"

if ! existing_volumes=$(docker volume ls \
  --filter "label=com.docker.compose.project=$project_name" \
  --format '{{.Name}}\t{{.Label "com.docker.compose.volume"}}'); then
  echo "refusing destructive fresh cycle: cannot inventory existing project volumes" >&2
  exit 2
fi
while IFS=$'\t' read -r volume_name volume_key; do
  [[ -n $volume_name ]] || continue
  case "$volume_key" in
    native-load-wallets|session-stats-data|shared-data|ton-db-val0) ;;
    *)
      echo "refusing destructive fresh cycle: unexpected project volume $volume_name ($volume_key)" >&2
      exit 2
      ;;
  esac
done <<<"$existing_volumes"

if ! existing_networks=$(docker network ls \
  --filter "label=com.docker.compose.project=$project_name" \
  --format '{{.Name}}\t{{.Label "com.docker.compose.network"}}'); then
  echo "refusing destructive fresh cycle: cannot inventory existing project networks" >&2
  exit 2
fi
while IFS=$'\t' read -r network_name network_key; do
  [[ -n $network_name ]] || continue
  if [[ $network_key != main ]]; then
    echo "refusing destructive fresh cycle: unexpected project network $network_name ($network_key)" >&2
    exit 2
  fi
done <<<"$existing_networks"

ton_git=(git -c "safe.directory=$ton_repo" -C "$ton_repo")
vcs_ref=$("${ton_git[@]}" describe --always --tags)
if [[ -n $("${ton_git[@]}" status --porcelain=v1 --untracked-files=normal) ]]; then
  worktree_sha=$({
    "${ton_git[@]}" diff --binary HEAD
    while IFS= read -r -d '' untracked; do
      printf 'untracked:%s\0' "$untracked"
      sha256sum "$ton_repo/$untracked"
    done < <("${ton_git[@]}" ls-files --others --exclude-standard -z)
  } | sha256sum | awk '{print substr($1, 1, 12)}')
  vcs_ref=$vcs_ref-dirty-$worktree_sha
fi
# GitMetadata inside the binaries uses the source commit time even though the
# Docker context excludes the 1.5 GiB .git object database. Keep the OCI
# creation label stable when rebuilding the identical qualified source, but
# record the real first-build time whenever source content changes.
vcs_date=$("${ton_git[@]}" show -s --format=%cI HEAD)
existing_vcs_ref=$(docker image inspect -f \
  '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
  "$ton_image:$ton_branch" 2>/dev/null || true)
if [[ $existing_vcs_ref == "$vcs_ref" ]]; then
  build_date=$(docker image inspect -f \
    '{{index .Config.Labels "org.opencontainers.image.created"}}' \
    "$ton_image:$ton_branch" 2>/dev/null || true)
fi
build_date=${build_date:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
jobs=${NINJA_JOBS:-20}

echo "Building $ton_image:$ton_branch from $ton_repo at $vcs_ref"
docker build \
  --build-arg PORTABLE=0 \
  --build-arg TON_ARCH=native \
  --build-arg NINJA_JOBS="$jobs" \
  --build-arg VCS_REF="$vcs_ref" \
  --build-arg VCS_DATE="$vcs_date" \
  --build-arg BUILD_DATE="$build_date" \
  -t "$ton_image:$ton_branch" \
  "$ton_repo"

echo "Prebuilding derived validator and generator images before deleting any state"
"${compose[@]}" --profile native-load-generator build genesis native-load-generator

echo "Deleting containers, networks, and volumes only for Compose project $project_name"
"${compose[@]}" --profile session-stats --profile native-load-generator down -v --remove-orphans

echo "Starting fresh native benchmark with $env_file"
cd "$docker_repo"
# The destructive operation above used a pinned Compose file/project. Do not
# let inherited Compose selectors redirect the wrapper's subsequent build/run.
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME
exec env BENCHMARK_IMAGES_PREBUILT=1 BENCHMARK_RECREATE_GENESIS=0 \
  ./run-native-benchmark.sh "$env_file"
