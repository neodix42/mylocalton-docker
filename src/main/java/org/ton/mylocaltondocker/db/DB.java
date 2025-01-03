package org.ton.mylocaltondocker.db;

import lombok.extern.slf4j.Slf4j;

import javax.persistence.*;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import static java.util.Objects.nonNull;

@Slf4j
public class DB {

  public static final EntityManagerFactory emf;

  private DB() {}

  static {
    emf = Persistence.createEntityManagerFactory("objectdb:/scripts/web/myLocalTon.odb");
    //    emf = Persistence.createEntityManagerFactory("objectdb:/g:/libs/myLocalTon.odb");
    log.info("DB initialized.");
  }

  public static boolean insertWallet(WalletEntity wallet) {
    EntityManager em = emf.createEntityManager();
    try {
      //      log.info("inserting into db wallet {}", wallet);
      em.getTransaction().begin();
      em.persist(wallet);
      em.getTransaction().commit();
      log.info("wallet inserted into db {}", wallet);
      return true;
    } catch (Exception e) {
      log.error("cannot insert wallet {}", wallet);
      return false;
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static void deleteWallet(WalletPk walletPk) {
    EntityManager em = emf.createEntityManager();
    try {
      WalletEntity walletEntity = em.find(WalletEntity.class, walletPk);
      if (nonNull(walletEntity)) {
        em.getTransaction().begin();
        em.remove(walletEntity);
        em.getTransaction().commit();
        log.info("wallet deleted {}", walletPk);
      }
    } catch (Exception e) {
      log.error("cannot delete wallet {}", walletPk);
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static void updateWalletStatus(WalletPk walletPk, String status) {
    EntityManager em = emf.createEntityManager();
    try {
      WalletEntity walletEntity = em.find(WalletEntity.class, walletPk);
      if (nonNull(walletEntity)) {
        em.getTransaction().begin();
        walletEntity.setStatus(status);
        em.getTransaction().commit();
        log.info("wallet updated {}", walletEntity);
      }
    } catch (Exception e) {
      log.error("cannot update wallet status {}", walletPk);
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static List<WalletEntity> getWalletsToSend() {
    EntityManager em = emf.createEntityManager();
    try {
      List<WalletEntity> results =
          em.createQuery(
                  "SELECT b FROM WalletEntity b where status is null ORDER BY b.createdAt ASC",
                  WalletEntity.class)
              .getResultList();
      return results;
    } catch (Exception e) {
      log.error("cannot get wallets to send {}", e.getMessage());
      return new ArrayList<>();
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static List<WalletEntity> getWalletsSent() {
    EntityManager em = emf.createEntityManager();
    try {
      List<WalletEntity> results =
          em.createQuery(
                  "SELECT b FROM WalletEntity b where status = 'sent' ORDER BY b.createdAt ASC",
                  WalletEntity.class)
              .getResultList();
      return results;
    } catch (Exception e) {
      log.error("cannot get wallets sent {}", e.getMessage());
      return new ArrayList<>();
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static long getTotalWallets() {
    EntityManager em = emf.createEntityManager();
    try {
      return em.createQuery("SELECT count(b) FROM WalletEntity b", Long.class).getSingleResult();
    } catch (Exception e) {
      log.error("cannot get total wallets {}", e.getMessage());
      return -1;
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static List<WalletEntity> findRemoteIp(String remoteIp) {
    EntityManager em = emf.createEntityManager();
    try {
      TypedQuery<WalletEntity> query =
          em.createQuery(
              "SELECT b FROM WalletEntity b where b.remoteIp = :remoteip", WalletEntity.class);
      List<WalletEntity> results = query.setParameter("remoteip", remoteIp).getResultList();
      return results;
    } catch (Exception e) {
      log.error("cannot find wallet by remote ip {}", e.getMessage());
      return new ArrayList<>();
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static long deleteExpiredWallets(long expirationPeriod) {
    EntityManager em = emf.createEntityManager();
    try {
      em.getTransaction().begin();
      Query query =
          em.createQuery(
              "DELETE FROM WalletEntity b where b.createdAt + :expirationperiod < :datetimenow",
              WalletEntity.class);
      int deletedCount =
          query
              .setParameter("expirationperiod", expirationPeriod)
              .setParameter("datetimenow", Instant.now().getEpochSecond())
              .executeUpdate();
      em.getTransaction().commit();
      log.info("deleted from queue {}", deletedCount);

      return deletedCount;
    } catch (Exception e) {
      log.error("cannot delete expired wallets {}", e.getMessage());
      return -1;
    } finally {
      if (em.getTransaction().isActive()) em.getTransaction().rollback();
      if (em.isOpen()) em.close();
    }
  }

  public static WalletEntity findWallet(WalletPk walletPk) {
    EntityManager em = emf.createEntityManager();
    try {
      return em.find(WalletEntity.class, walletPk);
    } catch (Exception e) {
      log.error("cannot find wallet {}", walletPk);
      return null;
    } finally {
      if (em.isOpen()) em.close();
    }
  }
}
