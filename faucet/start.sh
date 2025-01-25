#!/bin/sh
sed -i "s/RECAPTCHA_SITE_KEY/$RECAPTCHA_SITE_KEY/g" /scripts/web/index.html
java -jar /scripts/web/MyLocalTonDockerWebFaucet.jar
