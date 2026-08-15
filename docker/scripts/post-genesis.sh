#!/bin/bash
echo "started post-genesis.sh, waiting for genesis to produce the first block..."

wait_for_masterchain() {
  local attempt=0
  local seqno

  while [ "$attempt" -lt 120 ]; do
    seqno=$(/usr/local/bin/lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -t 3 -c "last" 2>&1 \
      | sed -n 's/.*last masterchain block is (-1,8000000000000000,\([0-9][0-9]*\)).*/\1/p' \
      | tail -n 1)

    if [ -n "$seqno" ] && [ "$seqno" -gt 0 ]; then
      echo "genesis is producing blocks, masterchain seqno=$seqno"
      return 0
    fi

    attempt=$((attempt + 1))
    sleep 5
  done

  echo "genesis did not produce a masterchain block in time"
  return 1
}

wait_for_masterchain || exit 1
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
SPAM_RUN=${SPAM_RUN:-0}
echo SPAM_RUN=$SPAM_RUN
if [[ "$SPAM_RUN" =~ ^[0-9]+$ ]] && [ "$SPAM_RUN" -gt 0 ]; then
  /scripts/run-spam.sh
else
  echo "Retranslator spam not enabled"
fi

NATIVE_SPAM_RUN=${NATIVE_SPAM_RUN:-0}
echo NATIVE_SPAM_RUN=$NATIVE_SPAM_RUN
if [[ "$NATIVE_SPAM_RUN" =~ ^[0-9]+$ ]] && [ "$NATIVE_SPAM_RUN" -gt 0 ]; then
  /scripts/run-native-spam.sh
else
  echo "Native spam not enabled"
fi

echo "finished post-genesis.sh"
