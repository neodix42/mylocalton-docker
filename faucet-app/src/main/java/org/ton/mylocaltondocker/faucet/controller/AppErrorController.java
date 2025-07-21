package org.ton.mylocaltondocker.faucet.controller;

import org.springframework.boot.web.error.ErrorAttributeOptions;
import org.springframework.boot.web.servlet.error.ErrorAttributes;
import org.springframework.boot.web.servlet.error.ErrorController;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Controller;
import org.springframework.web.context.request.WebRequest;

import java.util.Map;

@Controller
public class AppErrorController implements ErrorController {

  private final ErrorAttributes errorAttributes;

  public AppErrorController(ErrorAttributes errorAttributes) {
    this.errorAttributes = errorAttributes;
  }

  private static final String PATH = "/error";

  public ResponseEntity<Map<String, Object>> handleError(WebRequest webRequest) {
    Map<String, Object> errorDetails =
        errorAttributes.getErrorAttributes(
            webRequest, ErrorAttributeOptions.of(ErrorAttributeOptions.Include.MESSAGE));

    System.err.println("Error occurred: " + errorDetails);

    return ResponseEntity.status(
            (int) errorDetails.getOrDefault("status", HttpStatus.INTERNAL_SERVER_ERROR.value()))
        .body(errorDetails);
  }
}
