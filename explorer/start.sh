#!/bin/bash

echo wget -O /usr/src/global.config.json http://$FILE_SERVER_IP:$FILE_SERVER_PORT/global.config.json
wget -O /usr/src/global.config.json http://$FILE_SERVER_IP:$FILE_SERVER_PORT/global.config.json

echo blockchain-explorer -C /usr/src/global.config.json -H $SERVER_PORT
blockchain-explorer -C /usr/src/global.config.json -H $SERVER_PORT