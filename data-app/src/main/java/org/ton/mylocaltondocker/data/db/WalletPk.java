package org.ton.mylocaltondocker.data.db;

import lombok.Builder;
import lombok.ToString;

@Builder
@ToString
public class WalletPk {
    String walletAddress;
}