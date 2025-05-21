#!/bin/sh

FAUCET_USE_RECAPTCHA=${FAUCET_USE_RECAPTCHA:-"true"}
echo FAUCET_USE_RECAPTCHA=$FAUCET_USE_RECAPTCHA

if [ "$FAUCET_USE_RECAPTCHA" = "true" ]; then
  echo starting faucet with recaptcha
  sed -i "s/RECAPTCHA_SITE_KEY/$RECAPTCHA_SITE_KEY/g" /scripts/web/index.html
else
  echo starting faucet without recaptcha
  cp /scripts/web/index-no-recaptcha.html /scripts/web/index.html
  cp /scripts/web/script-no-recaptcha.js /scripts/web/script.js
fi


if [ "$EXTERNAL_IP" ]; then
  wget -O /scripts/web/global.config.json http://$GENESIS_IP:8000/external.global.config.json
  test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/external.global.config.json "; exit 14; }
elif [ "$GENESIS_IP" ]; then
  wget -O /scripts/web/global.config.json http://$GENESIS_IP:8000/global.config.json
  test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/global.config.json "; exit 14; }
else
  echo Neither EXTERNAL_IP nor GENESIS_IP specified.
  exit 11
fi

wget -O /scripts/web/libtonlibjson.so http://$GENESIS_IP:8000/libtonlibjson.so
test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/libtonlibjson.so "; exit 14; }
wget -O /scripts/web/faucet-highload.pk http://$GENESIS_IP:8000/faucet-highload.pk
test $? -eq 0 || { echo "Can't download http://$GENESIS_IP:8000/faucet-highload.pk "; exit 14; }



java -jar /scripts/web/MyLocalTonDockerWebFaucet.jar
