#FROM ghcr.io/ton-blockchain/ton:testnet
FROM ghcr.io/ton-blockchain/ton:latest
#FROM ghcr.io/neodix42/ton:testnet
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y python3 cron
#    openjdk-21-jdk-headless

RUN mkdir -p /scripts  \
    /usr/share/data/ \
    /var/ton-work/db/static \
    /var/ton-work/db/keyring \
    /var/ton-work/db/import \
    /var/ton-work/logs

COPY --chmod=744 docker/scripts/start-genesis.sh /scripts
COPY --chmod=744 docker/scripts/start-validator.sh /scripts
COPY --chmod=744 docker/scripts/start-node.sh /scripts
COPY --chmod=744 docker/scripts/participate.sh /scripts
COPY --chmod=744 docker/scripts/reap.sh /scripts
COPY docker/scripts/gen-zerostate.fif /usr/share/ton/smartcont/gen-zerostate.fif
COPY docker/scripts/ton-private-testnet.config.json.template /var/ton-work/db
COPY docker/scripts/example.config.json /var/ton-work/db
COPY docker/scripts/control.template /var/ton-work/db
COPY docker/scripts/faucet.pk /usr/share/ton/smartcont
COPY docker/scripts/faucet-highload.pk /usr/share/ton/smartcont
COPY docker/scripts/validator.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-1.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-2.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-3.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-4.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-5.pk /usr/share/ton/smartcont
COPY docker/scripts/liteserver /var/ton-work/db
COPY docker/scripts/liteserver.pub /var/ton-work/db

RUN echo 'alias getstats="validator-engine-console -k /var/ton-work/db/client -p /var/ton-work/db/server.pub -a $(hostname -I | tr -d " "):$(jq .control[].port <<< cat /var/ton-work/db/config.json) -c getstats"' >> ~/.bashrc
RUN echo 'alias last="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c last"' >> ~/.bashrc

# Setup cron
RUN touch /var/log/participate.log
RUN touch /var/log/reap.log
RUN (crontab -l ; echo "*/3 * * * * /scripts/participate.sh >> /var/log/participate.log 2>&1") | crontab
RUN (crontab -l ; echo "*/4 * * * * /scripts/reap.sh >> /var/log/reap.log 2>&1") | crontab

ENTRYPOINT ["/scripts/start-node.sh"]