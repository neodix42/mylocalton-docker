package org.ton.mylocaltondocker.timemachine.controller;

import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;
import org.springframework.web.servlet.config.annotation.ResourceHandlerRegistry;
import org.springframework.web.servlet.config.annotation.ViewControllerRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

@Configuration
public class CustomWebConfig implements WebMvcConfigurer {

  private static final String CUSTOM_STATIC_DIR = "file:/scripts/web/";
//  private static final String CUSTOM_STATIC_DIR = "file:./docker/scripts/web/";

  @Override
  public void addResourceHandlers(ResourceHandlerRegistry registry) {
    // Serve static files with lower priority than REST controllers
    registry.addResourceHandler("/**")
            .addResourceLocations(CUSTOM_STATIC_DIR)
            .setCachePeriod(0)
            .resourceChain(false);
    
    // Set lower priority for static resources
    registry.setOrder(Ordered.LOWEST_PRECEDENCE);
  }

  @Override
  public void addViewControllers(ViewControllerRegistry registry) {
    registry.addViewController("/").setViewName("forward:/index.html");
  }
}
