# MyLocalTon Docker image

Allows quickly to set up own [TON blockchain](https://github.com/ton-blockchain/ton) with up to 6 validators, running [TON-HTTP-API](https://github.com/toncenter/ton-http-api) and lite-server.

## Prerequisites

Installed Docker Engine or Docker desktop and docker-compose.

- For Ubuntu:
``` 
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh
curl -L "https://github.com/docker/compose/releases/download/v2.6.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```
 For MacOS and Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/).

## Usage

### Quick start

By default, only one genesis validator will be started. Uncomment sections in ```docker-compose.yaml``` for more.

```
wget https://raw.githubusercontent.com/neodix42/mylocalton-docker/refs/heads/main/docker-compose.yaml
docker-compose -f docker-compose.yaml up -d
```

### Build from sources

Clone this repo and execute:

```docker-compose -f docker-compose-build.yaml up -d```

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

```lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last```

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

```docker-compose -f docker-compose.yaml down```

the state will be persisted, and the next time when you start the containers up the blockchain will be resumed from the last state.

### Reset network and remove all data:

```docker-compose -f docker-compose.yaml down -v --rmi all```

## Features

* Validation
  * automatic participation in elections and reaping of rewards  
  * specify from 1 to 6 validators on start
  * validation cycle lasts 20 minutes
  * elections lasts 10 minutes (starts 5 minutes after validation cycle starts and finishes 5 minutes before validation cycles ends)
  * stake freeze period 3 minutes
  * predefined validators' wallet addresses (V3R2, subWalletId = 42)
    * genesis: 
      * address ```-1:0755526dfc926d1b6d468801099cad2d588f40a6a6088bcd3e059566c0ef907c```
      * private key ```5f14ebefc57461002fc07f9438a63ad35ff609759bb0ae334fedabbfb4bfce8```
    * validator-1: 
      * address ```-1:0e4160632db47d34bad8a24b55a56f46ca3b6fc84826d90515cd2b6313bd7cf6```
      * private key  ```001624080b055bf5ea72a252c1acc2c18552df27b4073a412fbde398d8061316```
    * validator-2: 
      * address ```-1:ddd8df36e13e3bcec0ffbcfb4de51535d39937311b3c5cad520a0802d3de9b54```
      * private key ```1da5f8b57104cc6c8af748c0541abc8a735362cd241aa96c201d696623684672```
    * validator-3:
      * address ```-1:1ea99012e00cee2aef95c6ac245ee28894080801e4e5fae2d91363f2ef5a7232```
      * private key ```fe968161dfe5aa6d7a6f8fdd1d43ceeee9395f1ca61bb8224d4f60e48fdc589d```
    * validator-4:
      * address ```-1:c21b6e9f20c35f31a3c46e510daae29261c3127e43aa2c90e5d1463451f623f8```
      * private key ```49cce23987cacbd05fac13978eff826e9107d694c0040a1e98bca4c2872d80f8```
    * validator-5:
      * address ```-1:a485d0e84de33e212d66eb025fbbaecbeed9dbad7f78cd8cd2058afe20cebde9```
      * private key ```b5e0ce4fba8ae2e3f44a393ac380549bfa44c3a5ba33a49171d502f1e4ac6c1d```
* Predefined Faucet Wallets
  * Wallet V3R2
    * address ```-1:7777777777777777777777777777777777777777777777777777777777777777```
    * private key ```249489b5c1bfa6f62451be3714679581ee04cc8f82a8e3f74b432a58f3e4fedf```
    * subWallet Id 42
  * Highload Wallet V3
    * address ```-1:8888888888888888888888888888888888888888888888888888888888888888```
    * private key ```ee26cd8f2709404b63bc172148ec6179bfc7049b1045a22c3ea5446c5d425347```   
* Predefined lite-server
  * ```lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last```
* cross-platform (arm64/amd64)
* tested on Ubuntu, Windows and MacOS