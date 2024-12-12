#!/usr/bin/env bash

PUBLIC_IP=$(hostname -I | tr -d " ")

if [ ! "$GENESIS_IP" ]
  echo No GENESIS_IP set, terminating...
  exit 1
fi

echo starting cron
service cron start &

if [ "$GENESIS" = "true" ]; then
  echo starting genesis...
  /scripts/start-genesis.sh
else
  echo starting validator...
  /scripts/start-validator.sh
fi