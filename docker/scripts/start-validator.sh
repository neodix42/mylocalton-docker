# next to this script you should have ton-private-testnet.config.json.template, example.config.json, control.template and gen-zerostate.fif

PUBLIC_IP=$(hostname -I | tr -d " ")
export PUBLIC_PORT=40001
export CONSOLE_PORT=40002
LITE_PORT=40004

echo "Current PUBLIC_IP $PUBLIC_IP"


if [ ! -f "/var/ton-work/db/global.config.json" ]; then
  echo "waiting 90 seconds for genesis to be ready very first time..."
  sleep 90
  echo "Downloading global.config.json from genesis..."
  wget http://$GENESIS_IP:8000/global.config.json -P /var/ton-work/db
else
#  echo "waiting 20 seconds for genesis to be ready..."
#  sleep 20
  echo "/var/ton-work/db/global.config.json from genesis already exists"
fi

cd /usr/share/ton

if [ ! -f "validator.pk" ]; then
  # HIDE_PRIVATE_KEYS == false, private keys are not copied by genesis to docker shared volume /usr/share/data/
  if [ ! -f "/usr/share/data/validator.pk" ]; then
    echo "downloading validator.pk from genesis to $NAME..."
    if [ "$NAME" = "validator-1" ]; then
      wget http://$GENESIS_IP:8000/validator-1.pk -O validator.pk
      wget http://$GENESIS_IP:8000/validator-1.addr -O validator.addr
    elif [ "$NAME" = "validator-2" ]; then
      wget http://$GENESIS_IP:8000/validator-2.pk -O validator.pk
      wget http://$GENESIS_IP:8000/validator-2.addr -O validator.addr
    elif [ "$NAME" = "validator-3" ]; then
      wget http://$GENESIS_IP:8000/validator-3.pk -O validator.pk
      wget http://$GENESIS_IP:8000/validator-3.addr -O validator.addr
    elif [ "$NAME" = "validator-4" ]; then
      wget http://$GENESIS_IP:8000/validator-4.pk -O validator.pk
      wget http://$GENESIS_IP:8000/validator-4.addr -O validator.addr
    elif [ "$NAME" = "validator-5" ]; then
      wget http://$GENESIS_IP:8000/validator-5.pk -O validator.pk
      wget http://$GENESIS_IP:8000/validator-5.addr -O validator.addr
    fi
  else
    echo "copying validator.pk from genesis /usr/share/data to $NAME..."
    if [ "$NAME" = "validator-1" ]; then
      cp /usr/share/data/validator-1.pk validator.pk
      cp /usr/share/data/validator-1.addr validator.addr
    elif [ "$NAME" = "validator-2" ]; then
      cp /usr/share/data/validator-2.pk validator.pk
      cp /usr/share/data/validator-2.addr validator.addr
    elif [ "$NAME" = "validator-3" ]; then
      cp /usr/share/data/validator-3.pk validator.pk
      cp /usr/share/data/validator-3.addr validator.addr
    elif [ "$NAME" = "validator-4" ]; then
      cp /usr/share/data/validator-4.pk validator.pk
      cp /usr/share/data/validator-4.addr validator.addr
    elif [ "$NAME" = "validator-5" ]; then
      cp /usr/share/data/validator-5.pk validator.pk
      cp /usr/share/data/validator-5.addr validator.addr
    fi
  fi
else
  echo "validator.pk already received/copied."
fi

cd /var/ton-work/db

if [ ! -f "config.json" ]; then
  echo "config.json does not exist, start very first time"

  # very first start to generate config.json only, stops automatically
  validator-engine -C /var/ton-work/db/global.config.json --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT"
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

echo NODE IP           $PUBLIC_IP
echo NODE_PORT         $PUBLIC_PORT
echo VALIDATOR_CONSOLE $CONSOLE_PORT
echo LITESERVER_PORT   $LITE_PORT
echo

if [ ! "$VERBOSITY" ]; then
  VERBOSITY=1
else
  VERBOSITY=$VERBOSITY
fi

echo Started $NAME at $PUBLIC_IP:$PUBLIC_PORT
validator-engine -C /var/ton-work/db/global.config.json -v $VERBOSITY --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT"