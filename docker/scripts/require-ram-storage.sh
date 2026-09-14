#!/usr/bin/env bash
# The RAM runner uses vfs on a noswap host tmpfs: image layers and volumes
# therefore have the same filesystem type. Check before bootstrap writes keys.
set -euo pipefail
case ${NATIVE_RAM_ENABLED:-0} in
  0|'') exit 0 ;;
  1) ;;
  *) echo 'NATIVE_RAM_ENABLED must be 0 or 1' >&2; exit 2 ;;
esac
for path in / /usr/local/bin /var/ton-work/db /usr/share/data \
  /var/ton-work/db/native-spam/wallets /tmp /var/tmp /var/log; do
  kind=$(stat -f -c %T -- "$path")
  if [[ $kind != tmpfs ]]; then
    echo "RAM benchmark requires tmpfs at $path; found $kind. Use benchmark/physical-ram-docker.py." >&2
    exit 2
  fi
done
