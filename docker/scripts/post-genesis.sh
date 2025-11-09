#!/bin/bash
echo "started post-genesis.sh, waiting for genesis to start, sleeping 3min..."

sleep 180
cp /usr/local/bin/fift /usr/bin/
cp /usr/local/bin/func /usr/bin/
cd /usr/share/ton/smartcont

echo "------------------------------------ Faucet wallet (basechain) ------------------------------------"
# Faucet wallet (basechain)
echo top up 0:1da77f0269bbbb76c862ea424b257df63bd1acb0d4eb681b68c9aadfbf553b93
chmod +x wallet.fif
./wallet.fif main-wallet 0QAdp38Cabu7dshi6kJLJX32O9GssNTraBtoyarfv1U7k9PA 0 1000000
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "sendfile /usr/share/ton/smartcont/wallet-query.boc"
sleep 15

/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "getaccount 0QAdp38Cabu7dshi6kJLJX32O9GssNTraBtoyarfv1U7k9PA"

chmod +x new-wallet-v3.fif
./new-wallet-v3.fif 0 42 faucet-basechain
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "sendfile /usr/share/ton/smartcont/faucet-basechain-query.boc"


echo "------------------------------------ Faucet Highload V2 (basechain) ------------------------------------"
# Faucet Highload V2 (basechain)
echo top up 0:d07625ea432039dc94dc019025f971bbeba0f7a1d9aaf6abfa94df70e60bca8f

./wallet.fif main-wallet 0QDQdiXqQyA53JTcAZAl-XG766D3odmq9qv6lN9w5gvKjza1 1 1000000
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "sendfile /usr/share/ton/smartcont/wallet-query.boc"
sleep 15
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "getaccount 0QDQdiXqQyA53JTcAZAl-XG766D3odmq9qv6lN9w5gvKjza1"

chmod +x new-highload-wallet-v2.fif
./new-highload-wallet-v2.fif 0 42 faucet-highload-basechain
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "sendfile /usr/share/ton/smartcont/faucet-highload-basechain42-query.boc"

echo "----------------------------------------------- Starting spam ------------------------------------------"
# start spam
echo SPAM_RUN=$SPAM_RUN
if [ $SPAM_RUN -eq 0 ]; then
  echo Spam not enabled
  echo "finished post-genesis.sh"
  exit
fi

echo Starting spam...
cd /scripts
echo SPAM_CHAINS=$SPAM_CHAINS

MSG_TEMPLATE=create-msg.fif
cp create-msg.fif.template $MSG_TEMPLATE

SPAM_CHAINS=${SPAM_CHAINS:-10}
echo SPAM_CHAINS=$SPAM_CHAINS
sed -i "s/SPAM_CHAINS/$SPAM_CHAINS/g" $MSG_TEMPLATE

SPAM_HOPS=${SPAM_HOPS:-65535}
echo SPAM_HOPS=$SPAM_HOPS
sed -i "s/SPAM_HOPS/$SPAM_HOPS/g" $MSG_TEMPLATE

SPAM_SPLIT_HOPS=${SPAM_SPLIT_HOPS:-7}
echo SPAM_SPLIT_HOPS=$SPAM_SPLIT_HOPS
sed -i "s/SPAM_SPLIT_HOPS/$SPAM_SPLIT_HOPS/g" $MSG_TEMPLATE

SPAM_DURATION_MINUTES=${SPAM_DURATION_MINUTES:-300}
echo SPAM_DURATION_MINUTES=$SPAM_DURATION_MINUTES
sed -i "s/SPAM_DURATION_MINUTES/$SPAM_DURATION_MINUTES/g" $MSG_TEMPLATE

echo Compile retranslator.fc smart-contract
func -o retranslator.fif -SPA /usr/share/ton/smartcont/stdlib.fc retranslator.fc

# create retranslator address and deploy query
chmod +x ./create-msg.fif
./create-msg.fif

RETRANSLATOR_ADDR=0:$(xxd -p -c 32 wallet-retranslator.addr | head -n1)
MASTER_ADDR=-1:$(xxd -p -c 32 /usr/share/ton/smartcont/main-wallet.addr | head -n1)

echo $RETRANSLATOR_ADDR
echo $MASTER_ADDR

echo Topping up retranslator wallet...
cd /usr/share/ton/smartcont/
chmod +x wallet.fif

#Run the command using the current seqno
echo ./wallet.fif main-wallet $RETRANSLATOR_ADDR 2 33333333 -n
./wallet.fif main-wallet $RETRANSLATOR_ADDR 2 33333333 -n
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "sendfile /usr/share/ton/smartcont/wallet-query.boc"
sleep 15

#get balance
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "getaccount $RETRANSLATOR_ADDR"

#start spam
/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "sendfile /scripts/query-retranslator.boc"

echo "finished post-genesis.sh"