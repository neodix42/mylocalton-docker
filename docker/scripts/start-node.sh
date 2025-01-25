#!/bin/bash

echo starting cron
service cron start &

GENESIS=${GENESIS:-"false"}
echo GENESIS=$GENESIS

if [ "$GENESIS" = "true" ]; then
  echo starting genesis...
  cp /usr/local/bin/libtonlibjson.so /usr/share/data
  cp /usr/local/bin/libemulator.so /usr/share/data
  /scripts/start-genesis.sh
else
  echo starting validator...
  if [ ! "$GENESIS_IP" ]; then
    echo No GENESIS_IP set, terminating...
    exit 1
  fi
  /scripts/start-validator.sh
fi