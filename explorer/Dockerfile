ARG TON_BRANCH=latest
FROM ghcr.io/ton-blockchain/ton:${TON_BRANCH}

RUN mkdir -p /scripts
COPY --chmod=744 explorer/start.sh /scripts
ENTRYPOINT ["/scripts/start.sh"]