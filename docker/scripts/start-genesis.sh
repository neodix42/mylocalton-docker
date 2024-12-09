# next to this script you should have ton-private-testnet.config.json.template, example.config.json, control.template and gen-zerostate.fif

if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP=127.0.0.1
fi

echo Current PUBLIC_IP $PUBLIC_IP, ubuntu $(hostname -I)

PUBLIC_PORT=40001
CONSOLE_PORT=40002
DHT_PORT=40003
LITE_PORT=40004

MY_DIR=$(pwd)
echo $MY_DIR

cd /var/ton-work/db/keyring

export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont/


read -r VAL_ID_HEX VAL_ID_BASE64 <<< $(generate-random-id -m keys -n validator)
cp validator $VAL_ID_HEX
fift -s <<< $(echo '"validator.pub" file>B 4 B| nip "validator-keys.pub" B>file')
echo "Validator key short_id "$VAL_ID_HEX

cp validator-keys.pub /usr/share/ton/smartcont/

# replace in gen-zerostate.fif parameters - min validators amount, min stake etc

cd /usr/share/ton/smartcont/


echo Creating zero state
echo $PATH
which fift
which create-state
create-state gen-zerostate.fif
test $? -eq 0 || { echo "Can't generate zero-state"; exit 1; }


ZEROSTATE_FILEHASH=$(sed ':a;N;$!ba;s/\n//g' <<<$(sed -e "s/\s//g" <<<"$(od -An -t x1 zerostate.fhash)") | awk '{ print toupper($0) }')
mv zerostate.boc /var/ton-work/db/static/$ZEROSTATE_FILEHASH
BASESTATE0_FILEHASH=$(sed ':a;N;$!ba;s/\n//g' <<<$(sed -e "s/\s//g" <<<"$(od -An -t x1 basestate0.fhash)") | awk '{ print toupper($0) }')
mv basestate0.boc /var/ton-work/db/static/$BASESTATE0_FILEHASH
cp main-wallet.pk main-wallet.addr config-master.pk config-master.addr faucet.pk faucet.addr $MY_DIR/

cd /var/ton-work/db
rm -f my-ton-global.config.json
sed -e "s#ROOT_HASH#$(cat /usr/share/ton/smartcont/zerostate.rhash | base64)#g" -e "s#FILE_HASH#$(cat /usr/share/ton/smartcont/zerostate.fhash | base64)#g" ton-private-testnet.config.json.template > my-ton-global.config.json
IP=$PUBLIC_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
[ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))


echo Creating DHT server at $PUBLIC_IP:$DHT_PORT

rm -rf dht-server
mkdir dht-server
cd dht-server
cp ../my-ton-global.config.json .
cp ../example.config.json .
dht-server -C example.config.json -D . -I "$PUBLIC_IP:$DHT_PORT"

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

(dht-server -C my-ton-global.config.json -D . -I "$PUBLIC_IP:$DHT_PORT")&
PRELIMINARY_DHT_SERVER_RUN=$!
sleep 1;
echo DHT server started at $PUBLIC_IP:$DHT_PORT

echo Initializing genesis node...

# NODE INIT START

cd /var/ton-work/db

# Create config.json, stops automatically
rm -f config.json
validator-engine -C /var/ton-work/db/my-ton-global.config.json --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT"
echo Initial /var/ton-work/db/config.json
cat /var/ton-work/db/config.json


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

echo cat config.json
cat config.json

# start the full node for some time to add validation keys
(validator-engine -C /var/ton-work/db/my-ton-global.config.json --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT")&
PRELIMINARY_VALIDATOR_RUN=$!
sleep 4;

echo Adding keys to validator-engine-console...

read -r t1 t2 t3 NEW_NODE_KEY <<< $(echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "newkey"|tail -n 1)
read -r t1 t2 t3 NEW_VAL_ADNL <<< $(echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "newkey"|tail -n 1)

echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "addpermkey $VAL_ID_HEX 0 $(($(date +"%s")+31414590))" 2>&1
echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "addtempkey $VAL_ID_HEX $VAL_ID_HEX $(($(date +"%s")+31414590))" 2>&1
echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "addadnl $NEW_VAL_ADNL 0" 2>&1
echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "addadnl $VAL_ID_HEX 0" 2>&1

echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "addvalidatoraddr $VAL_ID_HEX $NEW_VAL_ADNL $(($(date +"%s")+31414590))" 2>&1
echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "addadnl $NEW_NODE_KEY 0" 2>&1
echo | validator-engine-console -k client -p server.pub -v 0 -a  "$PUBLIC_IP:$CONSOLE_PORT" -rc "changefullnodeaddr $NEW_NODE_KEY" 2>&1
echo | validator-engine-console -k client -p server.pub -v 0 -a "$PUBLIC_IP:$CONSOLE_PORT" -rc "importf keyring/$VAL_ID_HEX" 2>&1
kill $PRELIMINARY_VALIDATOR_RUN;

rm -rf /var/ton-work/log*

echo Genesis node initilized

# install lite-server
read -r LITESERVER_ID1 LITESERVER_ID2 <<< $(generate-random-id -m keys -n liteserver)
echo "Liteserver IDs: $LITESERVER_ID1 $LITESERVER_ID2"
cp liteserver /var/ton-work/db/keyring/$LITESERVER_ID1

LITESERVERS=$(printf "%q" "\"liteservers\":[{\"id\":\"$LITESERVER_ID2\",\"port\":\"$LITE_PORT\"}")
sed -e "s~\"liteservers\"\ \:\ \[~$LITESERVERS~g" config.json > config.json.liteservers
mv config.json.liteservers config.json

chmod 777 /var/ton-work/db/liteserver.pub

dd if=/var/ton-work/db/liteserver.pub bs=1 skip=4 of=/var/ton-work/db/liteserver.pub.4
LITESERVER_PUB=$(base64 /var/ton-work/db/liteserver.pub.4)
rm -f liteserver.pub.4
IP=$PUBLIC_IP; IPNUM=0; for (( i=0 ; i<4 ; ++i )); do ((IPNUM=$IPNUM+${IP%%.*}*$((256**$((3-${i})))))); IP=${IP#*.}; done
[ $IPNUM -gt $((2**31)) ] && IPNUM=$(($IPNUM - $((2**32))))
LITESERVERSCONFIG=$(printf "%q" "\"liteservers\":[{\"id\":{\"key\":\"$LITESERVER_PUB\", \"@type\":\"pub.ed25519\"}, \"port\":\"$LITE_PORT\", \"ip\":$IPNUM }]}")
sed -i -e "\$s#\(.*\)\}#\1,$LITESERVERSCONFIG#" my-ton-global.config.json
python3 -c 'import json; f=open("my-ton-global.config.json", "r"); config=json.loads(f.read()); f.close(); f=open("my-ton-global.config.json", "w");f.write(json.dumps(config, indent=2)); f.close()';

cp my-ton-global.config.json global.config.json

echo Restart DHT server

#killall -9 dht-server
kill $PRELIMINARY_DHT_SERVER_RUN;
sleep 1
nohup dht-server -C /var/ton-work/db/global.config.json -D /var/ton-work/db/dht-server -I "$PUBLIC_IP:$DHT_PORT"&
echo DHT server started at $PUBLIC_IP:$DHT_PORT

# start http server
#
nohup python3 -m http.server&


#echo
#echo
#echo
#
echo http://$PUBLIC_IP:8000/
echo wget http://$PUBLIC_IP:8000/global.config.json
echo wget http://$PUBLIC_IP:8000/client.pub
echo wget http://$PUBLIC_IP:8000/client
echo wget http://$PUBLIC_IP:8000/server
echo wget http://$PUBLIC_IP:8000/server.pub
echo wget http://$PUBLIC_IP:8000/liteserver.pub
echo wget http://$PUBLIC_IP:8000/liteserver

validator-engine -C /var/ton-work/db/global.config.json --db /var/ton-work/db --ip "$PUBLIC_IP:$PUBLIC_PORT"

