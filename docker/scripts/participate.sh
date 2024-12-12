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

PUBLIC_IP=$(hostname -I | tr -d " ")
CONSOLE_PORT=40002
NODEHOST="$PUBLIC_IP:$CONSOLE_PORT" # Full Node IP:HOST

if [ ! -f "/var/ton-work/db/validator.pk" ] || [ ! -f "/var/ton-work/db/global.config.json" ]; then
  echo "participate.sh: Not ready yet. Exit."
  echo "------------------------------------------------------------------"
  exit
else
  WALLET_ADDR=-1:$(head -c 32 /var/ton-work/db/validator.addr | od -A n -t x1 | tr -d ' \n' | awk '{print toupper($0)}')
  echo "running participate.sh with wallet $WALLET_ADDR on $NODEHOST"
fi

MAX_FACTOR=3
STAKE_AMOUNT=10001
WALLETKEYS_DIR="/var/ton-work/db/"
VALIDATOR_WALLET_FILEBASE="validator"
SUBWALLET_ID=42


# env config
FIFTBIN="fift"
export FIFTPATH=/usr/lib/fift:/usr/share/ton/smartcont/
LITECLIENT="lite-client"
LITECLIENT_CONFIG="/var/ton-work/db/global.config.json"
VALIDATOR_CONSOLE="validator-engine-console"

export CONTRACTS_PATH="/usr/share/ton/smartcont/"
WALLET_FIF=$CONTRACTS_PATH"wallet-v3.fif"
VALIDATOR_ELECT_REQ=$CONTRACTS_PATH"validator-elect-req.fif"
VALIDATOR_ELECT_SIGNED=$CONTRACTS_PATH"validator-elect-signed.fif"
CLIENT_CERT="/var/ton-work/db/client"
SERVER_PUB="/var/ton-work/db/server.pub"

# watch for election

check_bins() {
    EXIT=0
    for cmd in ${FIFTBIN} ${LITECLIENT} ${VALIDATOR_CONSOLE}; do
        if ! [ -x "$(command -v $cmd)" ]; then
            echo "Error: $cmd not found." >&2
            EXIT=1
        fi
    done
    if [ "$EXIT" -eq 1 ]; then
        echo "------------------------------------------------------------------"
        exit 1
    fi
}

save_vars() {
    for var in ADNLKEY ELECTION_TIMESTAMP PUBKEY KEY; do
        echo ${!var}
        echo ${var}=${!var} >> $ELECTION_TIMESTAMP.elect
    done
}

load_vars() {
 export $(cat ${ELECTION_TIMESTAMP}.elect | xargs)
}

check_bins


ELECTOR_ADDRESS=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getconfig 1" |grep x{|sed -e 's/{/\ /g' -e 's/}//g'|awk {'print $2'})
ELECTION_TIMESTAMP=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "runmethod -1:${ELECTOR_ADDRESS} active_election_id" |grep -m1 result|awk {'print $3'})

echo "ELECTION_TIMESTAMP = $ELECTION_TIMESTAMP"

if [ ! "$ELECTION_TIMESTAMP" ] || [ "$ELECTION_TIMESTAMP" -eq "0" ]; then
   echo "No active election, exiting";
   echo "------------------------------------------------------------------"
   exit;
fi

echo "Election has started at ${ELECTION_TIMESTAMP} ($(date -d @${ELECTION_TIMESTAMP}))"
ELECTION_END=$(( ${ELECTION_TIMESTAMP} + 1800 ))

if [ ! -f "${ELECTION_TIMESTAMP}.elect" ]; then

    # Create signing key
    echo "Signing key..."
    KEY=$(${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "newkey" |grep "new key"|awk {'print $4'})
    echo "Signing key: ${KEY}"

    PUBKEY=$(${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "exportpub ${KEY}" |grep "got public key"|awk {'print $4'})

    echo "Public key: ${PUBKEY}"

    echo "Run: ${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "addpermkey ${KEY} ${ELECTION_TIMESTAMP} ${ELECTION_END}""
    ${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "addpermkey ${KEY} ${ELECTION_TIMESTAMP} ${ELECTION_END}"

    echo "${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "addtempkey ${KEY} ${KEY} ${ELECTION_END}""
    ${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "addtempkey ${KEY} ${KEY} ${ELECTION_END}"


    # adnl
    echo "ADNL"
    ADNLKEY=$(${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "newkey" |grep "new key"|awk {'print $4'})
    echo "ADNL Key: ${ADNLKEY}"

    ${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "addadnl ${ADNLKEY} 0"

    ${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "addvalidatoraddr ${KEY} ${ADNLKEY} ${ELECTION_END}"

    save_vars
else
    echo "Loading vars from: ${ELECTION_TIMESTAMP}.elect"
    load_vars
fi

# Signing participate request

if [ ! -f "${ELECTION_TIMESTAMP}.participated" ]; then

    echo "Participate"
    MESSAGE=$(${FIFTBIN} -s ${VALIDATOR_ELECT_REQ} ${WALLET_ADDR} ${ELECTION_TIMESTAMP} ${MAX_FACTOR} ${ADNLKEY}|tail -n 3|head -n1)

    SIGNATURE=$(${VALIDATOR_CONSOLE} -k ${CLIENT_CERT} -p ${SERVER_PUB} -a ${NODEHOST} -v 0 -rc "sign ${KEY} ${MESSAGE}" |grep signature|awk {'print $3'})

    ${FIFTBIN} -s ${VALIDATOR_ELECT_SIGNED} ${WALLET_ADDR} ${ELECTION_TIMESTAMP} ${MAX_FACTOR} ${ADNLKEY} ${PUBKEY} ${SIGNATURE}

    # Sending request

    echo "${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getaccount ${WALLET_ADDR}" 2> >(grep 'x{'| tail -n1|cut -c 4-|cut -c -8)"
    WALLET_SEQ=$(${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "getaccount ${WALLET_ADDR}" |grep 'x{'| tail -n1|cut -c 4-|cut -c -8)

    echo "${FIFTBIN} -s ${WALLET_FIF} $WALLETKEYS_DIR$VALIDATOR_WALLET_FILEBASE -1:${ELECTOR_ADDRESS} $SUBWALLET_ID 0x${WALLET_SEQ##+(0)} ${STAKE_AMOUNT}. -B validator-query.boc"

    ${FIFTBIN} -s ${WALLET_FIF} $WALLETKEYS_DIR$VALIDATOR_WALLET_FILEBASE Ef8zMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMzM0vF $SUBWALLET_ID 0x${WALLET_SEQ##+(0)} ${STAKE_AMOUNT}. -B validator-query.boc
    ${LITECLIENT} -C ${LITECLIENT_CONFIG} -v 0 -c "sendfile wallet-query.boc"
    touch ${ELECTION_TIMESTAMP}.participated
else
   participants=$(lite-client -v 0 -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c "runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 participant_list" | grep "remote result")
   echo "participant_list:"
   echo $participants
   echo "Already participated"
fi

echo "------------------------------------------------------------------"
