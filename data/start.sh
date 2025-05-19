#!/bin/sh

PERIOD=${PERIOD:-"5"}
echo PERIOD=PERIOD
wget -O /scripts/web/global.config.json http://$GENESIS_IP:8000/global.config.json
wget -O /scripts/web/libtonlibjson.so http://$GENESIS_IP:8000/libtonlibjson.so

java -jar /scripts/web/MyLocalTonDockerData.jar
