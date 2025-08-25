package org.ton.mylocaltondocker.timemachine.controller;

import com.github.dockerjava.api.model.Ports;
import com.google.gson.JsonDeserializationContext;
import com.google.gson.JsonDeserializer;
import com.google.gson.JsonElement;
import com.google.gson.JsonParseException;
import com.google.gson.reflect.TypeToken;

import java.lang.reflect.Type;
import java.util.List;
import java.util.Map;

public class PortsDeserializer implements JsonDeserializer<Ports> {
  @Override
  public Ports deserialize(JsonElement json, Type typeOfT, JsonDeserializationContext context)
      throws JsonParseException {
    Map<String, List<Map<String, String>>> map =
        context.deserialize(
            json, new TypeToken<Map<String, List<Map<String, String>>>>() {}.getType());
    return Ports.fromPrimitive(map);
  }
}
