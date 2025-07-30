package org.ton.mylocaltondocker.timemachine;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.ApplicationContext;
import org.ton.java.adnl.AdnlLiteClient;
import org.ton.mylocaltondocker.timemachine.controller.StartUpTask;

@SpringBootApplication
public class Main {

  public static AdnlLiteClient adnlLiteClient;
  private static ApplicationContext applicationContext;
  
  public static void main(String[] args) {
    applicationContext = SpringApplication.run(Main.class, args);
  }
  
  /**
   * Thread-safe method to get AdnlLiteClient instance.
   * Delegates to StartUpTask's thread-safe implementation.
   * 
   * @return AdnlLiteClient instance
   * @throws RuntimeException if client initialization fails
   */
  public static AdnlLiteClient getAdnlLiteClient() {
    if (applicationContext != null) {
      StartUpTask startUpTask = applicationContext.getBean(StartUpTask.class);
      return startUpTask.getAdnlLiteClient();
    }
    
    // Fallback to the static instance if Spring context is not available
    if (adnlLiteClient != null) {
      return adnlLiteClient;
    }
    
    throw new RuntimeException("AdnlLiteClient not initialized and Spring context not available");
  }
}
