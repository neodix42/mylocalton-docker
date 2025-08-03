package org.ton.mylocaltondocker.timemachine.controller;

import com.github.dockerjava.api.model.Ports;
import com.google.gson.JsonElement;
import com.google.gson.JsonSerializationContext;
import com.google.gson.JsonSerializer;

import java.lang.reflect.Type;

public class PortsSerializer implements JsonSerializer<Ports> {
    @Override
    public JsonElement serialize(Ports src, Type typeOfSrc, JsonSerializationContext context) {
        if (src == null) {
            return null;
        }
        // Use the toPrimitive() method to get the map representation
        return context.serialize(src.toPrimitive());
    }
}
