#!/bin/bash

if [ "$EXTERNAL_IP" ]; then
  wget -O /usr/src/global.config.json http://$GENESIS_IP:8000/external.global.config.json
  test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/external.global.config.json"; exit 14; }
elif [ "$GENESIS_IP" ]; then
  wget -O /usr/src/global.config.json http://$GENESIS_IP:8000/global.config.json
  test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/global.config.json"; exit 14; }
else
  echo "Neither EXTERNAL_IP nor GENESIS_IP specified."
  exit 11
fi

echo "blockchain-explorer -C /usr/src/global.config.json -H $SERVER_PORT"
blockchain-explorer -C /usr/src/global.config.json -H $SERVER_PORT
