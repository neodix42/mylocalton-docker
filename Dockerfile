FROM ghcr.io/ton-blockchain/ton:latest
ENV DEBIAN_FRONTEND=noninteractive
RUN apt -y update && apt install --no-install-recommends -y python3 cron bc

RUN mkdir -p /scripts/web  \
    /usr/share/data \
    /var/ton-work/logs

COPY --chmod=744 docker/scripts/start-genesis.sh /scripts
COPY --chmod=744 docker/scripts/post-genesis.sh /scripts
COPY --chmod=744 docker/scripts/start-validator.sh /scripts
COPY --chmod=744 docker/scripts/start-node.sh /scripts
COPY --chmod=744 docker/scripts/cron.sh /scripts
COPY --chmod=744 docker/scripts/participate.sh /scripts
COPY --chmod=744 docker/scripts/reap.sh /scripts
COPY docker/scripts/gen-zerostate.fif /usr/share/ton/smartcont/gen-zerostate.fif
COPY docker/scripts/ton-private-testnet.config.json.template /scripts
COPY docker/scripts/example.config.json /scripts
COPY docker/scripts/control.template /scripts
COPY docker/scripts/faucet.pk /usr/share/ton/smartcont
COPY docker/scripts/faucet-basechain.pk /usr/share/ton/smartcont
COPY docker/scripts/faucet-highload.pk /usr/share/ton/smartcont
COPY docker/scripts/faucet-highload-basechain.pk /usr/share/ton/smartcont
COPY docker/scripts/data-highload.pk /usr/share/ton/smartcont
COPY docker/scripts/validator.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-1.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-2.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-3.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-4.pk /usr/share/ton/smartcont
COPY docker/scripts/validator-5.pk /usr/share/ton/smartcont
COPY docker/scripts/validator.addr /usr/share/ton/smartcont
COPY docker/scripts/validator-1.addr /usr/share/ton/smartcont
COPY docker/scripts/validator-2.addr /usr/share/ton/smartcont
COPY docker/scripts/validator-3.addr /usr/share/ton/smartcont
COPY docker/scripts/validator-4.addr /usr/share/ton/smartcont
COPY docker/scripts/validator-5.addr /usr/share/ton/smartcont
COPY docker/scripts/liteserver /scripts
COPY docker/scripts/liteserver.pub /scripts

RUN echo 'alias getstats="validator-engine-console -k /var/ton-work/db/client -p /var/ton-work/db/server.pub -a $(hostname -I | tr -d " "):$(jq .control[].port <<< cat /var/ton-work/db/config.json) -c getstats"' >> ~/.bashrc
RUN echo 'alias last="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c last"' >> ~/.bashrc
RUN echo 'alias config32="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c \"getconfig 32\""' >> ~/.bashrc
RUN echo 'alias config34="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c \"getconfig 34\""' >> ~/.bashrc
RUN echo 'alias config36="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c \"getconfig 36\""' >> ~/.bashrc
RUN echo 'alias elid="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c \"runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 active_election_id\""' >> ~/.bashrc
RUN echo 'alias participants="lite-client -p /var/ton-work/db/liteserver.pub -a $(hostname -I | tr -d " "):$(jq .liteservers[].port <<< cat /var/ton-work/db/config.json) -c \"runmethod -1:3333333333333333333333333333333333333333333333333333333333333333 participant_list\""' >> ~/.bashrc

# Setup cron
RUN touch /var/log/cron.log
RUN (crontab -l ; echo "*/3 * * * * /scripts/cron.sh >> /var/log/cron.log 2>&1") | crontab

ENTRYPOINT ["/scripts/start-node.sh"]