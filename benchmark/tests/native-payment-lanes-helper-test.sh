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

# Count validator awk invocations.  The full physical manifest is large, so
# the validator must extract a requested range with one pass rather than scan
# the complete file once for every source.
real_awk=$(command -v awk)
awk_counter=$test_dir/awk-counter
printf '0\n' > "$awk_counter"
cat > "$test_dir/bin/awk" <<'EOF'
#!/bin/sh
count=$(cat "$NATIVE_PAYMENT_LANE_AWK_COUNTER")
printf '%s\n' "$((count + 1))" > "$NATIVE_PAYMENT_LANE_AWK_COUNTER"
exec "$NATIVE_PAYMENT_LANE_REAL_AWK" "$@"
EOF
chmod +x "$test_dir/bin/awk"
PATH="$test_dir/bin:$PATH"
export PATH NATIVE_PAYMENT_LANE_AWK_COUNTER="$awk_counter" NATIVE_PAYMENT_LANE_REAL_AWK="$real_awk"

write_address() {
  # Leading bits determine the fixed-depth lane; retain a valid 32-byte
  # account id followed by the ignored four-byte workchain field.
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

[ "$(native_payment_lanes_lane_count)" -eq 2 ]
[ "$(native_payment_lanes_lane_count 2)" -eq 4 ]
[ "$(native_payment_lanes_lane_count 3)" -eq 8 ]
! native_payment_lanes_lane_count 4 >/dev/null 2>&1
[ "$(native_payment_lanes_address_lane "$wallet_dir/source-0.addr")" -eq 0 ]
[ "$(native_payment_lanes_address_lane "$wallet_dir/source-1.addr")" -eq 1 ]

source_0=$(native_payment_lanes_address_hex "$wallet_dir/source-0.addr")
destination_0=$(native_payment_lanes_address_hex "$wallet_dir/dest-0.addr")
source_1=$(native_payment_lanes_address_hex "$wallet_dir/source-1.addr")
destination_1=$(native_payment_lanes_address_hex "$wallet_dir/dest-1.addr")
manifest=$wallet_dir/native-payment-lanes.manifest
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "0 0 $source_0 $destination_0" \
  "1 1 $source_1 $destination_1" > "$manifest"

# Disabled mode keeps the historical inert genesis-depth default, but a load
# depth is never allowed to activate lanes behind the protocol gate.
native_payment_lanes_validate_mode 0 0 0 0
native_payment_lanes_validate_mode 0 0 1 0
! native_payment_lanes_validate_mode 0 0 1 1 >/dev/null 2>&1
! native_payment_lanes_validate_mode 0 0 2 2 >/dev/null 2>&1
! native_payment_lanes_validate_mode 0 0 3 3 >/dev/null 2>&1

native_payment_lanes_validate_mode 1 1 1 1
native_payment_lanes_validate_mode 1 1 2 2
! native_payment_lanes_validate_mode 1 0 1 1 >/dev/null 2>&1
! native_payment_lanes_validate_mode 1 0 2 2 >/dev/null 2>&1
! native_payment_lanes_validate_mode 1 1 0 0 >/dev/null 2>&1
native_payment_lanes_validate_mode 1 1 3 3
! native_payment_lanes_validate_mode 1 1 4 4 >/dev/null 2>&1
! native_payment_lanes_validate_mode 1 1 1 2 >/dev/null 2>&1
! native_payment_lanes_validate_mode 1 1 2 1 >/dev/null 2>&1
! native_payment_lanes_validate_mode 1 1 01 1 >/dev/null 2>&1
! native_payment_lanes_validate_mode enabled 1 1 1 >/dev/null 2>&1

grep -Fq 'native_payment_lane_active_depth=$native_load_payment_lane_depth' \
  "$repo_dir/native-load-generator/entrypoint.sh"
grep -Fq -- '--native-payment-lane-depth "$native_payment_lane_active_depth"' \
  "$repo_dir/native-load-generator/entrypoint.sh"
printf '0\n' > "$awk_counter"
native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1
[ "$(cat "$awk_counter")" -eq 1 ]

# Validation accepts a manifest in any row order, but scans it only once and
# still rejects a missing, duplicate, or malformed requested source row.
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "1 1 $source_1 $destination_1" \
  "0 0 $source_0 $destination_0" > "$manifest"
native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "0 0 $source_0 $destination_0" \
  "0 0 $source_0 $destination_0" \
  "1 1 $source_1 $destination_1" > "$manifest"
! native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1 >/dev/null 2>&1
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "0 0 $source_0 $destination_0" > "$manifest"
! native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1 >/dev/null 2>&1
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "0 0 $source_0 $destination_0 unexpected" \
  "1 1 $source_1 $destination_1" > "$manifest"
! native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1 >/dev/null 2>&1
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 1 2 2' \
  "0 0 $source_0 $destination_0" \
  "1 1 $source_1 $destination_1" > "$manifest"

# A modified public address invalidates the manifest before any traffic is
# offered, even when it happens to retain the same lane prefix.
write_address '\003' "$wallet_dir/dest-0.addr"
! native_payment_lanes_validate_manifest "$manifest" "$wallet_dir" 0 2 1 >/dev/null 2>&1
write_address '\002' "$wallet_dir/dest-0.addr"

# Depth-2 artifacts use all four high-bit prefixes. Manifest validation keeps
# the same single-pass extraction guarantee while checking four-way balance.
depth2_wallet_dir=$test_dir/depth2-wallets
mkdir -p "$depth2_wallet_dir"
for index in 0 1 2 3; do
  touch "$depth2_wallet_dir/source-$index.pk" "$depth2_wallet_dir/dest-$index.pub"
done
write_address '\001' "$depth2_wallet_dir/source-0.addr"
write_address '\002' "$depth2_wallet_dir/dest-0.addr"
write_address '\101' "$depth2_wallet_dir/source-1.addr"
write_address '\102' "$depth2_wallet_dir/dest-1.addr"
write_address '\201' "$depth2_wallet_dir/source-2.addr"
write_address '\202' "$depth2_wallet_dir/dest-2.addr"
write_address '\301' "$depth2_wallet_dir/source-3.addr"
write_address '\302' "$depth2_wallet_dir/dest-3.addr"

depth2_source_0=$(native_payment_lanes_address_hex "$depth2_wallet_dir/source-0.addr")
depth2_destination_0=$(native_payment_lanes_address_hex "$depth2_wallet_dir/dest-0.addr")
depth2_source_1=$(native_payment_lanes_address_hex "$depth2_wallet_dir/source-1.addr")
depth2_destination_1=$(native_payment_lanes_address_hex "$depth2_wallet_dir/dest-1.addr")
depth2_source_2=$(native_payment_lanes_address_hex "$depth2_wallet_dir/source-2.addr")
depth2_destination_2=$(native_payment_lanes_address_hex "$depth2_wallet_dir/dest-2.addr")
depth2_source_3=$(native_payment_lanes_address_hex "$depth2_wallet_dir/source-3.addr")
depth2_destination_3=$(native_payment_lanes_address_hex "$depth2_wallet_dir/dest-3.addr")
depth2_manifest=$depth2_wallet_dir/native-payment-lanes.manifest
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 2 4 4' \
  "0 0 $depth2_source_0 $depth2_destination_0" \
  "1 1 $depth2_source_1 $depth2_destination_1" \
  "2 2 $depth2_source_2 $depth2_destination_2" \
  "3 3 $depth2_source_3 $depth2_destination_3" > "$depth2_manifest"

[ "$(native_payment_lanes_address_lane "$depth2_wallet_dir/source-0.addr" 2)" -eq 0 ]
[ "$(native_payment_lanes_address_lane "$depth2_wallet_dir/source-1.addr" 2)" -eq 1 ]
[ "$(native_payment_lanes_address_lane "$depth2_wallet_dir/source-2.addr" 2)" -eq 2 ]
[ "$(native_payment_lanes_address_lane "$depth2_wallet_dir/source-3.addr" 2)" -eq 3 ]
printf '0\n' > "$awk_counter"
native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 2
[ "$(cat "$awk_counter")" -eq 1 ]
! native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 1 >/dev/null 2>&1
! native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 3 >/dev/null 2>&1

printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 2 2 4' \
  "0 0 $depth2_source_0 $depth2_destination_0" \
  "1 1 $depth2_source_1 $depth2_destination_1" \
  "2 2 $depth2_source_2 $depth2_destination_2" \
  "3 3 $depth2_source_3 $depth2_destination_3" > "$depth2_manifest"
! native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 2 >/dev/null 2>&1

# A valid depth-2 header still rejects a lane outside [0,4).
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 2 4 4' \
  "0 0 $depth2_source_0 $depth2_destination_0" \
  "1 1 $depth2_source_1 $depth2_destination_1" \
  "2 2 $depth2_source_2 $depth2_destination_2" \
  "3 4 $depth2_source_3 $depth2_destination_3" > "$depth2_manifest"
! native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 2 \
  >/dev/null 2> "$test_dir/depth2-out-of-range-lane.err"
grep -Fq 'manifest row is invalid for source 3' "$test_dir/depth2-out-of-range-lane.err"

# Make the manifest match the modified destination artifact so validation
# reaches, and rejects, the source/destination cross-lane check.
write_address '\102' "$depth2_wallet_dir/dest-0.addr"
depth2_cross_lane_destination_0=$(native_payment_lanes_address_hex "$depth2_wallet_dir/dest-0.addr")
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 2 4 4' \
  "0 0 $depth2_source_0 $depth2_cross_lane_destination_0" \
  "1 1 $depth2_source_1 $depth2_destination_1" \
  "2 2 $depth2_source_2 $depth2_destination_2" \
  "3 3 $depth2_source_3 $depth2_destination_3" > "$depth2_manifest"
! native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 2 \
  >/dev/null 2> "$test_dir/depth2-cross-lane.err"
grep -Fq 'source/destination pair is not same-lane for source 0' "$test_dir/depth2-cross-lane.err"

# Restore and revalidate the canonical fixture for subsequent readiness cases.
write_address '\002' "$depth2_wallet_dir/dest-0.addr"
printf '%s\n' \
  'NATIVE_PAYMENT_LANES_MANIFEST_V1 2 4 4' \
  "0 0 $depth2_source_0 $depth2_destination_0" \
  "1 1 $depth2_source_1 $depth2_destination_1" \
  "2 2 $depth2_source_2 $depth2_destination_2" \
  "3 3 $depth2_source_3 $depth2_destination_3" > "$depth2_manifest"
native_payment_lanes_validate_manifest "$depth2_manifest" "$depth2_wallet_dir" 0 4 2

ready_output='shard #1 : (0,4000000000000000,10):AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB @ 1 lt 1 .. 2
shard #2 : (0,C000000000000000,10):CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD @ 1 lt 1 .. 2'
native_payment_lanes_shards_are_ready "$ready_output"
! native_payment_lanes_shards_are_ready 'shard #1 : (0,8000000000000000,10):A:B @ 1 lt 1 .. 2'

depth2_ready_output='shard #1 : (0,2000000000000000,10):AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB @ 1 lt 1 .. 2
shard #2 : (0,6000000000000000,10):CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD @ 1 lt 1 .. 2
shard #3 : (0,A000000000000000,10):EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE:FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF @ 1 lt 1 .. 2
shard #4 : (0,E000000000000000,10):AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB @ 1 lt 1 .. 2'
depth2_prefixes='2000000000000000
6000000000000000
A000000000000000
E000000000000000'
[ "$(native_payment_lanes_expected_shard_prefixes 2)" = "$depth2_prefixes" ]
native_payment_lanes_shards_are_ready "$depth2_ready_output" 2
! native_payment_lanes_shards_are_ready "$ready_output" 2
! native_payment_lanes_shards_are_ready "$depth2_ready_output" 1
! native_payment_lanes_shards_are_ready "$depth2_ready_output" 3 >/dev/null 2>&1

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
grep -Fq '"lane_depth":1' "$test_dir/readiness.json"
grep -Fq '"lane_count":2' "$test_dir/readiness.json"

printf '%s\n' "$depth2_ready_output" > "$test_dir/allshards.txt"
NATIVE_LOAD_LITE_CLIENT_BIN=lite-client \
  native_payment_lanes_wait_for_shards "$test_dir/global.config.json" 2 1 1 2 \
  > "$test_dir/depth2-readiness.json"
grep -Fq '"event":"ready_observation"' "$test_dir/depth2-readiness.json"
grep -Fq '"lane_depth":2' "$test_dir/depth2-readiness.json"
grep -Fq '"lane_count":4' "$test_dir/depth2-readiness.json"


# Depth 3 distinguishes all eight top-three-bit lanes, including neighboring
# addresses which still shared a depth-2 lane. Keep source range extraction O(N).
depth3_wallet_dir=$test_dir/depth3-wallets
mkdir -p "$depth3_wallet_dir"
depth3_manifest=$depth3_wallet_dir/native-payment-lanes.manifest
printf '%s\n' 'NATIVE_PAYMENT_LANES_MANIFEST_V1 3 8 8' > "$depth3_manifest"
for index in 0 1 2 3 4 5 6 7; do
  touch "$depth3_wallet_dir/source-$index.pk" "$depth3_wallet_dir/dest-$index.pub"
  write_address "$(printf '\\%03o' "$((index * 32 + 1))")" "$depth3_wallet_dir/source-$index.addr"
  write_address "$(printf '\\%03o' "$((index * 32 + 2))")" "$depth3_wallet_dir/dest-$index.addr"
  [ "$(native_payment_lanes_address_lane "$depth3_wallet_dir/source-$index.addr" 3)" -eq "$index" ]
  printf '%s %s %s %s\n' "$index" "$index" \
    "$(native_payment_lanes_address_hex "$depth3_wallet_dir/source-$index.addr")" \
    "$(native_payment_lanes_address_hex "$depth3_wallet_dir/dest-$index.addr")" >> "$depth3_manifest"
done
printf '0\n' > "$awk_counter"
native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 3
[ "$(cat "$awk_counter")" -eq 1 ]
native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 3 4 3
! native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 2 >/dev/null 2>&1

nibble_index=0
for nibble in 0 1 2 3 4 5 6 7 8 9 A B C D E F; do
  [ "$(native_payment_lanes_hex_lane "${nibble}0" 3)" -eq "$((nibble_index / 2))" ]
  nibble_index=$((nibble_index + 1))
done
[ "$(native_payment_lanes_hex_lane f0 3)" -eq 7 ]
! native_payment_lanes_hex_lane z0 3 >/dev/null 2>&1

cp "$depth3_manifest" "$test_dir/depth3-manifest.good"
sed '1s/3 8/3 4/' "$test_dir/depth3-manifest.good" > "$depth3_manifest"
! native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 3 >/dev/null 2>&1
sed 's/^7 7 /7 8 /' "$test_dir/depth3-manifest.good" > "$depth3_manifest"
! native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 3 >/dev/null 2>&1
sed '$d' "$test_dir/depth3-manifest.good" > "$depth3_manifest"
! native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 3 >/dev/null 2>&1
cat "$test_dir/depth3-manifest.good" > "$depth3_manifest"
sed -n '2p' "$test_dir/depth3-manifest.good" >> "$depth3_manifest"
! native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 3 >/dev/null 2>&1
write_address '\042' "$depth3_wallet_dir/dest-0.addr"
cross_destination=$(native_payment_lanes_address_hex "$depth3_wallet_dir/dest-0.addr")
awk -v dst="$cross_destination" 'NR == 2 {$4=dst} {print}' "$test_dir/depth3-manifest.good" > "$depth3_manifest"
! native_payment_lanes_validate_manifest "$depth3_manifest" "$depth3_wallet_dir" 0 8 3 \
  >/dev/null 2> "$test_dir/depth3-cross-lane.err"
grep -Fq 'source/destination pair is not same-lane for source 0' "$test_dir/depth3-cross-lane.err"

depth3_prefixes='1000000000000000
3000000000000000
5000000000000000
7000000000000000
9000000000000000
B000000000000000
D000000000000000
F000000000000000'
[ "$(native_payment_lanes_expected_shard_prefixes 3)" = "$depth3_prefixes" ]
depth3_ready_output=$(printf '%s\n' "$depth3_prefixes" |
  awk '{printf "shard #%d : (0,%s,10):A:B @ 1 lt 1 .. 2\n", NR, $0}')
native_payment_lanes_shards_are_ready "$depth3_ready_output" 3
! native_payment_lanes_shards_are_ready "$depth3_ready_output" 2
! native_payment_lanes_shards_are_ready "$depth2_ready_output" 3
! native_payment_lanes_shards_are_ready "$(printf '%s\n' "$depth3_ready_output" | sed '$d')" 3
! native_payment_lanes_shards_are_ready "$(printf '%s\n' "$depth3_ready_output" | sed 's/F000000000000000/E000000000000000/')" 3
! native_payment_lanes_shards_are_ready "$depth3_ready_output
shard #9 : (0,1000000000000000,11):A:B @ 1 lt 1 .. 2" 3
! native_payment_lanes_shards_are_ready "$depth3_ready_output
shard #9 : (1,8000000000000000,11):A:B @ 1 lt 1 .. 2" 3
! native_payment_lanes_shards_are_ready "$depth3_ready_output
shard #9 : (0,1000,11):A:B @ 1 lt 1 .. 2" 3
printf '%s\n' "$depth3_ready_output" > "$test_dir/allshards.txt"
NATIVE_LOAD_LITE_CLIENT_BIN=lite-client \
  native_payment_lanes_wait_for_shards "$test_dir/global.config.json" 2 1 1 3 \
  > "$test_dir/depth3-readiness.json"
grep -Fq '"event":"ready_observation"' "$test_dir/depth3-readiness.json"
grep -Fq '"lane_depth":3' "$test_dir/depth3-readiness.json"
grep -Fq '"lane_count":8' "$test_dir/depth3-readiness.json"
