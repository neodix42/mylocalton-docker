# next to this script you should have ton-private-testnet.config.json.template, example.config.json, control.template and gen-zerostate.fif

if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP=$(hostname -I)
fi

echo Current PUBLIC_IP $PUBLIC_IP

PUBLIC_PORT=41001
LITE_PORT=41004

cd /var/ton-work/db

wget http://172.28.1.1:8000/global.config.json
echo Downloaded global config from genesis

if [ ! -f "config.json" ]; then
  echo config.json does not exist, start very first time

  # very first start to generate config.json only, stops automatically
  validator-engine -C /var/ton-work/db/global.config.json --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT"
  sleep 2

  # install lite-server
  read -r LITESERVER_ID1 LITESERVER_ID2 <<< $(generate-random-id -m keys -n liteserver)
  echo "Liteserver IDs: $LITESERVER_ID1 $LITESERVER_ID2"
  cp liteserver /var/ton-work/db/keyring/$LITESERVER_ID1

  LITESERVERS=$(printf "%q" "\"liteservers\":[{\"id\":\"$LITESERVER_ID2\",\"port\":\"$LITE_PORT\"}")
  sed -e "s~\"liteservers\"\ \:\ \[~$LITESERVERS~g" config.json > config.json.liteservers
  mv config.json.liteservers config.json

fi
echo Starting validator at $PUBLIC_IP:$PUBLIC_PORT
validator-engine -C /var/ton-work/db/global.config.json --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT"