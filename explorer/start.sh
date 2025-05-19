#!/bin/bash

wget -O /usr/src/global.config.json http://$GENESIS_IP:8000/global.config.json
blockchain-explorer -C /usr/src/global.config.json -H $SERVER_PORT_VAR