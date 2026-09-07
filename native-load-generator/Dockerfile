ARG TON_IMAGE=ghcr.io/corton-nommander/ton
ARG TON_BRANCH=master
ARG TON_BASE_IMAGE=${TON_IMAGE}:${TON_BRANCH}
FROM ${TON_BASE_IMAGE}

COPY native-load-generator/entrypoint.sh /usr/local/bin/run-native-load-generator
COPY native-load-generator/payment-lanes.sh /usr/local/lib/native-load-generator/payment-lanes.sh
RUN test -x /usr/local/bin/native-load-generator && chmod +x /usr/local/bin/run-native-load-generator

ENTRYPOINT ["/usr/local/bin/run-native-load-generator"]
