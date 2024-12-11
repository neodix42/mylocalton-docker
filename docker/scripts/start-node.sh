#!/usr/bin/env bash

PUBLIC_IP=$(hostname -I | tr -d " ")

if [ "$PUBLIC_IP" = "172.28.1.1" ]; then
  echo starting genesis...
  /scripts/start-genesis.sh
else
  echo starting validator...
  /scripts/start-validator.sh
fi