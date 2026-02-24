package org.ton.mylocaltondocker.configupdate.service;

import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.ton.mylocaltondocker.configupdate.Main;
import org.ton.ton4j.address.Address;
import org.ton.ton4j.cell.Cell;
import org.ton.ton4j.cell.CellBuilder;
import org.ton.ton4j.cell.CellSlice;
import org.ton.ton4j.cell.TonHashMap;
import org.ton.ton4j.cell.TonHashMapE;
import org.ton.ton4j.provider.SendResponse;
import org.ton.ton4j.smartcontract.utils.MsgUtils;
import org.ton.ton4j.tl.liteserver.responses.ConfigInfo;
import org.ton.ton4j.tlb.Account;
import org.ton.ton4j.tlb.BlockLimits;
import org.ton.ton4j.tlb.BlockLimitsV1;
import org.ton.ton4j.tlb.BlockLimitsV2;
import org.ton.ton4j.tlb.CatchainConfig;
import org.ton.ton4j.tlb.CatchainConfigC1;
import org.ton.ton4j.tlb.CatchainConfigC2;
import org.ton.ton4j.tlb.ConfigParams0;
import org.ton.ton4j.tlb.ConfigParams1;
import org.ton.ton4j.tlb.ConfigParams10;
import org.ton.ton4j.tlb.ConfigParams11;
import org.ton.ton4j.tlb.ConfigParams12;
import org.ton.ton4j.tlb.ConfigParams13;
import org.ton.ton4j.tlb.ConfigParams14;
import org.ton.ton4j.tlb.ConfigParams15;
import org.ton.ton4j.tlb.ConfigParams16;
import org.ton.ton4j.tlb.ConfigParams17;
import org.ton.ton4j.tlb.ConfigParams18;
import org.ton.ton4j.tlb.ConfigParams19;
import org.ton.ton4j.tlb.ConfigParams2;
import org.ton.ton4j.tlb.ConfigParams20;
import org.ton.ton4j.tlb.ConfigParams21;
import org.ton.ton4j.tlb.ConfigParams22;
import org.ton.ton4j.tlb.ConfigParams23;
import org.ton.ton4j.tlb.ConfigParams24;
import org.ton.ton4j.tlb.ConfigParams25;
import org.ton.ton4j.tlb.ConfigParams28;
import org.ton.ton4j.tlb.ConfigParams29;
import org.ton.ton4j.tlb.ConfigParams3;
import org.ton.ton4j.tlb.ConfigParams31;
import org.ton.ton4j.tlb.ConfigParams32;
import org.ton.ton4j.tlb.ConfigParams33;
import org.ton.ton4j.tlb.ConfigParams34;
import org.ton.ton4j.tlb.ConfigParams35;
import org.ton.ton4j.tlb.ConfigParams36;
import org.ton.ton4j.tlb.ConfigParams37;
import org.ton.ton4j.tlb.ConfigParams39;
import org.ton.ton4j.tlb.ConfigParams4;
import org.ton.ton4j.tlb.ConfigParams40;
import org.ton.ton4j.tlb.ConfigParams44;
import org.ton.ton4j.tlb.ConfigParams45;
import org.ton.ton4j.tlb.ConfigParams5;
import org.ton.ton4j.tlb.ConfigParams6;
import org.ton.ton4j.tlb.ConfigParams7;
import org.ton.ton4j.tlb.ConfigParams71;
import org.ton.ton4j.tlb.ConfigParams72;
import org.ton.ton4j.tlb.ConfigParams73;
import org.ton.ton4j.tlb.ConfigParams79;
import org.ton.ton4j.tlb.ConfigParams8;
import org.ton.ton4j.tlb.ConfigParams81;
import org.ton.ton4j.tlb.ConfigParams82;
import org.ton.ton4j.tlb.ConfigParams9;
import org.ton.ton4j.tlb.ConsensusConfig;
import org.ton.ton4j.tlb.ConsensusConfigNew;
import org.ton.ton4j.tlb.ConsensusConfigV1;
import org.ton.ton4j.tlb.ConsensusConfigV3;
import org.ton.ton4j.tlb.ConsensusConfigV4;
import org.ton.ton4j.tlb.CryptoSignature;
import org.ton.ton4j.tlb.GasLimitsPrices;
import org.ton.ton4j.tlb.GasLimitsPricesExt;
import org.ton.ton4j.tlb.GasLimitsPricesOrdinary;
import org.ton.ton4j.tlb.GasLimitsPricesPfx;
import org.ton.ton4j.tlb.JettonBridgeParams;
import org.ton.ton4j.tlb.JettonBridgeParamsV1;
import org.ton.ton4j.tlb.JettonBridgeParamsV2;
import org.ton.ton4j.tlb.Message;
import org.ton.ton4j.tlb.OracleBridgeParams;
import org.ton.ton4j.tlb.PrecompiledSmc;
import org.ton.ton4j.tlb.SigPubKey;
import org.ton.ton4j.tlb.StoragePrices;
import org.ton.ton4j.tlb.Validator;
import org.ton.ton4j.tlb.ValidatorAddr;
import org.ton.ton4j.tlb.ValidatorDescr;
import org.ton.ton4j.tlb.ValidatorSet;
import org.ton.ton4j.tlb.ValidatorSignedTempKey;
import org.ton.ton4j.tlb.ValidatorTempKey;
import org.ton.ton4j.tlb.Validators;
import org.ton.ton4j.tlb.ValidatorsExt;
import org.ton.ton4j.tlb.WorkchainDescr;
import org.ton.ton4j.tlb.WorkchainDescrV1;
import org.ton.ton4j.tlb.WorkchainDescrV2;
import org.ton.ton4j.tlb.WorkchainFormat;
import org.ton.ton4j.tlb.WorkchainFormatBasic;
import org.ton.ton4j.tlb.WorkchainFormatExt;
import org.ton.ton4j.tlb.WcSplitMergeTimings;
import org.ton.ton4j.utils.Utils;

@Service
@Slf4j
public class ConfigUpdateService {

  private static final int UPDATE_CONFIG_OP = 0x43665021;
  private static final int MAX_SCHEMA_DEPTH = 20;
  private static final Pattern HEX_PATTERN = Pattern.compile("^(?:0x)?[0-9a-fA-F]+$");

  private static final List<Integer> SUPPORTED_PARAMS =
      List.of(
          0,
          1,
          2,
          3,
          4,
          5,
          6,
          7,
          8,
          9,
          10,
          11,
          12,
          13,
          14,
          15,
          16,
          17,
          18,
          19,
          20,
          21,
          22,
          23,
          24,
          25,
          28,
          29,
          31,
          32,
          33,
          34,
          35,
          36,
          37,
          39,
          40,
          44,
          45,
          71,
          72,
          73,
          79,
          81,
          82);

  private static final Map<Integer, String> PARAM_DESCRIPTIONS = createParamDescriptions();

  private static final Map<Integer, Class<?>> PARAM_CLASS_BY_ID = createParamClassById();
  private static final Map<Class<?>, List<Class<?>>> INTERFACE_OPTIONS = createInterfaceOptions();
  private static final Map<String, DictSpec> DICT_SPECS = createDictSpecs();
  private static final Map<String, BigIntFormatSpec> BIGINT_FORMAT_OVERRIDES =
      createBigIntFormatOverrides();
  private static final Map<String, Integer> UNSIGNED_NUMBER_FIELD_BITS =
      createUnsignedNumberFieldBits();

  private static final Set<String> TAG_FIELDS =
      Set.of("magic", "cfgVoteSetup", "cfgVoteCfg", "workchain", "wfmtBasic", "wfmtExt");

  private static final Map<String, String> FIELD_LABEL_OVERRIDES =
      Map.of(
          ConfigParams2.class.getName() + ".minterAddr", "minter address",
          ConfigParams0.class.getName() + ".configAddr", "config address",
          ConfigParams1.class.getName() + ".electorAddr", "elector address",
          ConfigParams3.class.getName() + ".feeCollectorAddr", "fee collector address",
          ConfigParams4.class.getName() + ".dnsRootAddr", "dns root address");

  private final Map<Integer, TypeSchema> schemaCache = new ConcurrentHashMap<>();
  private final Map<String, Optional<Integer>> addressWorkchainCache = new ConcurrentHashMap<>();

  public List<Map<String, Object>> getSupportedParams() {
    List<Map<String, Object>> result = new ArrayList<>();
    for (Integer id : SUPPORTED_PARAMS) {
      Class<?> paramClass = PARAM_CLASS_BY_ID.get(id);
      if (paramClass == null) {
        continue;
      }
      Map<String, Object> item = new LinkedHashMap<>();
      item.put("id", id);
      item.put("name", "ConfigParam" + id);
      item.put("description", PARAM_DESCRIPTIONS.getOrDefault(id, ""));
      item.put("className", paramClass.getSimpleName());
      item.put("title", "ConfigParam " + id);
      result.add(item);
    }
    return result;
  }

  public Map<String, Object> getParamDetails(int id) {
    Class<?> paramClass = requireSupportedParamClass(id);
    TypeSchema schema = schemaCache.computeIfAbsent(id, ignored -> buildSchema(paramClass, 0));

    Object currentValue = readCurrentParamObject(id, paramClass);

    Map<String, Object> response = new LinkedHashMap<>();
    response.put("id", id);
    response.put("className", paramClass.getSimpleName());
    response.put("title", "ConfigParam " + id);
    response.put("description", PARAM_DESCRIPTIONS.getOrDefault(id, ""));
    response.put("schema", schema.toPublicMap());
    response.put("value", toUiValue(currentValue, schema));
    return response;
  }

  public Map<String, Object> updateParam(int id, Object uiValue) {
    Class<?> paramClass = requireSupportedParamClass(id);
    TypeSchema schema = schemaCache.computeIfAbsent(id, ignored -> buildSchema(paramClass, 0));

    try {
      Object configParamObject = fromUiValue(uiValue, schema);
      if (configParamObject == null) {
        throw new IllegalArgumentException("Config parameter payload cannot be empty");
      }

      Cell paramCell = invokeToCell(configParamObject);
      long seqno = Main.adnlLiteClient.getSeqno(Main.CONFIG_SMART_CONTRACT_ADDRESS);

      Cell body =
          CellBuilder.beginCell()
              .storeUint(UPDATE_CONFIG_OP, 32)
              .storeUint(seqno, 32)
              .storeUint(Utils.now() + 60, 32)
              .storeUint(id, 32)
              .storeRef(paramCell)
              .endCell();

      Message externalMessage =
          MsgUtils.createExternalMessageWithSignedBody(
              Main.configKeyPair, Main.CONFIG_SMART_CONTRACT_ADDRESS, null, body);

      SendResponse sendResponse = Main.adnlLiteClient.sendExternalMessage(externalMessage);

      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", true);
      response.put("message", "Update message sent for ConfigParam " + id);
      response.put("seqno", seqno);
      response.put("sendResponse", sendResponse.toString());
      return response;
    } catch (Exception e) {
      log.error("Failed to update config param {}", id, e);
      Map<String, Object> response = new LinkedHashMap<>();
      response.put("success", false);
      response.put("message", resolveThrowableMessage(e));
      return response;
    }
  }

  private Class<?> requireSupportedParamClass(int id) {
    Class<?> paramClass = PARAM_CLASS_BY_ID.get(id);
    if (paramClass == null || !SUPPORTED_PARAMS.contains(id)) {
      throw new IllegalArgumentException("Unsupported config parameter: " + id);
    }
    if (Main.adnlLiteClient == null || Main.configKeyPair == null) {
      throw new IllegalStateException("Service is not initialized yet");
    }
    return paramClass;
  }

  private Object readCurrentParamObject(int id, Class<?> paramClass) {
    try {
      ConfigInfo configInfo = Main.adnlLiteClient.getConfigAll(Main.adnlLiteClient.getMasterchainInfo().getLast(), 0);
      Cell paramCell =
          (Cell) configInfo.getConfigParams().getConfig().getElements().get(BigInteger.valueOf(id));
      if (paramCell == null) {
        return instantiateClass(paramClass);
      }

      Method deserializeMethod = paramClass.getMethod("deserialize", CellSlice.class);
      return deserializeMethod.invoke(null, CellSlice.beginParse(paramCell));
    } catch (Exception e) {
      log.warn("Cannot deserialize ConfigParam {}, using empty value: {}", id, e.getMessage());
      return instantiateClass(paramClass);
    }
  }

  private Cell invokeToCell(Object value) throws Exception {
    Method toCellMethod = value.getClass().getMethod("toCell");
    return (Cell) toCellMethod.invoke(value);
  }

  private TypeSchema buildSchema(Class<?> javaType, int depth) {
    if (depth > MAX_SCHEMA_DEPTH) {
      throw new IllegalStateException("Schema nesting is too deep for " + javaType.getSimpleName());
    }

    if (javaType.equals(BigInteger.class)) {
      return TypeSchema.bigint(javaType, BigIntFormat.DECIMAL, 0);
    }
    if (javaType.equals(long.class) || javaType.equals(Long.class)) {
      return TypeSchema.longNumber(javaType);
    }
    if (javaType.equals(int.class) || javaType.equals(Integer.class)) {
      return TypeSchema.intNumber(javaType);
    }
    if (javaType.equals(boolean.class) || javaType.equals(Boolean.class)) {
      return TypeSchema.bool(javaType);
    }

    if (INTERFACE_OPTIONS.containsKey(javaType)) {
      List<TypeSchema> options = new ArrayList<>();
      for (Class<?> option : INTERFACE_OPTIONS.get(javaType)) {
        options.add(buildSchema(option, depth + 1));
      }
      return TypeSchema.choice(javaType, options);
    }

    return buildObjectSchema(javaType, depth + 1);
  }

  private TypeSchema buildObjectSchema(Class<?> javaType, int depth) {
    List<FieldSchema> fields = new ArrayList<>();
    for (Field field : getDeclaredEditableFields(javaType)) {
      field.setAccessible(true);

      String dictSpecKey = javaType.getName() + "." + field.getName();
      DictSpec dictSpec = DICT_SPECS.get(dictSpecKey);
      TypeSchema fieldSchema;

      if (dictSpec != null
          && (field.getType().equals(TonHashMap.class) || field.getType().equals(TonHashMapE.class))) {
        TypeSchema keySchema =
            buildSchemaForDictEntry(
                dictSpec.keyClass(), dictSpec.keyFormat(), dictSpec.keyBits(), depth + 1);
        TypeSchema valueSchema =
            dictSpec.unitValue()
                ? TypeSchema.unit()
                : buildSchemaForDictEntry(
                    dictSpec.valueClass(),
                    dictSpec.valueFormat(),
                    dictSpec.valueBits(),
                    depth + 1);
        fieldSchema = TypeSchema.dict(field.getType(), dictSpec, keySchema, valueSchema);
      } else if (javaType.equals(GasLimitsPricesPfx.class) && field.getName().equals("other")) {
        // GasLimitsPricesPfx -> other:GasLimitsPrices is recursive. Limit this branch to non-pfx
        // variants to keep the schema finite for UI rendering.
        List<TypeSchema> finiteOptions = new ArrayList<>();
        finiteOptions.add(buildSchema(GasLimitsPricesOrdinary.class, depth + 1));
        finiteOptions.add(buildSchema(GasLimitsPricesExt.class, depth + 1));
        fieldSchema = TypeSchema.choice(GasLimitsPrices.class, finiteOptions);
      } else if (field.getType().equals(BigInteger.class)) {
        fieldSchema = buildBigIntFieldSchema(javaType, field);
      } else {
        fieldSchema = buildSchema(field.getType(), depth + 1);
      }

      String label = resolveFieldLabel(javaType, field);
      boolean optional = !field.getType().isPrimitive();
      fields.add(new FieldSchema(field, field.getName(), label, optional, fieldSchema));
    }

    return TypeSchema.object(javaType, fields);
  }

  private List<Field> getDeclaredEditableFields(Class<?> javaType) {
    Field[] fields = javaType.getDeclaredFields();
    List<Field> editable = new ArrayList<>();
    for (Field field : fields) {
      if (Modifier.isStatic(field.getModifiers())) {
        continue;
      }
      if (field.isSynthetic()) {
        continue;
      }
      if (TAG_FIELDS.contains(field.getName())) {
        continue;
      }
      editable.add(field);
    }
    return editable;
  }

  private String resolveFieldLabel(Class<?> ownerType, Field field) {
    String override = FIELD_LABEL_OVERRIDES.get(ownerType.getName() + "." + field.getName());
    if (override != null) {
      return override;
    }
    String raw = field.getName();
    return raw.replaceAll("([a-z])([A-Z])", "$1 $2").toLowerCase(Locale.ROOT);
  }

  private TypeSchema buildBigIntFieldSchema(Class<?> ownerType, Field field) {
    String key = ownerType.getName() + "." + field.getName();
    BigIntFormatSpec formatSpec = BIGINT_FORMAT_OVERRIDES.get(key);
    if (formatSpec == null) {
      return TypeSchema.bigint(BigInteger.class, BigIntFormat.DECIMAL, 0);
    }
    return TypeSchema.bigint(BigInteger.class, formatSpec.format(), formatSpec.bits());
  }

  private TypeSchema buildSchemaForDictEntry(
      Class<?> javaType, BigIntFormat bigIntFormat, int bits, int depth) {
    if (javaType.equals(BigInteger.class)) {
      return TypeSchema.bigint(BigInteger.class, bigIntFormat, bits);
    }
    return buildSchema(javaType, depth);
  }

  private Object toUiValue(Object value, TypeSchema schema) {
    if (value == null) {
      if (schema.kind == SchemaKind.UNIT) {
        return true;
      }
      return null;
    }

    switch (schema.kind) {
      case BIGINT:
        return formatBigInteger((BigInteger) value, schema);
      case LONG:
      case INT:
        return String.valueOf(value);
      case BOOLEAN:
        return value;
      case UNIT:
        return true;
      case CHOICE:
        return toUiChoiceValue(value, schema);
      case OBJECT:
        return toUiObjectValue(value, schema);
      case DICT:
        return toUiDictValue(value, schema);
      default:
        throw new IllegalStateException("Unsupported schema kind " + schema.kind);
    }
  }

  private String formatBigInteger(BigInteger value, TypeSchema schema) {
    if (value == null) {
      return "";
    }

    BigIntFormat format =
        schema.bigIntFormat == null ? BigIntFormat.DECIMAL : schema.bigIntFormat;
    int bits = schema.bigIntBits == null ? 0 : schema.bigIntBits;

    if (format == BigIntFormat.DECIMAL) {
      return value.toString();
    }

    String hexValue = formatHex(value, bits);
    if (format == BigIntFormat.HEX) {
      return hexValue;
    }

    // ADDRESS_OR_HEX
    if (bits == 256) {
      Optional<Integer> wc = detectAddressWorkchain(hexValue);
      if (wc.isPresent()) {
        return wc.get() + ":" + hexValue;
      }
    }
    return hexValue;
  }

  private String formatHex(BigInteger value, int bits) {
    if (value == null) {
      return "";
    }
    String hex = value.toString(16);
    if (hex.startsWith("-")) {
      return hex;
    }
    if (bits <= 0) {
      return hex;
    }
    int expectedLength = (bits + 3) / 4;
    if (hex.length() >= expectedLength) {
      return hex;
    }
    return "0".repeat(expectedLength - hex.length()) + hex;
  }

  private Optional<Integer> detectAddressWorkchain(String hex256) {
    if (hex256 == null || hex256.isBlank()) {
      return Optional.empty();
    }

    return addressWorkchainCache.computeIfAbsent(
        hex256,
        key -> {
          for (int wc : List.of(-1, 0)) {
            try {
              Account account = Main.adnlLiteClient.getAccount(Address.of(wc + ":" + key));
              if (account != null && !account.isNone()) {
                return Optional.of(wc);
              }
            } catch (Exception ignored) {
              // ignore and try the next workchain
            }
          }
          return Optional.empty();
        });
  }

  private Object toUiChoiceValue(Object value, TypeSchema schema) {
    Optional<TypeSchema> selectedOption =
        schema.options.stream()
            .filter(option -> option.javaType.equals(value.getClass()))
            .findFirst();

    TypeSchema optionSchema = selectedOption.orElse(schema.options.get(0));
    return toUiObjectValue(value, optionSchema);
  }

  private Object toUiObjectValue(Object value, TypeSchema schema) {
    Map<String, Object> map = new LinkedHashMap<>();
    map.put("_type", schema.javaType.getSimpleName());

    for (FieldSchema fieldSchema : schema.fields) {
      try {
        Object fieldValue = fieldSchema.field.get(value);
        map.put(fieldSchema.name, toUiFieldValue(schema.javaType, fieldSchema, fieldValue));
      } catch (IllegalAccessException e) {
        throw new IllegalStateException("Cannot read field " + fieldSchema.name, e);
      }
    }
    return map;
  }

  private Object toUiFieldValue(Class<?> ownerType, FieldSchema fieldSchema, Object fieldValue) {
    if (fieldValue == null) {
      return toUiValue(null, fieldSchema.schema);
    }

    Integer bits = UNSIGNED_NUMBER_FIELD_BITS.get(ownerType.getName() + "." + fieldSchema.name);
    if (bits != null
        && (fieldSchema.schema.kind == SchemaKind.LONG || fieldSchema.schema.kind == SchemaKind.INT)
        && fieldValue instanceof Number numberValue) {
      return formatUnsignedNumber(numberValue.longValue(), bits);
    }

    return toUiValue(fieldValue, fieldSchema.schema);
  }

  private Object toUiDictValue(Object value, TypeSchema schema) {
    TonHashMap dict = (TonHashMap) value;
    if (dict == null || dict.getElements() == null || dict.getElements().isEmpty()) {
      return new ArrayList<>();
    }

    List<Map<String, Object>> entries = new ArrayList<>();
    for (Map.Entry<Object, Object> entry : dict.getElements().entrySet()) {
      Map<String, Object> item = new LinkedHashMap<>();
      item.put("key", toUiValue(entry.getKey(), schema.keySchema));
      if (!schema.dictSpec.unitValue()) {
        item.put("value", toUiValue(entry.getValue(), schema.valueSchema));
      }
      entries.add(item);
    }
    return entries;
  }

  private Object fromUiValue(Object uiValue, TypeSchema schema) {
    if (uiValue == null) {
      return null;
    }

    switch (schema.kind) {
      case BIGINT:
        return parseBigInteger(uiValue);
      case LONG:
        return parseLong(uiValue);
      case INT:
        return parseInt(uiValue);
      case BOOLEAN:
        return parseBoolean(uiValue);
      case UNIT:
        return Boolean.TRUE;
      case CHOICE:
        return fromUiChoice(uiValue, schema);
      case OBJECT:
        return fromUiObject(uiValue, schema);
      case DICT:
        return fromUiDict(uiValue, schema);
      default:
        throw new IllegalStateException("Unsupported schema kind " + schema.kind);
    }
  }

  private Object fromUiChoice(Object uiValue, TypeSchema schema) {
    if (!(uiValue instanceof Map<?, ?> valueMap)) {
      return null;
    }

    String typeName = asString(valueMap.get("_type"));
    TypeSchema selected =
        schema.options.stream()
            .filter(option -> option.javaType.getSimpleName().equals(typeName))
            .findFirst()
            .orElse(schema.options.get(0));

    return fromUiObject(uiValue, selected);
  }

  private Object fromUiObject(Object uiValue, TypeSchema schema) {
    if (!(uiValue instanceof Map<?, ?> valueMap)) {
      return null;
    }

    Object instance = instantiateClass(schema.javaType);

    for (FieldSchema fieldSchema : schema.fields) {
      Object rawValue = valueMap.get(fieldSchema.name);
      Object parsedValue = fromUiFieldValue(rawValue, schema.javaType, fieldSchema);

      try {
        if (parsedValue == null && fieldSchema.field.getType().isPrimitive()) {
          continue;
        }
        fieldSchema.field.set(instance, parsedValue);
      } catch (IllegalAccessException e) {
        throw new IllegalStateException("Cannot set field " + fieldSchema.name, e);
      }
    }

    return instance;
  }

  private Object fromUiFieldValue(Object rawValue, Class<?> ownerType, FieldSchema fieldSchema) {
    Integer bits = UNSIGNED_NUMBER_FIELD_BITS.get(ownerType.getName() + "." + fieldSchema.name);
    if (bits != null
        && (fieldSchema.schema.kind == SchemaKind.LONG || fieldSchema.schema.kind == SchemaKind.INT)) {
      return parseUnsignedNumber(rawValue, fieldSchema.field.getType(), bits, ownerType.getSimpleName() + "." + fieldSchema.name);
    }
    return fromUiValue(rawValue, fieldSchema.schema);
  }

  private Object fromUiDict(Object uiValue, TypeSchema schema) {
    TonHashMap dict =
        schema.javaType.equals(TonHashMap.class)
            ? new TonHashMap(schema.dictSpec.keyBits())
            : new TonHashMapE(schema.dictSpec.keyBits());

    if (!(uiValue instanceof List<?> items)) {
      return dict;
    }

    for (Object item : items) {
      if (!(item instanceof Map<?, ?> mapItem)) {
        continue;
      }

      Object rawKey = mapItem.get("key");
      if (rawKey == null || asString(rawKey).trim().isEmpty()) {
        continue;
      }

      Object parsedKey = fromUiValue(rawKey, schema.keySchema);
      if (parsedKey == null) {
        continue;
      }

      Object parsedValue;
      if (schema.dictSpec.unitValue()) {
        parsedValue = Boolean.TRUE;
      } else {
        parsedValue = fromUiValue(mapItem.get("value"), schema.valueSchema);
      }

      dict.getElements().put(parsedKey, parsedValue);
    }

    if (schema.javaType.equals(TonHashMap.class) && dict.getElements().isEmpty()) {
      throw new IllegalArgumentException("Non-empty dictionary field cannot be empty");
    }

    return dict;
  }

  private Object instantiateClass(Class<?> type) {
    try {
      var constructor = type.getDeclaredConstructor();
      constructor.setAccessible(true);
      return constructor.newInstance();
    } catch (Exception ignored) {
      try {
        Method builderMethod = type.getMethod("builder");
        Object builder = builderMethod.invoke(null);
        Method buildMethod = builder.getClass().getMethod("build");
        return buildMethod.invoke(builder);
      } catch (Exception e) {
        throw new IllegalStateException("Cannot instantiate " + type.getSimpleName(), e);
      }
    }
  }

  private BigInteger parseBigInteger(Object value) {
    if (value == null) {
      return null;
    }

    if (value instanceof BigInteger bigInteger) {
      return bigInteger;
    }

    if (value instanceof Number number) {
      return BigInteger.valueOf(number.longValue());
    }

    String raw = asString(value).trim();
    if (raw.isEmpty()) {
      return null;
    }

    if (Address.isValid(raw)) {
      return Address.of(raw).toBigInteger();
    }

    if (raw.startsWith("0x") || raw.startsWith("0X")) {
      return new BigInteger(raw.substring(2), 16);
    }

    if (raw.matches("^-?[0-9]+$")) {
      return new BigInteger(raw);
    }

    if (HEX_PATTERN.matcher(raw).matches()) {
      return new BigInteger(raw, 16);
    }

    throw new IllegalArgumentException("Cannot parse BigInteger value: " + raw);
  }

  private Long parseLong(Object value) {
    if (value == null) {
      return 0L;
    }
    if (value instanceof Number number) {
      return number.longValue();
    }
    String raw = asString(value).trim();
    if (raw.isEmpty()) {
      return 0L;
    }
    if (HEX_PATTERN.matcher(raw).matches() && (raw.startsWith("0x") || raw.startsWith("0X"))) {
      return new BigInteger(raw.substring(2), 16).longValue();
    }
    return Long.parseLong(raw);
  }

  private Integer parseInt(Object value) {
    if (value == null) {
      return 0;
    }
    if (value instanceof Number number) {
      return number.intValue();
    }
    String raw = asString(value).trim();
    if (raw.isEmpty()) {
      return 0;
    }
    if (HEX_PATTERN.matcher(raw).matches() && (raw.startsWith("0x") || raw.startsWith("0X"))) {
      return new BigInteger(raw.substring(2), 16).intValue();
    }
    return Integer.parseInt(raw);
  }

  private Boolean parseBoolean(Object value) {
    if (value == null) {
      return false;
    }
    if (value instanceof Boolean booleanValue) {
      return booleanValue;
    }
    return Boolean.parseBoolean(asString(value));
  }

  private String asString(Object value) {
    return Objects.toString(value, "");
  }

  private String formatUnsignedNumber(long value, int bits) {
    if (value >= 0) {
      return String.valueOf(value);
    }
    BigInteger modulus = BigInteger.ONE.shiftLeft(bits);
    return BigInteger.valueOf(value).mod(modulus).toString();
  }

  private Object parseUnsignedNumber(Object value, Class<?> targetType, int bits, String fieldName) {
    BigInteger parsed = parseRawBigInteger(value);
    if (parsed.signum() < 0) {
      parsed = parsed.add(BigInteger.ONE.shiftLeft(bits));
    }

    BigInteger max = BigInteger.ONE.shiftLeft(bits).subtract(BigInteger.ONE);
    if (parsed.signum() < 0 || parsed.compareTo(max) > 0) {
      throw new IllegalArgumentException(
          "Value " + parsed + " is out of range for unsigned " + bits + "-bit field " + fieldName);
    }

    if (targetType.equals(long.class) || targetType.equals(Long.class)) {
      return parsed.longValue();
    }

    if (targetType.equals(int.class) || targetType.equals(Integer.class)) {
      if (parsed.compareTo(BigInteger.valueOf(Integer.MAX_VALUE)) > 0) {
        throw new IllegalArgumentException(
            "Value " + parsed + " is too large for int field " + fieldName + " in ton4j model");
      }
      return parsed.intValue();
    }

    return parsed.longValue();
  }

  private BigInteger parseRawBigInteger(Object value) {
    if (value == null) {
      return BigInteger.ZERO;
    }
    if (value instanceof BigInteger bigInteger) {
      return bigInteger;
    }
    if (value instanceof Number number) {
      return BigInteger.valueOf(number.longValue());
    }

    String raw = asString(value).trim();
    if (raw.isEmpty()) {
      return BigInteger.ZERO;
    }
    if (raw.startsWith("0x") || raw.startsWith("0X")) {
      return new BigInteger(raw.substring(2), 16);
    }
    return new BigInteger(raw);
  }

  private String resolveThrowableMessage(Throwable throwable) {
    Throwable root = throwable;
    if (root instanceof InvocationTargetException invocationTargetException
        && invocationTargetException.getTargetException() != null) {
      root = invocationTargetException.getTargetException();
    }
    while (root.getCause() != null && root.getCause() != root) {
      root = root.getCause();
    }
    String message = root.getMessage();
    if (message == null || message.isBlank()) {
      return root.toString();
    }
    return message;
  }

  private static Map<Integer, Class<?>> createParamClassById() {
    Map<Integer, Class<?>> map = new LinkedHashMap<>();
    map.put(0, ConfigParams0.class);
    map.put(1, ConfigParams1.class);
    map.put(2, ConfigParams2.class);
    map.put(3, ConfigParams3.class);
    map.put(4, ConfigParams4.class);
    map.put(5, ConfigParams5.class);
    map.put(6, ConfigParams6.class);
    map.put(7, ConfigParams7.class);
    map.put(8, ConfigParams8.class);
    map.put(9, ConfigParams9.class);
    map.put(10, ConfigParams10.class);
    map.put(11, ConfigParams11.class);
    map.put(12, ConfigParams12.class);
    map.put(13, ConfigParams13.class);
    map.put(14, ConfigParams14.class);
    map.put(15, ConfigParams15.class);
    map.put(16, ConfigParams16.class);
    map.put(17, ConfigParams17.class);
    map.put(18, ConfigParams18.class);
    map.put(19, ConfigParams19.class);
    map.put(20, ConfigParams20.class);
    map.put(21, ConfigParams21.class);
    map.put(22, ConfigParams22.class);
    map.put(23, ConfigParams23.class);
    map.put(24, ConfigParams24.class);
    map.put(25, ConfigParams25.class);
    map.put(28, ConfigParams28.class);
    map.put(29, ConfigParams29.class);
    map.put(31, ConfigParams31.class);
    map.put(32, ConfigParams32.class);
    map.put(33, ConfigParams33.class);
    map.put(34, ConfigParams34.class);
    map.put(35, ConfigParams35.class);
    map.put(36, ConfigParams36.class);
    map.put(37, ConfigParams37.class);
    map.put(39, ConfigParams39.class);
    map.put(40, ConfigParams40.class);
    map.put(44, ConfigParams44.class);
    map.put(45, ConfigParams45.class);
    map.put(71, ConfigParams71.class);
    map.put(72, ConfigParams72.class);
    map.put(73, ConfigParams73.class);
    map.put(79, ConfigParams79.class);
    map.put(81, ConfigParams81.class);
    map.put(82, ConfigParams82.class);
    return Collections.unmodifiableMap(map);
  }

  private static Map<Integer, String> createParamDescriptions() {
    Map<Integer, String> map = new LinkedHashMap<>();
    map.put(0, "config address");
    map.put(1, "elector address");
    map.put(2, "minter address");
    map.put(3, "fee collector address");
    map.put(4, "dns root address");
    map.put(5, "burning config");
    map.put(6, "mint prices");
    map.put(7, "extra currencies");
    map.put(8, "global version");
    map.put(9, "mandatory params");
    map.put(10, "critical params");
    map.put(11, "config voting setup");
    map.put(12, "workchains");
    map.put(13, "complaint pricing");
    map.put(14, "block creation fees");
    map.put(15, "elections timing");
    map.put(16, "validator counts");
    map.put(17, "stake limits");
    map.put(18, "storage prices");
    map.put(19, "global id");
    map.put(20, "masterchain gas prices");
    map.put(21, "basechain gas prices");
    map.put(22, "masterchain block limits");
    map.put(23, "basechain block limits");
    map.put(24, "masterchain msg forward prices");
    map.put(25, "msg forward prices");
    map.put(28, "catchain config");
    map.put(29, "consensus config");
    map.put(31, "fundamental smc addresses");
    map.put(32, "prev validators");
    map.put(33, "prev temp validators");
    map.put(34, "current validators");
    map.put(35, "current temp validators");
    map.put(36, "next validators");
    map.put(37, "next temp validators");
    map.put(39, "validator signed temp keys");
    map.put(40, "misbehaviour punishment config");
    map.put(44, "suspended address list");
    map.put(45, "precompiled contracts config");
    map.put(71, "ethereum bridge");
    map.put(72, "binance smart chain bridge");
    map.put(73, "polygon bridge");
    map.put(79, "eth ton token bridge");
    map.put(81, "bnb ton token bridge");
    map.put(82, "polygon ton token bridge");
    return Collections.unmodifiableMap(map);
  }

  private static Map<Class<?>, List<Class<?>>> createInterfaceOptions() {
    Map<Class<?>, List<Class<?>>> map = new ConcurrentHashMap<>();
    map.put(ValidatorSet.class, List.of(Validators.class, ValidatorsExt.class));
    map.put(ValidatorDescr.class, List.of(Validator.class, ValidatorAddr.class));
    map.put(WorkchainDescr.class, List.of(WorkchainDescrV1.class, WorkchainDescrV2.class));
    map.put(WorkchainFormat.class, List.of(WorkchainFormatBasic.class, WorkchainFormatExt.class));
    map.put(
        GasLimitsPrices.class,
        List.of(GasLimitsPricesOrdinary.class, GasLimitsPricesExt.class, GasLimitsPricesPfx.class));
    map.put(BlockLimits.class, List.of(BlockLimitsV1.class, BlockLimitsV2.class));
    map.put(CatchainConfig.class, List.of(CatchainConfigC1.class, CatchainConfigC2.class));
    map.put(
        ConsensusConfig.class,
        List.of(
            ConsensusConfigV1.class,
            ConsensusConfigNew.class,
            ConsensusConfigV3.class,
            ConsensusConfigV4.class));
    map.put(JettonBridgeParams.class, List.of(JettonBridgeParamsV1.class, JettonBridgeParamsV2.class));
    return Collections.unmodifiableMap(map);
  }

  private static Map<String, DictSpec> createDictSpecs() {
    Map<String, DictSpec> map = new LinkedHashMap<>();

    map.put(
        ConfigParams7.class.getName() + ".extraCurrencies",
        new DictSpec(32, BigInteger.class, BigIntFormat.DECIMAL, 32, BigInteger.class, BigIntFormat.DECIMAL, false));
    map.put(
        ConfigParams9.class.getName() + ".mandatoryParams",
        new DictSpec(32, BigInteger.class, BigIntFormat.DECIMAL, 0, Void.class, BigIntFormat.DECIMAL, true));
    map.put(
        ConfigParams10.class.getName() + ".criticalParams",
        new DictSpec(32, BigInteger.class, BigIntFormat.DECIMAL, 0, Void.class, BigIntFormat.DECIMAL, true));
    map.put(
        ConfigParams12.class.getName() + ".workchains",
        new DictSpec(32, BigInteger.class, BigIntFormat.DECIMAL, 0, WorkchainDescr.class, BigIntFormat.DECIMAL, false));
    map.put(
        ConfigParams18.class.getName() + ".storagePrices",
        new DictSpec(32, BigInteger.class, BigIntFormat.DECIMAL, 0, StoragePrices.class, BigIntFormat.DECIMAL, false));
    map.put(
        ConfigParams31.class.getName() + ".fundamentalSmcAddr",
        new DictSpec(256, BigInteger.class, BigIntFormat.ADDRESS_OR_HEX, 0, Void.class, BigIntFormat.DECIMAL, true));

    map.put(
        Validators.class.getName() + ".list",
        new DictSpec(16, Long.class, BigIntFormat.DECIMAL, 0, ValidatorDescr.class, BigIntFormat.DECIMAL, false));
    map.put(
        ValidatorsExt.class.getName() + ".list",
        new DictSpec(16, BigInteger.class, BigIntFormat.DECIMAL, 0, ValidatorDescr.class, BigIntFormat.DECIMAL, false));

    map.put(
        ConfigParams39.class.getName() + ".validatorSignedTemp",
        new DictSpec(256, BigInteger.class, BigIntFormat.HEX, 0, ValidatorSignedTempKey.class, BigIntFormat.DECIMAL, false));

    map.put(
        ConfigParams44.class.getName() + ".suspendedAddressList",
        new DictSpec(288, BigInteger.class, BigIntFormat.HEX, 0, Void.class, BigIntFormat.DECIMAL, true));
    map.put(
        ConfigParams45.class.getName() + ".precompiledContractsList",
        new DictSpec(256, BigInteger.class, BigIntFormat.HEX, 0, PrecompiledSmc.class, BigIntFormat.DECIMAL, false));

    map.put(
        OracleBridgeParams.class.getName() + ".oracles",
        new DictSpec(256, BigInteger.class, BigIntFormat.HEX, 256, BigInteger.class, BigIntFormat.HEX, false));
    map.put(
        JettonBridgeParamsV1.class.getName() + ".oracles",
        new DictSpec(256, BigInteger.class, BigIntFormat.HEX, 256, BigInteger.class, BigIntFormat.HEX, false));
    map.put(
        JettonBridgeParamsV2.class.getName() + ".oracles",
        new DictSpec(256, BigInteger.class, BigIntFormat.HEX, 256, BigInteger.class, BigIntFormat.HEX, false));

    return Collections.unmodifiableMap(map);
  }

  private static Map<String, BigIntFormatSpec> createBigIntFormatOverrides() {
    Map<String, BigIntFormatSpec> map = new LinkedHashMap<>();

    // Config smart contract addresses
    map.put(ConfigParams0.class.getName() + ".configAddr", new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(ConfigParams1.class.getName() + ".electorAddr", new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(ConfigParams2.class.getName() + ".minterAddr", new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(ConfigParams3.class.getName() + ".feeCollectorAddr", new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(ConfigParams4.class.getName() + ".dnsRootAddr", new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(ConfigParams5.class.getName() + ".blackholeAddr", new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));

    // Hashes / keys
    map.put(WorkchainDescrV1.class.getName() + ".zeroStateRootHash", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(WorkchainDescrV1.class.getName() + ".zeroStateFileHash", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(WorkchainDescrV2.class.getName() + ".zeroStateRootHash", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(WorkchainDescrV2.class.getName() + ".zeroStateFileHash", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(SigPubKey.class.getName() + ".pubkey", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(ValidatorAddr.class.getName() + ".adnlAddr", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(ValidatorTempKey.class.getName() + ".adnlAddr", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(CryptoSignature.class.getName() + ".r", new BigIntFormatSpec(BigIntFormat.HEX, 256));
    map.put(CryptoSignature.class.getName() + ".s", new BigIntFormatSpec(BigIntFormat.HEX, 256));

    // Bridge params
    map.put(
        OracleBridgeParams.class.getName() + ".bridgeAddress",
        new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(
        OracleBridgeParams.class.getName() + ".oracleMultiSigAddress",
        new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(
        OracleBridgeParams.class.getName() + ".externalChainAddress",
        new BigIntFormatSpec(BigIntFormat.HEX, 256));

    map.put(
        JettonBridgeParamsV1.class.getName() + ".bridgeAddress",
        new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(
        JettonBridgeParamsV1.class.getName() + ".oracleAddress",
        new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(
        JettonBridgeParamsV2.class.getName() + ".bridgeAddress",
        new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(
        JettonBridgeParamsV2.class.getName() + ".oracleAddress",
        new BigIntFormatSpec(BigIntFormat.ADDRESS_OR_HEX, 256));
    map.put(
        JettonBridgeParamsV2.class.getName() + ".externalChainAddress",
        new BigIntFormatSpec(BigIntFormat.HEX, 256));

    return Collections.unmodifiableMap(map);
  }

  private static Map<String, Integer> createUnsignedNumberFieldBits() {
    Map<String, Integer> map = new LinkedHashMap<>();

    map.put(WorkchainDescrV1.class.getName() + ".enabledSince", 32);
    map.put(WorkchainDescrV1.class.getName() + ".version", 32);
    map.put(WorkchainDescrV2.class.getName() + ".enabledSince", 32);
    map.put(WorkchainDescrV2.class.getName() + ".version", 32);
    map.put(WcSplitMergeTimings.class.getName() + ".splitMergeDelay", 32);
    map.put(WcSplitMergeTimings.class.getName() + ".splitMergeInterval", 32);
    map.put(WcSplitMergeTimings.class.getName() + ".minSplitMergeInterval", 32);
    map.put(WcSplitMergeTimings.class.getName() + ".minSplitMergeDelay", 32);

    return Collections.unmodifiableMap(map);
  }

  private enum SchemaKind {
    OBJECT,
    CHOICE,
    DICT,
    BIGINT,
    LONG,
    INT,
    BOOLEAN,
    UNIT
  }

  private enum BigIntFormat {
    DECIMAL,
    HEX,
    ADDRESS_OR_HEX
  }

  private record DictSpec(
      int keyBits,
      Class<?> keyClass,
      BigIntFormat keyFormat,
      int valueBits,
      Class<?> valueClass,
      BigIntFormat valueFormat,
      boolean unitValue) {}

  private record BigIntFormatSpec(BigIntFormat format, int bits) {}

  private static final class FieldSchema {
    private final Field field;
    private final String name;
    private final String label;
    private final boolean optional;
    private final TypeSchema schema;

    private FieldSchema(Field field, String name, String label, boolean optional, TypeSchema schema) {
      this.field = field;
      this.name = name;
      this.label = label;
      this.optional = optional;
      this.schema = schema;
    }

    private Map<String, Object> toPublicMap() {
      Map<String, Object> map = new LinkedHashMap<>();
      map.put("name", name);
      map.put("label", label);
      map.put("optional", optional);
      map.put("schema", schema.toPublicMap());
      return map;
    }
  }

  private static final class TypeSchema {
    private final SchemaKind kind;
    private final Class<?> javaType;
    private final List<FieldSchema> fields;
    private final List<TypeSchema> options;
    private final DictSpec dictSpec;
    private final TypeSchema keySchema;
    private final TypeSchema valueSchema;
    private final BigIntFormat bigIntFormat;
    private final Integer bigIntBits;

    private TypeSchema(
        SchemaKind kind,
        Class<?> javaType,
        List<FieldSchema> fields,
        List<TypeSchema> options,
        DictSpec dictSpec,
        TypeSchema keySchema,
        TypeSchema valueSchema,
        BigIntFormat bigIntFormat,
        Integer bigIntBits) {
      this.kind = kind;
      this.javaType = javaType;
      this.fields = fields;
      this.options = options;
      this.dictSpec = dictSpec;
      this.keySchema = keySchema;
      this.valueSchema = valueSchema;
      this.bigIntFormat = bigIntFormat;
      this.bigIntBits = bigIntBits;
    }

    private static TypeSchema object(Class<?> javaType, List<FieldSchema> fields) {
      return new TypeSchema(
          SchemaKind.OBJECT,
          javaType,
          Collections.unmodifiableList(fields),
          List.of(),
          null,
          null,
          null,
          null,
          null);
    }

    private static TypeSchema choice(Class<?> javaType, List<TypeSchema> options) {
      return new TypeSchema(
          SchemaKind.CHOICE,
          javaType,
          List.of(),
          Collections.unmodifiableList(options),
          null,
          null,
          null,
          null,
          null);
    }

    private static TypeSchema dict(
        Class<?> javaType, DictSpec dictSpec, TypeSchema keySchema, TypeSchema valueSchema) {
      return new TypeSchema(
          SchemaKind.DICT,
          javaType,
          List.of(),
          List.of(),
          dictSpec,
          keySchema,
          valueSchema,
          null,
          null);
    }

    private static TypeSchema bigint(Class<?> javaType, BigIntFormat bigIntFormat, int bits) {
      return new TypeSchema(
          SchemaKind.BIGINT,
          javaType,
          List.of(),
          List.of(),
          null,
          null,
          null,
          bigIntFormat,
          bits > 0 ? bits : null);
    }

    private static TypeSchema longNumber(Class<?> javaType) {
      return new TypeSchema(
          SchemaKind.LONG, javaType, List.of(), List.of(), null, null, null, null, null);
    }

    private static TypeSchema intNumber(Class<?> javaType) {
      return new TypeSchema(
          SchemaKind.INT, javaType, List.of(), List.of(), null, null, null, null, null);
    }

    private static TypeSchema bool(Class<?> javaType) {
      return new TypeSchema(
          SchemaKind.BOOLEAN, javaType, List.of(), List.of(), null, null, null, null, null);
    }

    private static TypeSchema unit() {
      return new TypeSchema(
          SchemaKind.UNIT, Void.class, List.of(), List.of(), null, null, null, null, null);
    }

    private Map<String, Object> toPublicMap() {
      Map<String, Object> map = new LinkedHashMap<>();
      map.put("kind", kind.name().toLowerCase(Locale.ROOT));
      map.put("typeName", javaType.getSimpleName());

      if (kind == SchemaKind.OBJECT) {
        List<Map<String, Object>> fieldMaps = new ArrayList<>();
        for (FieldSchema field : fields) {
          fieldMaps.add(field.toPublicMap());
        }
        map.put("fields", fieldMaps);
      }

      if (kind == SchemaKind.CHOICE) {
        List<Map<String, Object>> optionMaps = new ArrayList<>();
        for (TypeSchema option : options) {
          optionMaps.add(option.toPublicMap());
        }
        map.put("options", optionMaps);
      }

      if (kind == SchemaKind.DICT) {
        map.put("keyBits", dictSpec.keyBits());
        map.put("unitValue", dictSpec.unitValue());
        map.put("key", keySchema.toPublicMap());
        map.put("value", valueSchema.toPublicMap());
      }

      if (kind == SchemaKind.BIGINT && bigIntFormat != null && bigIntFormat != BigIntFormat.DECIMAL) {
        map.put("format", bigIntFormat.name().toLowerCase(Locale.ROOT));
        if (bigIntBits != null) {
          map.put("bits", bigIntBits);
        }
      }

      return map;
    }
  }
}
