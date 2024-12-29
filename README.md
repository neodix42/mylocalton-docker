# MyLocalTon Docker image

Allows quickly to set up own [TON blockchain](https://github.com/ton-blockchain/ton) with up to 6 validators, running [TON-HTTP-API](https://github.com/toncenter/ton-http-api) and lite-server.

## Prerequisites

Installed Docker Engine or Docker desktop and docker-compose.

- For Ubuntu:
``` bash
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh
curl -L "https://github.com/docker/compose/releases/download/v2.6.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```
 For MacOS and Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/).

## Usage

### Quick start

By default, only one genesis validator will be started. Uncomment sections in ```docker-compose.yaml``` for more.

```bash
wget https://raw.githubusercontent.com/neodix42/mylocalton-docker/refs/heads/main/docker-compose.yaml
docker-compose up -d
```

### Start parameters
Edit `docker-compose.yaml` for relevant changes.

Specify only for `genesis` container:

* `VALIDATION_PERIOD` - set validation period in seconds, default `1200 (20 min)`;
* `MASTERCHAIN_ONLY` - set to `true` if you want to have only masterchain, i.e. without workchains, default `false`;
* `HIDE_PRIVATE_KEYS` - set to `true` if you don't want to have predefined private keys for validators and faucets, and don't want to expose them via http-server;
* `SERVER_PORT` - used by local http-server that runs faucet service, default port `80`;
* `SERVER_ADDRESS` - used by local http-server that runs faucet service, default bind IP `172.28.1.1`;
* `RECAPTCHA_SITE_KEY` - used by local http-server that runs faucet service, default `empty`; **If not empty then the faucet will be started at** `SERVER_ADDRESS`:`SERVER_PORT`;
* `RECAPTCHA_SECRET` - used by local http-server that runs faucet service, , default `empty`;

Can be set for all node types:
* `VERBOSITY` - set verbosity level for validator-engine. Default 1, allowed values: 0, 1, 2, 3, 4;

### Build from sources

Clone this repo and execute:

`docker-compose -f docker-compose-build.yaml up -d`

### Access services

**TON-HTTP-API** will be started at:

http://127.0.0.1:8081/

**Blockchain explorer** will be available on localhost via:

http://127.0.0.1:8080/last

**Simple HTTP server** on genesis node will be available on: 

http://127.0.0.1:8000

Global network configuration file available at:

http://127.0.0.1:8000/global.config.json

**Lite-server** on genesis node runs on port 40004 and can be queried as follows:

`lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last`

### Go inside the container

```
docker exec -it genesis bash
docker exec -it validator-1 bash
docker exec -it validator-2 bash
docker exec -it validator-3 bash
docker exec -it validator-4 bash
docker exec -it validator-5 bash

# each container has some predefined aliases:
>last
>getstats
```

### Stop all containers

```docker-compose down```

the state will be persisted, and the next time when you start the containers up the blockchain will be resumed from the last state.

### Reset network and remove all data:

```docker-compose down -v --rmi all```

## Features

* Validation
  * automatic participation in elections and reaping of rewards  
  * specify from 1 to 6 validators on start
  * validation cycle lasts 20 minutes (can be changed via env var VALIDATION_PERIOD)
  * elections lasts 10 minutes (starts 5 minutes after validation cycle starts and finishes 5 minutes before validation cycles ends)
  * stake freeze period 3 minutes
  * predefined validators' wallet addresses (`V3R2`, subWalletId = `42`)
    * genesis: 
      * address `-1:0755526dfc926d1b6d468801099cad2d588f40a6a6088bcd3e059566c0ef907c`
      * private key `5f14ebefc57461002fc07f9438a63ad35ff609759bb0ae334fedabbfb4bfdce8`
    * validator-1: 
      * address `-1:0e4160632db47d34bad8a24b55a56f46ca3b6fc84826d90515cd2b6313bd7cf6`
      * private key `001624080b055bf5ea72a252c1acc2c18552df27b4073a412fbde398d8061316`
    * validator-2: 
      * address `-1:ddd8df36e13e3bcec0ffbcfb4de51535d39937311b3c5cad520a0802d3de9b54`
      * private key `1da5f8b57104cc6c8af748c0541abc8a735362cd241aa96c201d696623684672`
    * validator-3:
      * address `-1:1ea99012e00cee2aef95c6ac245ee28894080801e4e5fae2d91363f2ef5a7232`
      * private key `fe968161dfe5aa6d7a6f8fdd1d43ceeee9395f1ca61bb8224d4f60e48fdc589d`
    * validator-4:
      * address `-1:c21b6e9f20c35f31a3c46e510daae29261c3127e43aa2c90e5d1463451f623f8`
      * private key `49cce23987cacbd05fac13978eff826e9107d694c0040a1e98bca4c2872d80f8`
    * validator-5:
      * address `-1:a485d0e84de33e212d66eb025fbbaecbeed9dbad7f78cd8cd2058afe20cebde9`
      * private key `b5e0ce4fba8ae2e3f44a393ac380549bfa44c3a5ba33a49171d502f1e4ac6c1d`
* Predefined Faucet Wallets
  * Wallet V3R2
    * address `-1:db7ef76c48e888b7a35d3c88ed61cc33e2ec84b74f0ce2d159e4dd6cd34f406c`
    * private key `249489b5c1bfa6f62451be3714679581ee04cc8f82a8e3f74b432a58f3e4fedf`
    * subWallet Id `42`
  * Highload Wallet V1
    * address `-1:fee48a6002da9ad21c61a6a2e4dd73c005d46101450b52bf47d1ce16cdc8230f`
    * private key `ee26cd8f2709404b63bc172148ec6179bfc7049b1045a22c3ea5446c5d425347`
    * queryId `0`
* Predefined lite-server
  * `lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last`
* cross-platform (arm64/amd64)
* tested on Ubuntu, Windows and MacOS

## Development using TON third party libraries
### ton4j - https://github.com/neodiX42/ton4j

```java
Tonlib tonlib =
    Tonlib.builder()
        .pathToTonlibSharedLib("path to libtonlibjson.so/dll/dylib")
        .pathToGlobalConfig("<user>/global.config.json") // global config from MyLocalTon (http://127.0.0.1:8000/global.config.json)
        .ignoreCache(false)
        .build();

log.info("last {}", tonlib.getLast());

byte[] prvKey =  Utils.hexToSignedBytes("249489b5c1bfa6f62451be3714679581ee04cc8f82a8e3f74b432a58f3e4fedf");
TweetNaclFast.Signature.KeyPair keyPair = Utils.generateSignatureKeyPairFromSeed(prvKey);

WalletV3R2 contract =  WalletV3R2.builder().tonlib(tonlib).wc(-1).keyPair(keyPair).walletId(42).build();
log.info("WalletV3R2 address {}", contract.getAddress().toRaw());
assertThat(contract.getAddress().toRaw()).isEqualTo("-1:db7ef76c48e888b7a35d3c88ed61cc33e2ec84b74f0ce2d159e4dd6cd34f406c");
```

**Important!** MyLocalTon-Docker lite-server runs inside genesis container in its own network on IP `172.28.1.1` (integer `-1407450879`),
if you want to access it from local host you have to refer to `127.0.0.1` IP address.  

Go inside `global.config.json` and in `liteservers` section replace this IP `-1407450879` to this one `2130706433`.