#!/bin/bash

if [ "$EXTERNAL_IP" ]; then
  wget -O /usr/src/global.config.json http://$EXTERNAL_IP:8000/external.global.config.json
elif [ "$GENESIS_IP" ]; then
  wget -O /usr/src/global.config.json http://$GENESIS_IP:8000/global.config.json
else
  echo Neither EXTERNAL_IP nor GENESIS_IP specified.
  exit 11
fi

blockchain-explorer -C /usr/src/global.config.json -H $SERVER_PORT_VAR