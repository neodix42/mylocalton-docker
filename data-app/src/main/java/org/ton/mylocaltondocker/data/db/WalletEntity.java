package org.ton.mylocaltondocker.data.db;


import javax.persistence.Entity;
import javax.persistence.Id;
import javax.persistence.IdClass;

import lombok.*;

import java.math.BigInteger;

@Entity
@Builder
@Data
@IdClass(WalletPk.class)
public class WalletEntity {
    @Id
    String walletAddress;

    long createdAt;

    BigInteger balance;

    String status;

    public WalletPk getPrimaryKey() {
        return WalletPk.builder()
                .walletAddress(walletAddress)
                .build();
    }
}
