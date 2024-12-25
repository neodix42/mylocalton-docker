#!/usr/bin/env bash

PUBLIC_IP=$(hostname -I | tr -d " ")

echo starting cron
service cron start &

if [ "$GENESIS" = "true" ]; then
  echo starting genesis...
  cp /usr/local/bin/libtonlibjson.so /usr/share/libs
  cp /usr/local/bin/libemulator.so /usr/share/libs
  /scripts/start-genesis.sh
else
  echo starting validator...
  if [ ! "$GENESIS_IP" ]; then
    echo No GENESIS_IP set, terminating...
    exit 1
  fi
  /scripts/start-validator.sh
fi