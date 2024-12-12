#!/bin/bash

#This is free and unencumbered software released into the public domain.

#Anyone is free to copy, modify, publish, use, compile, sell, or
#distribute this software, either in source code form or as a compiled
#binary, for any purpose, commercial or non-commercial, and by any
#means.

#In jurisdictions that recognize copyright laws, the author or authors
#of this software dedicate any and all copyright interest in the
#software to the public domain. We make this dedication for the benefit
#of the public at large and to the detriment of our heirs and
#successors. We intend this dedication to be an overt act of
#relinquishment in perpetuity of all present and future rights to this
#software under copyright law.

#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
#MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
#OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
#ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
#OTHER DEALINGS IN THE SOFTWARE.

#For more information, please refer to <https://unlicense.org>
# (c) Mercuryo and Viacheslav Akhmetov - original authors
# (c) @neodiX

#!/usr/bin/env bash

PUBLIC_IP=$(hostname -I | tr -d " ")

if [ ! -f "/var/ton-work/db/validator.pk" ] || [ ! -f "/var/ton-work/db/global.config.json" ]; then
  echo "reap.sh: Not ready yet. Exit."
  echo "------------------------------------------------------------------"
  exit
else
  WALLET_ADDR=-1:$(head -c 32 /var/ton-work/db/validator.addr | od -A n -t x1 | tr -d ' \n' | awk '{print toupper($0)}')
  echo "running reap.sh with wallet $WALLET_ADDR on $PUBLIC_IP"
fi

LITECLIENT="lite-client"
LITECLIENT_CONFIG="/var/ton-work/db/global.config.json"
FIFTBIN="fift"
export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont/
CONTRACTS_PATH="/usr/share/ton/smartcont/"
WALLET_FIF=$CONTRACTS_PATH"wallet-v3.fif"
SUBWALLET_ID=42
WALLETKEYS_DIR="/var/ton-work/db/"
VALIDATOR_WALLET_FILEBASE="validator"

ELECTOR_ADDRESS=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getconfig 1" |grep x{|sed -e 's/{/\ /g' -e 's/}//g'|awk {'print $2'})


WALLET_SEQ=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getaccount ${WALLET_ADDR}" |grep 'x{'| tail -n1|cut -c 4-|cut -c -8)

echo "${FIFTBIN} -s ${WALLET_FIF} $WALLETKEYS_DIR$VALIDATOR_WALLET_FILEBASE -1:${ELECTOR_ADDRESS} $SUBWALLET_ID 0x${WALLET_SEQ} 1. -B recover-query.boc"

${FIFTBIN} -s $CONTRACTS_PATH"recover-stake.fif"
${FIFTBIN} -s ${WALLET_FIF} $WALLETKEYS_DIR$VALIDATOR_WALLET_FILEBASE Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF $SUBWALLET_ID 0x${WALLET_SEQ} 1. -B recover-query.boc


${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "sendfile wallet-query.boc"
echo "------------------------------------------------------------------"