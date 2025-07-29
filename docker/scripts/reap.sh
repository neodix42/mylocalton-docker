#!/bin/bash
echo "---------------------------------------- REAP REWARDS ---------------------------------------"
INTERNAL_IP=$(hostname -I | tr -d " ")

if [ "$NAME" = "genesis" ]; then
    NAME="validator"
fi

echo $(date)
echo "NAME = $NAME"
echo "Looking for /usr/share/ton/smartcont/$NAME.pk"
if [ -f "/usr/share/ton/smartcont/$NAME.pk" ] && [ -f "/var/ton-work/db/global.config.json" ]; then
  WALLET_ADDR=-1:$(head -c 32 /usr/share/data/$NAME.addr | od -A n -t x1 | tr -d ' \n' | awk '{print toupper($0)}')
  echo "running reap.sh with wallet $WALLET_ADDR on $INTERNAL_IP"
else
  echo "reap.sh: Not ready yet. Exit."
  echo "------------------------------------------------------------------"
  exit
fi

LITECLIENT="lite-client"
LITECLIENT_CONFIG="/var/ton-work/db/global.config.json"
FIFTBIN="fift"
export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont/
CONTRACTS_PATH="/usr/share/ton/smartcont/"
WALLET_FIF=$CONTRACTS_PATH"wallet-v3.fif"
SUBWALLET_ID=42
WALLETKEYS_DIR="/usr/share/ton/smartcont/"
VALIDATOR_WALLET_FILEBASE=$NAME

ELECTOR_ADDRESS=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getconfig 1" |grep x{|sed -e 's/{/\ /g' -e 's/}//g'|awk {'print $2'})


WALLET_SEQ=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getaccount ${WALLET_ADDR}" |grep 'x{'| tail -n1|cut -c 4-|cut -c -8)

echo "${FIFTBIN} -s ${WALLET_FIF} $WALLETKEYS_DIR$VALIDATOR_WALLET_FILEBASE -1:${ELECTOR_ADDRESS} $SUBWALLET_ID 0x${WALLET_SEQ} 1. -B recover-query.boc"

${FIFTBIN} -s $CONTRACTS_PATH"recover-stake.fif"
${FIFTBIN} -s ${WALLET_FIF} $WALLETKEYS_DIR$VALIDATOR_WALLET_FILEBASE Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF $SUBWALLET_ID 0x${WALLET_SEQ} 1. -B recover-query.boc


${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "sendfile wallet-query.boc"
echo "------------------------------------------------------------------"