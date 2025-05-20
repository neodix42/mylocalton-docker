#!/bin/sh

PERIOD=${PERIOD:-"5"}
echo PERIOD=PERIOD

if [ "$EXTERNAL_IP" ]; then
  wget -O /scripts/web/global.config.json http://$GENESIS_IP:8000/external.global.config.json
elif [ "$GENESIS_IP" ]; then
  wget -O /scripts/web/global.config.json http://$GENESIS_IP:8000/global.config.json
else
  echo Neither EXTERNAL_IP nor GENESIS_IP specified.
  exit 11
fi
wget -O /scripts/web/libtonlibjson.so http://$GENESIS_IP:8000/libtonlibjson.so

java -jar /scripts/web/MyLocalTonDockerData.jar
