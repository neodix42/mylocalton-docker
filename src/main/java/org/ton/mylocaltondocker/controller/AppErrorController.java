package org.ton.mylocaltondocker.controller;

import org.springframework.boot.web.servlet.error.ErrorController;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseBody;

@Controller
public class AppErrorController implements ErrorController {
  private static final String PATH = "/error";

  @RequestMapping(value = PATH, produces = "text/html")
  @ResponseBody
  public String getErrorPath() {
    return "No Mapping Found";
  }
}
