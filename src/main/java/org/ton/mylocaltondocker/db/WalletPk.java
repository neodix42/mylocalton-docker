package org.ton.mylocaltondocker.db;

import lombok.Builder;
import lombok.ToString;

@Builder
@ToString
public class WalletPk {
    String walletAddress;
}