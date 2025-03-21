package org.ton.mylocaltondocker.faucet.db;


import javax.persistence.Entity;
import javax.persistence.Id;
import javax.persistence.IdClass;

import lombok.*;

@Entity
@Builder
@Data
@IdClass(WalletPk.class)
public class WalletEntity {
    @Id
    String walletAddress;

    long createdAt;

    String remoteIp;

    String status;

    public WalletPk getPrimaryKey() {
        return WalletPk.builder()
                .walletAddress(walletAddress)
                .build();
    }
}
