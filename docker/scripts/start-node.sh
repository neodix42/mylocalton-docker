#!/bin/bash

echo starting cron

printenv | while IFS='=' read -r name value; do
  printf 'export %s=%q\n' "$name" "$value"
done > /etc/container_env

service cron start &

GENESIS=${GENESIS:-"false"}
echo GENESIS=$GENESIS

if [ "$GENESIS" = "true" ]; then
  echo starting genesis...
  cp /usr/local/bin/libtonlibjson.so /usr/share/data
  cp /usr/local/bin/libemulator.so /usr/share/data
  cp /usr/local/bin/libtonlibjson.so /var/ton-work/db # available via http
  cp /usr/local/bin/libemulator.so /var/ton-work/db   # available via http
  /scripts/start-genesis.sh
else
  echo starting validator...
  if [ ! "$GENESIS_IP" ]; then
    echo No GENESIS_IP set, terminating...
    exit 1
  fi
  /scripts/start-validator.sh
fi
