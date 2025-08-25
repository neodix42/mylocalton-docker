FROM ghcr.io/ton-blockchain/ton:latest

RUN mkdir -p /scripts
COPY --chmod=744 explorer/start.sh /scripts
ENTRYPOINT ["/scripts/start.sh"]