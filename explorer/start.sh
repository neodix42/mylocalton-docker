#!/bin/bash

if [ "$EXTERNAL_IP" ]; then
  wget -O /usr/src/global.config.json http://$GENESIS_IP:8000/external.global.config.json
  test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/external.global.config.json "; exit 14; }
elif [ "$GENESIS_IP" ]; then
  wget -O /usr/src/global.config.json http://$GENESIS_IP:8000/global.config.json
  test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/global.config.json "; exit 14; }
else
  echo Neither EXTERNAL_IP nor GENESIS_IP specified.
  exit 11
fi

get_preferred_ip() {
  for ip in $(hostname -I); do
    if [[ $ip == 172.28.* ]]; then
      echo "$ip"
      return
    fi
  done
  # Fallback to the first IP if no 172.28.* IP found
  echo "$(hostname -I | awk '{print $1}')"
}

INTERNAL_IP=$(get_preferred_ip)

if [ "$EXTERNAL_IP" ]; then
  echo "Started at http://$EXTERNAL_IP:$SERVER_PORT/last"
  IP=$EXTERNAL_IP
else
  echo "Started at http://$INTERNAL_IP:$SERVER_PORT/last"
  IP=$INTERNAL_IP
if
echo blockchain-explorer -C /usr/src/global.config.json -a $IP:$SERVER_PORT
blockchain-explorer -C /usr/src/global.config.json -a $IP:$SERVER_PORT