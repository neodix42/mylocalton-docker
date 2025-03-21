# MyLocalTon Docker image

Allows quickly to set up own [TON blockchain](https://github.com/ton-blockchain/ton) with up to 6 validators,
running [TON-HTTP-API](https://github.com/toncenter/ton-http-api) and lite-server.

## Prerequisites

Installed Docker Engine or Docker desktop and docker-compose.

- For Ubuntu:
    - quick Docker installation

``` bash
curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh
```

- docker-compose installation

``` bash
curl -L "https://github.com/docker/compose/releases/download/v2.6.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
```

For MacOS and Windows: install [Docker Desktop](https://www.docker.com/products/docker-desktop/).

## Usage

### Quick start

By default, only one genesis validator will be started. Uncomment sections in ```docker-compose.yaml``` for more
validators and services.

```bash
wget https://raw.githubusercontent.com/neodix42/mylocalton-docker/refs/heads/main/docker-compose.yaml
docker-compose up -d
```

### Start parameters

Edit `docker-compose.yaml` for relevant changes.

`genesis` container:

* `EXTERNAL_IP` - used to generate  `external.global.config.json` that allows remote users to connect to lite-server via
  public IP. Default `empty`, i.e. no `external.global.config.json` will be generated;
* `NEXT_BLOCK_GENERATION_DELAY` - used to set blocks generation rate per second. Default value 2 (seconds), that means 1
  block in 2 seconds. Can also be set to less than a seconds, e.g. 0.5;
* `VALIDATION_PERIOD` - set validation period in seconds, default `1200 (20 min)`;
* `MASTERCHAIN_ONLY` - set to `true` if you want to have only masterchain, i.e. without workchains, default `false`;
* `HIDE_PRIVATE_KEYS` - set to `true` if you don't want to have predefined private keys for validators and faucets, and
  don't want to expose them via http-server;
* `DHT_PORT` - set port (udp) for dht server, default port `40004`, optional.
* `CUSTOM_PARAMETERS` - used to specify validator's command line parameters, default - empty string (no parameters),
  optional.

`faucet` container:

* `FAUCET_USE_RECAPTCHA` - if `false` faucet will not use recaptcha as protection, mandatory, default `true`;
* `RECAPTCHA_SITE_KEY` - used by local http-server that runs faucet service, mandatory;
* `RECAPTCHA_SECRET` - used by local http-server that runs faucet service, , mandatory;
* `FAUCET_REQUEST_EXPIRATION_PERIOD` - used by local http-server that runs faucet service, default `86400` seconds (
  24h), optional;
* `FAUCET_SINGLE_GIVEAWAY` - used by local http-server that runs faucet service, default `10` toncoins, optional;
* `SERVER_PORT` - used by local http-server that runs faucet service, default port `88`, optional;

`data` container (used for traffic generation):

* `SERVER_PORT` - used by local http-server that runs data service, default port `99`, optional;
* `PERIOD` - period in minutes on how often to run all scenarios. More details on wiki.

`blockchain-explorer` container:

* `SERVER_PORT` - used by local TON blockchain-explorer, default port `8080`, optional;

Can be set for all validator-N containers:

* `VERBOSITY` - set verbosity level for validator-engine. Default 1, allowed values: 0, 1, 2, 3, 4;
* `PUBLIC_PORT` - set public port (udp) for validator-engine, default port `40001`, optional;
* `CONSOLE_PORT` - set port for validator-engine-console, default port `40002`, optional;
* `LITE_PORT` - set port for lite-server, default port `40004`, optional.

### Build from sources

Clone this repo, build Java projects and execute:

`docker-compose -f docker-compose-build.yaml up -d`

### Access services

| Service name        | Link                                                                                     | 
|---------------------|------------------------------------------------------------------------------------------|
| TON-HTTP-API V2     | http://127.0.0.1:8081/                                                                   | 
| TON-HTTP-API V3     | http://127.0.0.1:8082/                                                                   |
| Blockchain explorer | http://127.0.0.1:8080/last                                                               |
| Faucet              | http://127.0.0.1:88                                                                      |
| Traffic generation  | http://127.0.0.1:99/                                                                     |
| Simple HTTP server  | http://127.0.0.1:8000/                                                                   |
| Lite-server         | `lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last` |

Global network configuration file available at:

http://127.0.0.1:8000/global.config.json

### Go inside the container

```
docker exec -it genesis bash
docker exec -it validator-1 bash
docker exec -it validator-2 bash
docker exec -it validator-3 bash
docker exec -it validator-4 bash
docker exec -it validator-5 bash

# each container has some predefined aliases:
last, getstats, config32, config34, config36, elid, participants
```

### Stop all containers

```docker-compose down```

the state will be persisted, and the next time when you start the containers up the blockchain will be resumed from the
last state.

If you want to access TON working directory and/or to keep database state even after rebuilding images, uncomment and
adjust the volume section for `ton-db` in main yaml file.

### Reset network and remove all data:

```docker-compose down -v --rmi all```

## Features

* Validation
    * automatic participation in elections and reaping of rewards
    * specify from 1 to 6 validators on start
    * validation cycle lasts 20 minutes (can be changed via env var VALIDATION_PERIOD)
    * be default, elections last 10 minutes (starts 5 minutes after validation cycle starts and finishes 5 minutes
      before validation cycles ends)
    * minimum validator stake is set to 100mln;
    * stake freeze period 3 minutes
    * predefined validators' wallet addresses (`V3R2`, subWalletId = `42`)
        * genesis:
            * address `-1:6744e92c6f71c776fbbcef299e31bf76f39c245cd56f2075b89c6a22026b4131`
            * private key `3c5156df1a46a1c84264c5e4019b9172232595936729595da5c15267c0761ba8`
            *
          mnemonic `quantum input cannon actress public limit case torch manage pig wrestle sunny riot midnight mouse romance guitar chat race famous jacket donor empty sad`
        * validator-1:
            * address `-1:ac76977d75e874006e37bf1113ff0b111851b1b72217b7e281424d2389be0122`
            * private key `bf97c398d24e3d23a1dcf48120a43f0981ec331cf3e1632ba641157694a9b0c8`
            *
          mnemonic `dentist melt vault invest alcohol argue sausage embrace afford verify control credit waste file hope vocal air ahead gesture wage innocent today party salad`
        * validator-2:
            * address `-1:061e92aa93905a0e1499dd9964f5c8e06d8bfe349c0dee03c6395b609a9b2e63`
            * private key `bd8343a5338eaa2f4ca327755cc6e23a46dc916db6397c7164abec4fa74470d4`
            *
          mnemonic `involve talk only inform oblige police liberty inform brain daughter erode arrest betray situate gesture curious talent position response window flower car include hunt`
        * validator-3:
            * address `-1:05045ba974ca403d9bf46b4835fd5cbd0a525c366a92cd020ea2af39761d9e99`
            * private key `9b87d2d9356ef460c2a5b7d087ac7753abb7a4080b3bd48898012e92c12603dc`
            *
          mnemonic `prevent farm bottom wasp limb black planet spider glove grunt apart nerve run motor depart kick about exchange delay police saddle image blast satoshi`
        * validator-4:
            * address `-1:578a994a4be99fedf40953621cf780d109aea2126de9c1ad5362ece75867a10a`
            * private key `ca76a4fc98b7f0f8dcbcc051b2c44e5ffa46340ba613edf72be50d4bc9bdd9ea`
            *
          mnemonic `tattoo program weird deer minimum replace dwarf blind guess cotton casual tool smooth carbon guide poet uphold cheese stand sunset fetch drink dumb chaos`
        * validator-5:
            * address `-1:f002d1a5106c751c7346369cda745085253cb9bf009e5769a017a28e2264faab`
            * private key `6d2b9c3d816edb18f7114df57123aa3ad0d4a453ba9e01081635f6d8c58d3cc2`
            *
          mnemonic `alley brass abandon essence boring sing bundle knee image pilot life noodle rough always drastic approve quick spot spy bronze behind include merit mutual`
* Predefined Faucet Wallets with 1 million toncoins of initial balance
    * Wallet V3R2
        * address `-1:22f53b7d9aba2cef44755f7078b01614cd4dde2388a1729c2c386cf8f9898afe`
        * private key `a51e8fb6f0fae3834bf430f5012589d319e7b3b3303ceb82c816b762fccf2d05`
        *
      mnemonic `viable model canvas decade neck soap turtle asthma bench crouch bicycle grief history envelope valid intact invest like offer urban adjust popular draft coral`
        * subWallet Id `42`
    * Highload Wallet V1
        * address `-1:5ee77ced0b7ae6ef88ab3f4350d8872c64667ffbe76073455215d3cdfab3294b`
        * private key `e1480435871753a968ef08edabb24f5532dab4cd904dbdc683b8576fb45fa697`
        *
      mnemonic `twenty unfair stay entry during please water april fabric morning length lumber style tomorrow melody similar forum width ride render void rather custom coin`
        * queryId `0`
    * Data Highload Wallet V1 (used by traffic generator)
        * address `-1:10df89757ee2bd09779d876a29b3e8ec4e706f902c9704eea5434d0a165e7ccd`
        * private key `f2480435871753a968ef08edabb24f5532dab4cd904dbdc683b8576fb45fa697`
        * queryId `0`
* Predefined lite-server
    * `lite-client -a 127.0.0.1:40004 -b E7XwFSQzNkcRepUC23J2nRpASXpnsEKmyyHYV4u/FZY= -c last`
* Faucet web server with reCaptcha V2 functionality
    * uncomment section in `docker-compose.yaml` to enable;
    * specify RECAPTCHA_SITE_KEY and RECAPTCHA_SECRET reCaptcha parameters;
    * hardcoded rate limit per session - 10 requests per minute per session.
* Native TON blockchain-explorer:
    * enabled on http://127.0.0.1:8080/last by default
* Integrated TON Index API V2 engine (https://toncenter.com/api/v2/)
* Integrated TON Index API V3 engine (https://toncenter.com/api/v3/index.html)
* cross-platform (arm64/amd64)
* tested on Ubuntu, Windows and MacOS

## Development using TON third party libraries

### Using W3R2 faucet with help of ton4j - https://github.com/neodiX42/ton4j

```java
Tonlib tonlib=
        Tonlib.builder()
        .pathToTonlibSharedLib(Utils.getTonlibGithubUrl())
        .pathToGlobalConfig("http://127.0.0.1:8000/localhost.global.config.json")
        .ignoreCache(false)
        .build();

        log.info("last {}",tonlib.getLast());

        byte[]prvKey=Utils.hexToSignedBytes("a51e8fb6f0fae3834bf430f5012589d319e7b3b3303ceb82c816b762fccf2d05");

// to use mnemonic
//        byte[] prvKey =
//        Mnemonic.toKeyPair(
//        Arrays.asList(
//        "viable","model", "canvas", "decade", "neck", "soap","turtle", "asthma", "bench",
//        "crouch", "bicycle", "grief", "history", "envelope", "valid", "intact", "invest",
//        "like", "offer", "urban", "adjust", "popular", "draft", "coral"))
//        .getSecretKey();
        TweetNaclFast.Signature.KeyPair keyPair=Utils.generateSignatureKeyPairFromSeed(prvKey);

        WalletV3R2 contract=WalletV3R2.builder().tonlib(tonlib).wc(-1).keyPair(keyPair).walletId(42).build();
        log.info("WalletV3R2 address {}",contract.getAddress().toRaw());
        assertThat(contract.getAddress().toRaw()).isEqualTo("-1:22f53b7d9aba2cef44755f7078b01614cd4dde2388a1729c2c386cf8f9898afe");
```

### Using Highload Wallet V2 faucet with help of ton4j

```java
byte[]prvKey=Utils.hexToSignedBytes("e1480435871753a968ef08edabb24f5532dab4cd904dbdc683b8576fb45fa697");
        TweetNaclFast.Signature.KeyPair keyPair=Utils.generateSignatureKeyPairFromSeed(prvKey);

        HighloadWallet highloadFaucet=
        HighloadWallet.builder()
        .tonlib(tonlib)
        .keyPair(keyPair)
        .wc(-1)
        .walletId(42L)
        .queryId(BigInteger.ZERO)
        .build();

        List<Destination> destinations=new ArrayList<>(); // fill it up

        HighloadConfig config=
        HighloadConfig.builder()
        .walletId(42)
        .queryId(BigInteger.valueOf(Instant.now().getEpochSecond()+60L<<32))
        .destinations(
        Arrays.asList(
        Destination.builder()
        .address("EQAaGHUHfkpWFGs428ETmym4vbvRNxCA1o4sTkwqigKjgf-_")
        .amount(Utils.toNano(0.3))
        .build()))
        .build();

        ExtMessageInfo extMessageInfo=highloadFaucet.send(config);
```

**Important!** MyLocalTon-Docker lite-server runs inside genesis container in its own network on IP `172.28.1.1` (
integer `-1407450879`),
if you want to access it from local host you have to refer to `127.0.0.1` IP address.

Go inside `global.config.json` and in `liteservers` section replace this IP `-1407450879` to this one `2130706433` or
download
`localhost.global.config.json` from file http server http://127.0.0.1:8000 if it is enabled.