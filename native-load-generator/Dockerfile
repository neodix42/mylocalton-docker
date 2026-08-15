ARG TON_IMAGE=ghcr.io/corton-nommander/ton
ARG TON_BRANCH=latest
FROM ${TON_IMAGE}:${TON_BRANCH}

COPY native-load-generator/entrypoint.sh /usr/local/bin/run-native-load-generator
RUN test -x /usr/local/bin/native-load-generator && chmod +x /usr/local/bin/run-native-load-generator

ENTRYPOINT ["/usr/local/bin/run-native-load-generator"]
