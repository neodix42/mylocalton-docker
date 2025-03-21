package org.ton.mylocaltondocker.faucet.db;

import lombok.Builder;
import lombok.ToString;

@Builder
@ToString
public class WalletPk {
    String walletAddress;
}