#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)

# shellcheck source=../../native-load-generator/payment-lanes.sh
. "$repo_dir/native-load-generator/payment-lanes.sh"

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT HUP INT TERM
wallet_dir=$test_dir/wallets
mkdir -p "$wallet_dir" "$test_dir/bin"

write_address() {
  # First byte determines the depth-1 lane; retain a valid 32-byte account id
  # followed by the ignored four-byte workchain field.
  {
    printf "$1"
    dd if=/dev/zero bs=31 count=1 2>/dev/null
    printf '\000\000\000\000'
  } > "$2"
}

for index in 0 1; do
  touch "$wallet_dir/source-$index.pk" "$wallet_dir/dest-$index.pub"
done
write_address '\001' "$wallet_dir/source-0.addr"
write_address '\002' "$wallet_dir/dest-0.addr"
write_address '\201' "$wallet_dir/source-1.addr"
write_address '\202' "$wallet_dir/dest-1.addr"

source_0=$(native_payment_lanes_address_hex "$wallet_dir/source-0.addr")
destination_0=$(native_payment_lanes_address_hex "$wallet_dir/dest-0.addr")
source_1=$(native_payment_lanes_address_hex "$wallet_dir/source-1.addr")
destination_1=$(native_payment_lanes_address_hex "$wallet_dir/dest-1.addr")
manifest=$wallet_dir/native-payment-lanes.manifest
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "0 0 $source_0 $destination_0" \
  "1 1 $source_1 $destination_1" > "$manifest"

native_payment_lanes_validate_mode 0 0 1 0
! native_payment_lanes_validate_mode 0 0 1 1 >/dev/null 2>&1
native_payment_lanes_validate_mode 1 1 1 1
! native_payment_lanes_validate_mode 1 0 1 1 >/dev/null 2>&1
native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1

# A modified public address invalidates the manifest before any traffic is
# offered, even when it happens to retain the same lane prefix.
write_address '\003' "$wallet_dir/dest-0.addr"
! native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1 >/dev/null 2>&1
write_address '\002' "$wallet_dir/dest-0.addr"

ready_output='shard #1 : (0,4000000000000000,10):AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB @ 1 lt 1 .. 2
shard #2 : (0,C000000000000000,10):CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD @ 1 lt 1 .. 2'
native_payment_lanes_shards_are_ready "$ready_output"
! native_payment_lanes_shards_are_ready 'shard #1 : (0,8000000000000000,10):A:B @ 1 lt 1 .. 2'

cat > "$test_dir/bin/lite-client" <<'EOF'
#!/bin/sh
cat "$NATIVE_PAYMENT_LANE_TEST_OUTPUT"
EOF
chmod +x "$test_dir/bin/lite-client"
printf '%s\n' "$ready_output" > "$test_dir/allshards.txt"
touch "$test_dir/global.config.json"
PATH="$test_dir/bin:$PATH"
export PATH NATIVE_PAYMENT_LANE_TEST_OUTPUT="$test_dir/allshards.txt"
NATIVE_LOAD_LITE_CLIENT_BIN=lite-client \
  native_payment_lanes_wait_for_shards "$test_dir/global.config.json" 2 1 1 \
  > "$test_dir/readiness.json"
grep -Fq '"event":"ready_observation"' "$test_dir/readiness.json"
