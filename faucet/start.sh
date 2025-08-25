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

java -jar /scripts/web/MyLocalTonDockerWebFaucet.jar
