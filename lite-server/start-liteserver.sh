#!/bin/bash
# next to this script you should have control.template

get_preferred_ip() {
  for ip in $(hostname -I); do
    if [[ $ip == 172.28.* ]]; then
      echo "$ip"
      return
    fi
  done
  # Fallback to the first IP if no 172.28.* IP found
  echo "$(hostname -I | awk '{print $1}')"
}

INTERNAL_IP=$(get_preferred_ip)
export PUBLIC_PORT=${PUBLIC_PORT:-30001}
export CONSOLE_PORT=${CONSOLE_PORT:-30002}
LITE_PORT=${LITE_SERVER_PORT:-30004}

echo "Current INTERNAL_IP $INTERNAL_IP"
echo "Current GENESIS_IP $GENESIS_IP"
echo "Current EXTERNAL_IP $EXTERNAL_IP"

if [ "$EXTERNAL_IP" ]; then
  INTERNAL_IP=$EXTERNAL_IP
fi

echo "Current INTERNAL_IP $INTERNAL_IP"
echo "Current GENESIS_IP $GENESIS_IP"
echo "Current EXTERNAL_IP $EXTERNAL_IP"

if [ ! -f "/var/ton-work/db/global.config.json" ]; then
  echo "genesis is ready..."
  sleep 10
  if [ "$EXTERNAL_IP" ]; then
    echo "Getting external.global.config.json from genesis $GENESIS_IP via http server..."
    wget -O /var/ton-work/db/global.config.json http://$GENESIS_IP:8000/external.global.config.json
    test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/external.global.config.json "; exit 14; }
  elif [ "$GENESIS_IP" ]; then
    echo "Getting global.config.json from genesis $GENESIS_IP via http server..."
    wget -O /var/ton-work/db/global.config.json http://$GENESIS_IP:8000/global.config.json
    test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/global.config.json "; exit 14; }
  else
    echo Neither EXTERNAL_IP nor GENESIS_IP specified.
    exit 11
  fi
else
#  echo "waiting 20 seconds for genesis to be ready..."
#  sleep 20
  echo "/var/ton-work/db/global.config.json from genesis already exists"
fi

cd /var/ton-work/db

if [ ! -f "config.json" ]; then
  echo "config.json does not exist, start very first time"

  # very first start to generate config.json only, stops automatically
  validator-engine -C /var/ton-work/db/global.config.json --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT"
  sleep 2

  # Give access to validator-console
  #
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


  # install lite-server using random lite-server keys

#  read -r LITESERVER_ID1 LITESERVER_ID2 <<< $(generate-random-id -m keys -n liteserver)
#  echo "Liteserver IDs: $LITESERVER_ID1 $LITESERVER_ID2"
#  cp liteserver /var/ton-work/db/keyring/$LITESERVER_ID1
#  LITESERVERS=$(printf "%q" "\"liteservers\":[{\"id\":\"$LITESERVER_ID2\",\"port\":\"$LITE_PORT\"}")
#  sed -e "s~\"liteservers\"\ \:\ \[~$LITESERVERS~g" config.json > config.json.liteservers
#  mv config.json.liteservers config.json
#
#  chmod 777 /var/ton-work/db/liteserver.pub
#  dd if=/var/ton-work/db/liteserver.pub bs=1 skip=4 of=/var/ton-work/db/liteserver.pub.4
#  LITESERVER_PUB=$(base64 /var/ton-work/db/liteserver.pub.4)
#  echo LITESERVER_PUB $LITESERVER_PUB
#  rm -f liteserver.pub.4


  # install lite-server using predefined lite-server keys
  echo "Liteserver IDs: 15F961BE81DA9012E3BAF81593CB40926C0585A4307C534C9581A2E745754CD4 FflhvoHakBLjuvgVk8tAkmwFhaQwfFNMlYGi50V1TNQ="
  cp /scripts/liteserver /var/ton-work/db/
  cp /scripts/liteserver.pub /var/ton-work/db/
  cp /scripts/liteserver /var/ton-work/db/keyring/15F961BE81DA9012E3BAF81593CB40926C0585A4307C534C9581A2E745754CD4
  LITESERVERS=$(printf "%q" "\"liteservers\":[{\"id\":\"FflhvoHakBLjuvgVk8tAkmwFhaQwfFNMlYGi50V1TNQ=\",\"port\":$LITE_PORT}")
  sed -e "s~\"liteservers\"\ \:\ \[~$LITESERVERS~g" config.json > config.json.liteservers
  mv config.json.liteservers config.json

  cat global.config.json
  echo
  echo "Replace genesis lite-server by our lite-server in global.config.json"
  IP=$INTERNAL_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
  [ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))
  LITESERVERSCONFIG=$(printf "%q" "\"liteservers\":[{\"id\":{\"key\":\"Wha42OjSNvDaHOjhZhUZu0zW/+wu/+PaltND/a0FbuI=\", \"@type\":\"pub.ed25519\"}, \"port\":$LITE_PORT, \"ip\":$IPNUM }]}")
  sed -i -e "\$s#\(.*\)\}#\1,$LITESERVERSCONFIG#" global.config.json
  python3 -c 'import json; f=open("global.config.json", "r"); config=json.loads(f.read()); f.close(); f=open("global.config.json", "w");f.write(json.dumps(config, indent=2)); f.close()';

  echo "cat global.config.json"
  cat global.config.json
#  cp my-ton-global.config.json global.config.json
  rm control.new control.template

  OLDNUM=$IPNUM
  if [ "$EXTERNAL_IP" ]; then
    IP=$EXTERNAL_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
    [ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))
    cp global.config.json external.global.config.json
    sed -i "s/$OLDNUM/$IPNUM/g" external.global.config.json
  fi
  echo "cat external.global.config.json"
  cat external.global.config.json

  cp global.config.json localhost.global.config.json
  sed -i "s/$OLDNUM/2130706433/g" localhost.global.config.json

fi

echo NODE IP           $INTERNAL_IP
echo NODE_PORT         $PUBLIC_PORT
echo VALIDATOR_CONSOLE $CONSOLE_PORT
echo LITESERVER_PORT   $LITE_PORT
echo "lite-client -a $INTERNAL_IP:30004 -b Wha42OjSNvDaHOjhZhUZu0zW/+wu/+PaltND/a0FbuI= -c last"
echo

if [ ! "$VERBOSITY" ]; then
  VERBOSITY=1
else
  VERBOSITY=$VERBOSITY
fi

echo Started $NAME at $INTERNAL_IP:$PUBLIC_PORT
echo validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT" $CUSTOM_PARAMETERS
validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT" $CUSTOM_PARAMETERS