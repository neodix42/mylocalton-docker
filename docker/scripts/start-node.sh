#!/usr/bin/env bash

echo GENESIS $GENESIS

if [ "$GENESIS" = true ]; then
  echo starting genesis...
  /scripts/start-genesis.sh
else
  echo starting validator...
  sleep 120
  /scripts/start-validator.sh
fi