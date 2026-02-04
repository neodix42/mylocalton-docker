#!/bin/bash
# next to this script you should have ton-private-testnet.config.json.template, example.config.json, control.template and gen-zerostate.fif

INTERNAL_IP=$(hostname -I | tr -d " ")
export PUBLIC_PORT=${PUBLIC_PORT:-40001}
export CONSOLE_PORT=${CONSOLE_PORT:-40002}
LITE_PORT=${LITE_PORT:-40004}

echo "Current INTERNAL_IP $INTERNAL_IP"


if [ ! -f "/var/ton-work/db/global.config.json" ]; then
  echo "waiting 10 seconds for genesis to be ready very first time..."
  sleep 10
  echo "Getting global.config.json from genesis via shared volume..."
  cp /usr/share/data/global.config.json /var/ton-work/db
else
#  echo "waiting 20 seconds for genesis to be ready..."
#  sleep 20
  echo "/var/ton-work/db/global.config.json from genesis already exists"
fi

echo "NAME=$NAME"

if [ "$NAME" = "genesis" ]; then
    NAME="validator"
fi

if [ ! -f "/usr/share/ton/smartcont/$NAME.pk" ]; then
  echo "/usr/share/ton/smartcont/$NAME.pk is missing!"
  exit 12
else
  echo "/usr/share/ton/smartcont/$NAME.pk exists!"
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

  # install lite-server
  #
  read -r LITESERVER_ID1 LITESERVER_ID2 <<< $(generate-random-id -m keys -n liteserver)
  echo "Liteserver IDs: $LITESERVER_ID1 $LITESERVER_ID2"
  cp liteserver /var/ton-work/db/keyring/$LITESERVER_ID1

  LITESERVERS=$(printf "%q" "\"liteservers\":[{\"id\":\"$LITESERVER_ID2\",\"port\":\"$LITE_PORT\"}")
  sed -e "s~\"liteservers\"\ \:\ \[~$LITESERVERS~g" config.json > config.json.liteservers
  mv config.json.liteservers config.json

fi

echo NODE IP           $INTERNAL_IP
echo NODE_PORT         $PUBLIC_PORT
echo VALIDATOR_CONSOLE $CONSOLE_PORT
echo LITESERVER_PORT   $LITE_PORT
echo

if [ ! "$VERBOSITY" ]; then
  VERBOSITY=1
else
  VERBOSITY=$VERBOSITY
fi

echo Started $NAME at $INTERNAL_IP:$PUBLIC_PORT
echo validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT" --initial-sync-delay 0.0 $CUSTOM_PARAMETERS
validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$INTERNAL_IP:$PUBLIC_PORT" --initial-sync-delay 0.0 $CUSTOM_PARAMETERS