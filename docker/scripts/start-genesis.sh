#!/bin/bash

INTERNAL_IP=$(hostname -I | tr -d " ")
PUBLIC_PORT=${PUBLIC_PORT:-40001}
CONSOLE_PORT=${CONSOLE_PORT:-40002}
DHT_PORT=${DHT_PORT:-40003}
LITE_PORT=${LITE_PORT:-40004}

echo Current INTERNAL_IP $INTERNAL_IP
echo Custom EXTERNAL_IP $EXTERNAL_IP

if [ "$EXTERNAL_IP" ]; then
  INTERNAL_IP=$EXTERNAL_IP
fi

export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont/
echo "pwd $(pwd)"

initialized=0
if [ -f "/var/ton-work/db/state/IDENTITY" ]; then
  echo
  echo "Found non-empty state; Skip initialization";
  initialized=1
  echo
else
  echo
  echo "Creating zero state..."
  echo
  mkdir -p /var/ton-work/db/{keyring,static,import}
  cd /var/ton-work/db/keyring

  read -r VAL_ID_HEX VAL_ID_BASE64 <<< $(generate-random-id -m keys -n validator)
  cp validator $VAL_ID_HEX
  rm validator
  fift -s <<< $(echo '"validator.pub" file>B 4 B| nip "validator-keys.pub" B>file')
  echo "Validator key short_id "$VAL_ID_HEX

  cp validator-keys.pub /usr/share/ton/smartcont/
  cp /usr/share/ton/smartcont/auto/highload-wallet-v2-code.fif /usr/share/ton/smartcont/highload-wallet-v2-code.fif

  cd /usr/share/ton/smartcont/

  HIDE_PRIVATE_KEYS=${HIDE_PRIVATE_KEYS:-"false"}
  echo HIDE_PRIVATE_KEYS=$HIDE_PRIVATE_KEYS

  if [ "$HIDE_PRIVATE_KEYS" == "true" ]; then
    echo "regenerate private keys"
    rm validator-1.pk validator-2.pk validator-3.pk validator-4.pk validator-5.pk validator.pk faucet-highload.pk faucet.pk
  fi
  # ---------------------------------------------------------
  # start setup genesis
  if [ "$CUSTOM_CONFIG_SMC_URL" ]; then
    echo "Installing new configuration smart-contract..."
    wget -O /usr/share/ton/smartcont/auto/new-custom-config.fif $CUSTOM_CONFIG_SMC_URL
    CONFIG_CODE_FIF="new-custom-config.fif"
  fi

  CONFIG_CODE_FIF=${CONFIG_CODE_FIF:-"config-code.fif"}
  echo CONFIG_CODE_FIF=$CONFIG_CODE_FIF
  sed -i "s/CONFIG_CODE_FIF/$CONFIG_CODE_FIF/g" gen-zerostate.fif

  GLOBAL_ID=${GLOBAL_ID:--217}
  echo GLOBAL_ID=$GLOBAL_ID
  sed -i "s/GLOBAL_ID/$GLOBAL_ID/g" gen-zerostate.fif

  BLOCKCHAIN_INITIAL_BALANCE=${BLOCKCHAIN_INITIAL_BALANCE:-5000000000}
  echo BLOCKCHAIN_INITIAL_BALANCE=$BLOCKCHAIN_INITIAL_BALANCE
  sed -i "s/BLOCKCHAIN_INITIAL_BALANCE/$BLOCKCHAIN_INITIAL_BALANCE/g" gen-zerostate.fif

  MAX_VALIDATORS=${MAX_VALIDATORS:-1000}
  echo MAX_VALIDATORS=$MAX_VALIDATORS
  sed -i "s/MAX_VALIDATORS/$MAX_VALIDATORS/g" gen-zerostate.fif

  MAX_MAIN_VALIDATORS=${MAX_MAIN_VALIDATORS:-100}
  echo MAX_MAIN_VALIDATORS=$MAX_MAIN_VALIDATORS
  sed -i "s/MAX_MAIN_VALIDATORS/$MAX_MAIN_VALIDATORS/g" gen-zerostate.fif

  MIN_VALIDATORS=${MIN_VALIDATORS:-1}
  echo MIN_VALIDATORS=$MIN_VALIDATORS
  sed -i "s/MIN_VALIDATORS/$MIN_VALIDATORS/g" gen-zerostate.fif

  MIN_STAKE=${MIN_STAKE:-1000000}
  echo MIN_STAKE=$MIN_STAKE
  sed -i "s/MIN_STAKE/$MIN_STAKE/g" gen-zerostate.fif

  MAX_STAKE=${MAX_STAKE:-1000000000}
  echo MAX_STAKE=$MAX_STAKE
  sed -i "s/MAX_STAKE/$MAX_STAKE/g" gen-zerostate.fif

  MAX_FACTOR=${MAX_FACTOR:-10}
  echo MAX_FACTOR=$MAX_FACTOR
  sed -i "s/MAX_FACTOR/$MAX_FACTOR/g" gen-zerostate.fif

  MIN_TOTAL_STAKE=${MIN_TOTAL_STAKE:-10000}
  echo MIN_TOTAL_STAKE=$MIN_TOTAL_STAKE
  sed -i "s/MIN_TOTAL_STAKE/$MIN_TOTAL_STAKE/g" gen-zerostate.fif

  ELECTION_START_BEFORE=${ELECTION_START_BEFORE:-900}
  echo ELECTION_START_BEFORE=$ELECTION_START_BEFORE
  sed -i "s/ELECTION_START_BEFORE/$ELECTION_START_BEFORE/g" gen-zerostate.fif

  ELECTION_END_BEFORE=${ELECTION_END_BEFORE:-300}
  echo ELECTION_END_BEFORE=$ELECTION_END_BEFORE
  sed -i "s/ELECTION_END_BEFORE/$ELECTION_END_BEFORE/g" gen-zerostate.fif

  ELECTION_STAKE_FROZEN=${ELECTION_STAKE_FROZEN:-180}
  echo ELECTION_STAKE_FROZEN=$ELECTION_STAKE_FROZEN
  sed -i "s/ELECTION_STAKE_FROZEN/$ELECTION_STAKE_FROZEN/g" gen-zerostate.fif

  ORIGINAL_VALIDATOR_SET_VALID_FOR=${ORIGINAL_VALIDATOR_SET_VALID_FOR:-120}
  echo ORIGINAL_VALIDATOR_SET_VALID_FOR=$ORIGINAL_VALIDATOR_SET_VALID_FOR
  sed -i "s/ORIGINAL_VALIDATOR_SET_VALID_FOR/$ORIGINAL_VALIDATOR_SET_VALID_FOR/g" gen-zerostate.fif

  BIT_PRICE_PER_SECOND_MC=${BIT_PRICE_PER_SECOND_MC:-1000}
  echo BIT_PRICE_PER_SECOND_MC=$BIT_PRICE_PER_SECOND_MC
  sed -i "s/BIT_PRICE_PER_SECOND_MC/$BIT_PRICE_PER_SECOND_MC/g" gen-zerostate.fif

  CELL_PRICE_PER_SECOND_MC=${CELL_PRICE_PER_SECOND_MC:-500000}
  echo CELL_PRICE_PER_SECOND_MC=$CELL_PRICE_PER_SECOND_MC
  sed -i "s/CELL_PRICE_PER_SECOND_MC/$CELL_PRICE_PER_SECOND_MC/g" gen-zerostate.fif

  BIT_PRICE_PER_SECOND=${BIT_PRICE_PER_SECOND:-1}
  echo BIT_PRICE_PER_SECOND=$BIT_PRICE_PER_SECOND
  sed -i "s/BIT_PRICE_PER_SECOND/$BIT_PRICE_PER_SECOND/g" gen-zerostate.fif

  CELL_PRICE_PER_SECOND=${CELL_PRICE_PER_SECOND:-500}
  echo CELL_PRICE_PER_SECOND=$CELL_PRICE_PER_SECOND
  sed -i "s/CELL_PRICE_PER_SECOND/$CELL_PRICE_PER_SECOND/g" gen-zerostate.fif

  CELL_PRICE_MC=${CELL_PRICE_MC:-1000000}
  echo CELL_PRICE_MC=$CELL_PRICE_MC
  sed -i "s/CELL_PRICE_MC/$CELL_PRICE_MC/g" gen-zerostate.fif

  GAS_PRICE_MC=${GAS_PRICE_MC:-10000}
  echo GAS_PRICE_MC=$GAS_PRICE_MC
  sed -i "s/GAS_PRICE_MC/$GAS_PRICE_MC/g" gen-zerostate.fif

  CELL_PRICE=${CELL_PRICE:-100000}
  echo CELL_PRICE=$CELL_PRICE
  sed -i "s/CELL_PRICE/$CELL_PRICE/g" gen-zerostate.fif

  GAS_PRICE=${GAS_PRICE:-1000}
  echo GAS_PRICE=$GAS_PRICE
  sed -i "s/GAS_PRICE/$GAS_PRICE/g" gen-zerostate.fif

  SIMPLE_FAUCET_INITIAL_BALANCE=${SIMPLE_FAUCET_INITIAL_BALANCE:-1000000}
  echo SIMPLE_FAUCET_INITIAL_BALANCE=$SIMPLE_FAUCET_INITIAL_BALANCE
  sed -i "s/SIMPLE_FAUCET_INITIAL_BALANCE/$SIMPLE_FAUCET_INITIAL_BALANCE/g" gen-zerostate.fif

  HIGHLOAD_FAUCET_INITIAL_BALANCE=${HIGHLOAD_FAUCET_INITIAL_BALANCE:-1000000}
  echo HIGHLOAD_FAUCET_INITIAL_BALANCE=$HIGHLOAD_FAUCET_INITIAL_BALANCE
  sed -i "s/HIGHLOAD_FAUCET_INITIAL_BALANCE/$HIGHLOAD_FAUCET_INITIAL_BALANCE/g" gen-zerostate.fif

  DATA_FAUCET_INITIAL_BALANCE=${DATA_FAUCET_INITIAL_BALANCE:-1000000}
  echo DATA_FAUCET_INITIAL_BALANCE=$DATA_FAUCET_INITIAL_BALANCE
  sed -i "s/DATA_FAUCET_INITIAL_BALANCE/$DATA_FAUCET_INITIAL_BALANCE/g" gen-zerostate.fif

  VALIDATOR_0_INITIAL_BALANCE=${VALIDATOR_0_INITIAL_BALANCE:-500000000}
  echo VALIDATOR_0_INITIAL_BALANCE=$VALIDATOR_0_INITIAL_BALANCE
  sed -i "s/VALIDATOR_0_INITIAL_BALANCE/$VALIDATOR_0_INITIAL_BALANCE/g" gen-zerostate.fif

  VALIDATOR_1_INITIAL_BALANCE=${VALIDATOR_1_INITIAL_BALANCE:-500000000}
  echo VALIDATOR_1_INITIAL_BALANCE=$VALIDATOR_1_INITIAL_BALANCE
  sed -i "s/VALIDATOR_1_INITIAL_BALANCE/$VALIDATOR_1_INITIAL_BALANCE/g" gen-zerostate.fif

  VALIDATOR_2_INITIAL_BALANCE=${VALIDATOR_2_INITIAL_BALANCE:-500000000}
  echo VALIDATOR_2_INITIAL_BALANCE=$VALIDATOR_2_INITIAL_BALANCE
  sed -i "s/VALIDATOR_2_INITIAL_BALANCE/$VALIDATOR_2_INITIAL_BALANCE/g" gen-zerostate.fif

  VALIDATOR_3_INITIAL_BALANCE=${VALIDATOR_3_INITIAL_BALANCE:-500000000}
  echo VALIDATOR_3_INITIAL_BALANCE=$VALIDATOR_3_INITIAL_BALANCE
  sed -i "s/VALIDATOR_3_INITIAL_BALANCE/$VALIDATOR_3_INITIAL_BALANCE/g" gen-zerostate.fif

  VALIDATOR_4_INITIAL_BALANCE=${VALIDATOR_4_INITIAL_BALANCE:-500000000}
  echo VALIDATOR_4_INITIAL_BALANCE=$VALIDATOR_4_INITIAL_BALANCE
  sed -i "s/VALIDATOR_4_INITIAL_BALANCE/$VALIDATOR_4_INITIAL_BALANCE/g" gen-zerostate.fif

  VALIDATOR_5_INITIAL_BALANCE=${VALIDATOR_5_INITIAL_BALANCE:-500000000}
  echo VALIDATOR_5_INITIAL_BALANCE=$VALIDATOR_5_INITIAL_BALANCE
  sed -i "s/VALIDATOR_5_INITIAL_BALANCE/$VALIDATOR_5_INITIAL_BALANCE/g" gen-zerostate.fif

  VERSION_CAPABILITIES=${VERSION_CAPABILITIES:-11}
  echo VERSION_CAPABILITIES=$VERSION_CAPABILITIES
  sed -i "s/VERSION_CAPABILITIES/$VERSION_CAPABILITIES/g" gen-zerostate.fif

  VALIDATION_PERIOD=${VALIDATION_PERIOD:-1200}
  echo VALIDATION_PERIOD=$VALIDATION_PERIOD
  sed -i "s/VALIDATION_PERIOD/$VALIDATION_PERIOD/g" gen-zerostate.fif

  ACTUAL_MIN_SPLIT=${ACTUAL_MIN_SPLIT:-0}
  echo ACTUAL_MIN_SPLIT=$ACTUAL_MIN_SPLIT
  sed -i "s/ACTUAL_MIN_SPLIT/$ACTUAL_MIN_SPLIT/g" gen-zerostate.fif

  MIN_SPLIT=${MIN_SPLIT:-0}
  echo MIN_SPLIT=$MIN_SPLIT
  sed -i "s/MIN_SPLIT/$MIN_SPLIT/g" gen-zerostate.fif

  MAX_SPLIT=${MAX_SPLIT:-4}
  echo MAX_SPLIT=$MAX_SPLIT
  sed -i "s/MAX_SPLIT/$MAX_SPLIT/g" gen-zerostate.fif

  CRITICAL_PARAM_MIN_WINS=${CRITICAL_PARAM_MIN_WINS:-4}
  echo CRITICAL_PARAM_MIN_WINS=$CRITICAL_PARAM_MIN_WINS
  sed -i "s/CRITICAL_PARAM_MIN_WINS/$CRITICAL_PARAM_MIN_WINS/g" gen-zerostate.fif

  CRITICAL_PARAM_MAX_LOSSES=${CRITICAL_PARAM_MAX_LOSSES:-2}
  echo CRITICAL_PARAM_MAX_LOSSES=$CRITICAL_PARAM_MAX_LOSSES
  sed -i "s/CRITICAL_PARAM_MAX_LOSSES/$CRITICAL_PARAM_MAX_LOSSES/g" gen-zerostate.fif

  PROTO_VERSION=${PROTO_VERSION:-5}
  echo PROTO_VERSION=$PROTO_VERSION
  sed -i "s/PROTO_VERSION/$PROTO_VERSION/g" gen-zerostate.fif

  VALIDATORS_PER_SHARD=${VALIDATORS_PER_SHARD:-1}
  echo VALIDATORS_PER_SHARD=$VALIDATORS_PER_SHARD
  sed -i "s/VALIDATORS_PER_SHARD/$VALIDATORS_PER_SHARD/g" gen-zerostate.fif

  VALIDATORS_MASTERCHAIN_NUM=${VALIDATORS_MASTERCHAIN_NUM:-1}
  echo VALIDATORS_MASTERCHAIN_NUM=$VALIDATORS_MASTERCHAIN_NUM
  sed -i "s/VALIDATORS_MASTERCHAIN_NUM/$VALIDATORS_MASTERCHAIN_NUM/g" gen-zerostate.fif


  BLOCK_SIZE_UNDERLOAD_KB=${BLOCK_SIZE_UNDERLOAD_KB:-256}
  echo BLOCK_SIZE_UNDERLOAD_KB=$BLOCK_SIZE_UNDERLOAD_KB
  sed -i "s/BLOCK_SIZE_UNDERLOAD_KB/$BLOCK_SIZE_UNDERLOAD_KB/g" gen-zerostate.fif

  BLOCK_SIZE_SOFT_KB=${BLOCK_SIZE_SOFT_KB:-1024}
  echo BLOCK_SIZE_SOFT_KB=$BLOCK_SIZE_SOFT_KB
  sed -i "s/BLOCK_SIZE_SOFT_KB/$BLOCK_SIZE_SOFT_KB/g" gen-zerostate.fif

  BLOCK_SIZE_HARD_KB=${BLOCK_SIZE_HARD_MB:-2048}
  echo BLOCK_SIZE_HARD_KB=$BLOCK_SIZE_HARD_KB
  sed -i "s/BLOCK_SIZE_HARD_KB/$BLOCK_SIZE_HARD_KB/g" gen-zerostate.fif

  BLOCK_GAS_LIMIT_UNDERLOAD=${BLOCK_GAS_LIMIT_UNDERLOAD:-2000000}
  echo BLOCK_GAS_LIMIT_UNDERLOAD=$BLOCK_GAS_LIMIT_UNDERLOAD
  sed -i "s/BLOCK_GAS_LIMIT_UNDERLOAD/$BLOCK_GAS_LIMIT_UNDERLOAD/g" gen-zerostate.fif

  BLOCK_GAS_LIMIT_SOFT=${BLOCK_GAS_LIMIT_SOFT:-10000000}
  echo BLOCK_GAS_LIMIT_SOFT=$BLOCK_GAS_LIMIT_SOFT
  sed -i "s/BLOCK_GAS_LIMIT_SOFT/$BLOCK_GAS_LIMIT_SOFT/g" gen-zerostate.fif

  BLOCK_GAS_LIMIT_HARD=${BLOCK_GAS_LIMIT_HARD:-20000000}
  echo BLOCK_GAS_LIMIT_HARD=$BLOCK_GAS_LIMIT_HARD
  sed -i "s/BLOCK_GAS_LIMIT_HARD/$BLOCK_GAS_LIMIT_HARD/g" gen-zerostate.fif

  BLOCK_LIMIT_MULTIPLIER=${BLOCK_LIMIT_MULTIPLIER:-1}
  echo BLOCK_LIMIT_MULTIPLIER=$BLOCK_LIMIT_MULTIPLIER
  sed -i "s/BLOCK_LIMIT_MULTIPLIER/$BLOCK_LIMIT_MULTIPLIER/g" gen-zerostate.fif

  MASTERCHAIN_ONLY=${MASTERCHAIN_ONLY:-"false"}
  echo MASTERCHAIN_ONLY=$MASTERCHAIN_ONLY
  if [ "$MASTERCHAIN_ONLY" == "false" ]; then
    echo "With workchains"
    sed -i "s/MASTERCHAIN_ONLY/config.workchains!/g" gen-zerostate.fif
  elif [ "$MASTERCHAIN_ONLY" == "true" ]; then
    echo "Without workchains"
    sed -i "s/MASTERCHAIN_ONLY//g" gen-zerostate.fif
  fi

  NEXT_BLOCK_GENERATION_DELAY=${NEXT_BLOCK_GENERATION_DELAY:-"2"}
  echo NEXT_BLOCK_GENERATION_DELAY=$NEXT_BLOCK_GENERATION_DELAY
  TMP_VAR=$(echo "($NEXT_BLOCK_GENERATION_DELAY*1000)/1" | bc)
  sed -i "s/NEXT_BLOCK_GENERATION_DELAY/$TMP_VAR/g" gen-zerostate.fif
  # end setup genesis
  # ---------------------------------------------------------

  create-state gen-zerostate.fif
  test $? -eq 0 || { echo "Can't generate zero-state"; exit 1; }


  ZEROSTATE_FILEHASH=$(sed ':a;N;$!ba;s/\n//g' <<<$(sed -e "s/\s//g" <<<"$(od -An -t x1 zerostate.fhash)") | awk '{ print toupper($0) }')
  mv zerostate.boc /var/ton-work/db/static/$ZEROSTATE_FILEHASH
  BASESTATE0_FILEHASH=$(sed ':a;N;$!ba;s/\n//g' <<<$(sed -e "s/\s//g" <<<"$(od -An -t x1 basestate0.fhash)") | awk '{ print toupper($0) }')
  mv basestate0.boc /var/ton-work/db/static/$BASESTATE0_FILEHASH

  if [ "$HIDE_PRIVATE_KEYS" == "false" ]; then
    echo "Share private keys via http-server"
    cp main-wallet.pk main-wallet.addr \
      config-master.pk config-master.addr \
      validator-1.pk validator-1.addr \
      validator-2.pk validator-2.addr \
      validator-3.pk validator-3.addr \
      validator-4.pk validator-4.addr \
      validator-5.pk validator-5.addr \
      validator.pk validator.addr \
      faucet-highload.pk faucet-highload.addr \
      faucet.pk faucet.addr \
      /var/ton-work/db/
  fi

  echo "Share private keys via docker shared volume"
  cp main-wallet.pk main-wallet.addr \
    config-master.pk config-master.addr \
    validator-1.pk validator-1.addr \
    validator-2.pk validator-2.addr \
    validator-3.pk validator-3.addr \
    validator-4.pk validator-4.addr \
    validator-5.pk validator-5.addr \
    validator.pk validator.addr \
    faucet-highload.pk faucet-highload.addr \
    faucet.pk faucet.addr \
    /usr/share/data
  chmod 744 /usr/share/data/*

#  echo "Make available for reap and participate"
#  cp validator.pk validator.addr /usr/share/ton
#  chmod 744 /usr/share/ton/*


  cd /var/ton-work/db
  rm -f my-ton-global.config.json
  cp /scripts/ton-private-testnet.config.json.template .
  sed -e "s#ROOT_HASH#$(cat /usr/share/ton/smartcont/zerostate.rhash | base64)#g" -e "s#FILE_HASH#$(cat /usr/share/ton/smartcont/zerostate.fhash | base64)#g" ton-private-testnet.config.json.template > my-ton-global.config.json
  IP=$INTERNAL_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
  [ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))


  echo Creating DHT server at $INTERNAL_IP:$DHT_PORT

  rm -rf dht-server
  mkdir dht-server
  cd dht-server
  cp ../my-ton-global.config.json .
  cp /scripts/example.config.json .
  dht-server -C example.config.json -D . -I "$INTERNAL_IP:$DHT_PORT"

  DHT_NODES=$(generate-random-id -m dht -k keyring/* -a "{
               \"@type\": \"adnl.addressList\",
               \"addrs\": [
                 {
                   \"@type\": \"adnl.address.udp\",
                   \"ip\":  $IPNUM,
                   \"port\": $DHT_PORT
                 }
               ],
               \"version\": 0,
               \"reinit_date\": 0,
               \"priority\": 0,
               \"expire_at\": 0
             }")

  sed -i -e "s#NODES#$(printf "%q" $DHT_NODES)#g" my-ton-global.config.json
  cp my-ton-global.config.json ..

  (dht-server -C my-ton-global.config.json -D . -I "$INTERNAL_IP:$DHT_PORT")&
  PRELIMINARY_DHT_SERVER_RUN=$!
  sleep 1;
  echo DHT server started at $INTERNAL_IP:$DHT_PORT

  echo Initializing genesis node...

  # NODE INIT START

  cd /var/ton-work/db

  # Create config.json, stops automatically
  rm -f config.json
  validator-engine -C /var/ton-work/db/my-ton-global.config.json --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT"

  # Generating server certificate
  read -r SERVER_ID1 SERVER_ID2 <<< $(generate-random-id -m keys -n server)
  echo "Server IDs: $SERVER_ID1 $SERVER_ID2"
  cp server /var/ton-work/db/keyring/$SERVER_ID1

  # Generating client certificate
  read -r CLIENT_ID1 CLIENT_ID2 <<< $(generate-random-id -m keys -n client)
  echo -e "\e[1;32m[+]\e[0m Generated client private certificate $CLIENT_ID1 $CLIENT_ID2"
  echo -e "\e[1;32m[+]\e[0m Generated client public certificate"


  # Adding client permissions
  rm -f control.new
  cp /scripts/control.template .
  sed -e "s/CONSOLE-PORT/\"$(printf "%q" $CONSOLE_PORT)\"/g" -e "s~SERVER-ID~\"$(printf "%q" $SERVER_ID2)\"~g" -e "s~CLIENT-ID~\"$(printf "%q" $CLIENT_ID2)\"~g" control.template > control.new
  sed -e "s~\"control\"\ \:\ \[~$(printf "%q" $(cat control.new))~g" config.json > config.json.new
  mv config.json.new config.json

  # start the full node for some time to add validation keys
  (validator-engine -C /var/ton-work/db/my-ton-global.config.json --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT")&
  PRELIMINARY_VALIDATOR_RUN=$!
  sleep 4;

  echo Adding keys to validator-engine-console...

  read -r t1 t2 t3 NEW_NODE_KEY <<< $(echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "newkey"|tail -n 1)
  read -r t1 t2 t3 NEW_VAL_ADNL <<< $(echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "newkey"|tail -n 1)

  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "addpermkey $VAL_ID_HEX 0 $(($(date +"%s")+31414590))" 2>&1
  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "addtempkey $VAL_ID_HEX $VAL_ID_HEX $(($(date +"%s")+31414590))" 2>&1
  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "addadnl $NEW_VAL_ADNL 0" 2>&1
  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "addadnl $VAL_ID_HEX 0" 2>&1

  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "addvalidatoraddr $VAL_ID_HEX $NEW_VAL_ADNL $(($(date +"%s")+31414590))" 2>&1
  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "addadnl $NEW_NODE_KEY 0" 2>&1
  echo | validator-engine-console -k client -p server.pub -v 0 -a  "$INTERNAL_IP:$CONSOLE_PORT" -rc "changefullnodeaddr $NEW_NODE_KEY" 2>&1
  echo | validator-engine-console -k client -p server.pub -v 0 -a "$INTERNAL_IP:$CONSOLE_PORT" -rc "importf keyring/$VAL_ID_HEX" 2>&1
  kill $PRELIMINARY_VALIDATOR_RUN;

  rm -rf /var/ton-work/log*

  echo Genesis node initilized
  echo
  # current dir /var/ton-work/db
  # install lite-server using predefined lite-server keys
  #read -r LITESERVER_ID1 LITESERVER_ID2 <<< $(generate-random-id -m keys -n liteserver)
  #echo "Liteserver IDs: $LITESERVER_ID1 $LITESERVER_ID2"
  #cp liteserver /var/ton-work/db/keyring/$LITESERVER_ID1
  echo "Liteserver IDs: DA46DE8CCCED9AB6F29447B334636FBE07F7F4CAE6B6833D26AF1240A1BB34B1 2kbejMztmrbylEezNGNvvgf39MrmtoM9Jq8SQKG7NLE="
  cp /scripts/liteserver /var/ton-work/db/
  cp /scripts/liteserver.pub /var/ton-work/db/
  cp /scripts/liteserver /var/ton-work/db/keyring/DA46DE8CCCED9AB6F29447B334636FBE07F7F4CAE6B6833D26AF1240A1BB34B1

  LITESERVERS=$(printf "%q" "\"liteservers\":[{\"id\":\"2kbejMztmrbylEezNGNvvgf39MrmtoM9Jq8SQKG7NLE=\",\"port\":$LITE_PORT}")
  sed -e "s~\"liteservers\"\ \:\ \[~$LITESERVERS~g" config.json > config.json.liteservers
  mv config.json.liteservers config.json

  IP=$INTERNAL_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
  [ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))
  LITESERVERSCONFIG=$(printf "%q" "\"liteservers\":[{\"id\":{\"key\":\"E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY=\", \"@type\":\"pub.ed25519\"}, \"port\":$LITE_PORT, \"ip\":$IPNUM }]}")
  sed -i -e "\$s#\(.*\)\}#\1,$LITESERVERSCONFIG#" my-ton-global.config.json
  python3 -c 'import json; f=open("my-ton-global.config.json", "r"); config=json.loads(f.read()); f.close(); f=open("my-ton-global.config.json", "w");f.write(json.dumps(config, indent=2)); f.close()';

  cp my-ton-global.config.json global.config.json
  rm my-ton-global.config.json control.new control.template ton-private-testnet.config.json.template

  OLDNUM=$IPNUM
  if [ "$EXTERNAL_IP" ]; then
    IP=$EXTERNAL_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
    [ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))
    cp global.config.json external.global.config.json
    sed -i "s/$OLDNUM/$IPNUM/g" external.global.config.json
    cp external.global.config.json /usr/share/data/
  fi

  cp global.config.json localhost.global.config.json
  sed -i "s/$OLDNUM/2130706433/g" localhost.global.config.json

  echo Restart DHT server
  echo
  kill $PRELIMINARY_DHT_SERVER_RUN;
  sleep 1
fi

EMBEDDED_FILE_HTTP_SERVER=${EMBEDDED_FILE_HTTP_SERVER:-"false"}
echo EMBEDDED_FILE_HTTP_SERVER=$EMBEDDED_FILE_HTTP_SERVER

EMBEDDED_FILE_HTTP_SERVER_PORT=${EMBEDDED_FILE_HTTP_SERVER_PORT:-8888}
echo EMBEDDED_FILE_HTTP_SERVER_PORT=$EMBEDDED_FILE_HTTP_SERVER_PORT

if [ "$EMBEDDED_FILE_HTTP_SERVER" == "true" ]; then
  # start file http server
  nohup python3 -m http.server -d /usr/share/data/ $EMBEDDED_FILE_HTTP_SERVER_PORT &
  echo Simple HTTP server runs on:
  echo
  echo http://127.0.0.1:$EMBEDDED_FILE_HTTP_SERVER_PORT/
  echo http://$INTERNAL_IP:$EMBEDDED_FILE_HTTP_SERVER_PORT/
  echo
  echo wget http://$INTERNAL_IP:$EMBEDDED_FILE_HTTP_SERVER_PORT/global.config.json
fi

cd /var/ton-work/db
cp global.config.json /usr/share/data/
cp localhost.global.config.json /usr/share/data/
cp config.json /usr/share/data/

nohup dht-server -C /var/ton-work/db/global.config.json -D /var/ton-work/db/dht-server -I "$INTERNAL_IP:$DHT_PORT"&
echo DHT server started at $INTERNAL_IP:$DHT_PORT
echo
echo Lite server started at $INTERNAL_IP:$LITE_PORT
echo

VERBOSITY=${VERBOSITY:-1}
echo VERBOSITY=$VERBOSITY

if [ $initialized -eq 0 ]; then
  /scripts/post-genesis.sh &
fi

echo Started $NAME at $INTERNAL_IP:$PUBLIC_PORT
echo validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT" --initial-sync-delay 0.0 $CUSTOM_PARAMETERS
validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --daemonize --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT" --initial-sync-delay 0.0 $CUSTOM_PARAMETERS


