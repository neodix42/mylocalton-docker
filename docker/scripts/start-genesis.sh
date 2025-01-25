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

if ( [ -d "state" ] && [ "$(ls -A ./state)" ]); then
  echo
  echo "Found non-empty state; Skip initialization";
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

  VALIDATION_PERIOD=${VALIDATION_PERIOD:-1200}
  echo VALIDATION_PERIOD=$VALIDATION_PERIOD
  sed -i "s/VALIDATION_PERIOD/$VALIDATION_PERIOD/g" gen-zerostate.fif

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

  echo "Make available for reap and participate"
  cp validator.pk validator.addr /usr/share/ton
  chmod 744 /usr/share/ton/*


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

cp global.config.json /usr/share/data/
cp localhost.global.config.json /usr/share/data/

nohup dht-server -C /var/ton-work/db/global.config.json -D /var/ton-work/db/dht-server -I "$INTERNAL_IP:$DHT_PORT"&
echo DHT server started at $INTERNAL_IP:$DHT_PORT
echo
echo Lite server started at $INTERNAL_IP:$LITE_PORT
echo

ENABLE_FILE_HTTP_SERVER=${ENABLE_FILE_HTTP_SERVER:-"true"}
echo ENABLE_FILE_HTTP_SERVER=$ENABLE_FILE_HTTP_SERVER

if [ "$ENABLE_FILE_HTTP_SERVER" == "true" ]; then
  # start file http server
  nohup python3 -m http.server&
  echo Simple HTTP server runs on:
  echo
  echo http://127.0.0.1:8000/
  echo http://$INTERNAL_IP:8000/
  echo
  echo wget http://$INTERNAL_IP:8000/global.config.json
fi

if [ ! "$VERBOSITY" ]; then
  VERBOSITY=1
else
  VERBOSITY=$VERBOSITY
fi

echo Started $NAME at $INTERNAL_IP:$PUBLIC_PORT
validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT"


