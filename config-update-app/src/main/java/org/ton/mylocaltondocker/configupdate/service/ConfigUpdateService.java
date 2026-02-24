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
import org.ton.ton4j.tlb.ConfigProposalSetup;
import org.ton.ton4j.tlb.ConfigVotingSetup;
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
import org.ton.ton4j.tlb.GlobalVersion;
import org.ton.ton4j.tlb.JettonBridgeParams;
import org.ton.ton4j.tlb.JettonBridgeParamsV1;
import org.ton.ton4j.tlb.JettonBridgeParamsV2;
import org.ton.ton4j.tlb.JettonBridgePrices;
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
import org.ton.ton4j.tlb.WcSplitMergeTimings;
import org.ton.ton4j.tlb.WorkchainDescr;
import org.ton.ton4j.tlb.WorkchainDescrV1;
import org.ton.ton4j.tlb.WorkchainDescrV2;
import org.ton.ton4j.tlb.WorkchainFormat;
import org.ton.ton4j.tlb.WorkchainFormatBasic;
import org.ton.ton4j.tlb.WorkchainFormatExt;
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
        new DictSpec(32, BigInteger.class, BigIntFormat.DECIMAL, 32, Byte.class, BigIntFormat.DECIMAL, false));
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

  public long getConfigSeqno() {
    if (Main.adnlLiteClient == null) {
      throw new IllegalStateException("Service is not initialized yet");
    }
    return Main.adnlLiteClient.getSeqno(Main.CONFIG_SMART_CONTRACT_ADDRESS);
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

      Cell paramCell = buildParamCell(id, configParamObject);
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

      if (id == 18) {
        TonHashMap storagePrices =
            CellSlice.beginParse(paramCell)
                .loadDict(
                    32,
                    k -> k.readUint(32),
                    v -> StoragePrices.deserialize(CellSlice.beginParse(v)));
        return ConfigParams18.builder().storagePrices(storagePrices).build();
      }

      if (id == 44) {
        CellSlice slice = CellSlice.beginParse(paramCell);
        int magic = slice.loadUint(8).intValue();
        TonHashMapE suspendedAddressList = slice.loadDictE(288, k -> k.readUint(288), v -> v);
        long suspendedUntil = slice.loadUint(32).longValue();
        return ConfigParams44.builder()
            .magic(magic)
            .suspendedAddressList(suspendedAddressList)
            .suspendedUntil(suspendedUntil)
            .build();
      }

      if (id == 45) {
        CellSlice slice = CellSlice.beginParse(paramCell);
        int magic = slice.loadUint(8).intValue();
        TonHashMapE precompiledContractsList =
            slice.loadDictE(
                256,
                k -> k.readUint(256),
                v -> PrecompiledSmc.deserialize(CellSlice.beginParse(v)));
        return ConfigParams45.builder()
            .magic(magic)
            .precompiledContractsList(precompiledContractsList)
            .build();
      }

      if (id >= 32 && id <= 37) {
        ValidatorSet validatorSet = deserializeValidatorSetFixed(CellSlice.beginParse(paramCell));
        return switch (id) {
          case 32 -> ConfigParams32.builder().prevValidatorSet(validatorSet).build();
          case 33 -> ConfigParams33.builder().prevTempValidatorSet(validatorSet).build();
          case 34 -> ConfigParams34.builder().currValidatorSet(validatorSet).build();
          case 35 -> ConfigParams35.builder().currTempValidatorSet(validatorSet).build();
          case 36 -> ConfigParams36.builder().nextValidatorSet(validatorSet).build();
          case 37 -> ConfigParams37.builder().nextTempValidatorSet(validatorSet).build();
          default -> instantiateClass(paramClass);
        };
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

  private Cell buildParamCell(int paramId, Object value) throws Exception {
    if (paramId == 5 && value instanceof ConfigParams5 configParams5) {
      return buildConfigParam5Cell(configParams5);
    }
    if (paramId == 8 && value instanceof ConfigParams8 configParams8) {
      return buildConfigParam8Cell(configParams8);
    }
    if (paramId == 9 && value instanceof ConfigParams9 configParams9) {
      return buildConfigParam9Cell(configParams9);
    }
    if (paramId == 10 && value instanceof ConfigParams10 configParams10) {
      return buildConfigParam10Cell(configParams10);
    }
    if (paramId == 18 && value instanceof ConfigParams18 configParams18) {
      return buildConfigParam18Cell(configParams18);
    }
    if (paramId == 11 && value instanceof ConfigParams11 configParams11) {
      return buildConfigParam11Cell(configParams11);
    }
    if (paramId == 17 && value instanceof ConfigParams17 configParams17) {
      return buildConfigParam17Cell(configParams17);
    }
    if (paramId == 29 && value instanceof ConfigParams29 configParams29) {
      return buildConfigParam29Cell(configParams29);
    }
    if (paramId == 79 && value instanceof ConfigParams79 configParams79) {
      return buildConfigParam79Cell(configParams79);
    }
    if (paramId == 81 && value instanceof ConfigParams81 configParams81) {
      return buildConfigParam81Cell(configParams81);
    }
    if (paramId == 82 && value instanceof ConfigParams82 configParams82) {
      return buildConfigParam82Cell(configParams82);
    }
    if (paramId == 44 && value instanceof ConfigParams44 configParams44) {
      return buildConfigParam44Cell(configParams44);
    }
    if (paramId == 45 && value instanceof ConfigParams45 configParams45) {
      return buildConfigParam45Cell(configParams45);
    }
    if (paramId >= 32 && paramId <= 37) {
      ValidatorSet validatorSet = extractValidatorSetFromConfigParam(paramId, value);
      if (validatorSet != null) {
        return CellBuilder.beginCell().storeCell(buildValidatorSetCell(validatorSet)).endCell();
      }
    }
    return invokeToCell(value);
  }

  private Cell buildConfigParam5Cell(ConfigParams5 config) {
    long feeBurnDenom = normalizeUnsignedLong(config.getFeeBurnDenom(), 32);
    if (feeBurnDenom < 1) {
      feeBurnDenom = 1;
    }

    long feeBurnNum = normalizeUnsignedLong(config.getFeeBurnNum(), 32);
    if (feeBurnNum > feeBurnDenom) {
      feeBurnNum = feeBurnDenom;
    }

    BigInteger blackholeAddr = config.blackholeAddr;

    CellBuilder cellBuilder = CellBuilder.beginCell().storeUint(0x01, 8);
    if (blackholeAddr == null) {
      cellBuilder.storeBit(false);
    } else {
      cellBuilder.storeBit(true).storeUint(normalizeUnsignedBigInteger(blackholeAddr, 256), 256);
    }

    return cellBuilder.storeUint(feeBurnNum, 32).storeUint(feeBurnDenom, 32).endCell();
  }

  private Cell buildConfigParam8Cell(ConfigParams8 config) {
    GlobalVersion globalVersion = config.getGlobalVersion();
    long version = 0L;
    BigInteger capabilities = BigInteger.ZERO;

    if (globalVersion != null) {
      version = normalizeUnsignedLong(globalVersion.getVersion(), 32);
      capabilities = normalizeUnsignedBigInteger(globalVersion.getCapabilities(), 64);
    }

    return CellBuilder.beginCell()
        .storeUint(0xc4, 8)
        .storeUint(version, 32)
        .storeUint(capabilities, 64)
        .endCell();
  }

  private Cell buildConfigParam9Cell(ConfigParams9 config) {
    TonHashMap mandatoryParams = config.getMandatoryParams();
    if (mandatoryParams == null || mandatoryParams.getElements() == null || mandatoryParams.getElements().isEmpty()) {
      throw new IllegalArgumentException("ConfigParam 9 mandatory params dictionary cannot be empty");
    }

    Cell dict =
        mandatoryParams.serialize(
            k ->
                CellBuilder.beginCell()
                    .storeUint(normalizeUnsignedBigInteger((BigInteger) k, 32), 32)
                    .endCell()
                    .getBits(),
            v -> CellBuilder.beginCell().endCell());

    return CellBuilder.beginCell().storeCell(dict).endCell();
  }

  private Cell buildConfigParam10Cell(ConfigParams10 config) {
    TonHashMap criticalParams = config.getCriticalParams();
    if (criticalParams == null || criticalParams.getElements() == null || criticalParams.getElements().isEmpty()) {
      throw new IllegalArgumentException("ConfigParam 10 critical params dictionary cannot be empty");
    }

    Cell dict =
        criticalParams.serialize(
            k ->
                CellBuilder.beginCell()
                    .storeUint(normalizeUnsignedBigInteger((BigInteger) k, 32), 32)
                    .endCell()
                    .getBits(),
            v -> CellBuilder.beginCell().endCell());

    return CellBuilder.beginCell().storeCell(dict).endCell();
  }

  private Cell buildConfigParam18Cell(ConfigParams18 config) {
    TonHashMap storagePrices = config.getStoragePrices();
    if (storagePrices == null
        || storagePrices.getElements() == null
        || storagePrices.getElements().isEmpty()) {
      throw new IllegalArgumentException("ConfigParam 18 storage prices dictionary cannot be empty");
    }

    Cell dict =
        storagePrices.serialize(
            k ->
                CellBuilder.beginCell()
                    .storeUint(normalizeUnsignedBigInteger((BigInteger) k, 32), 32)
                    .endCell()
                    .getBits(),
            v ->
                CellBuilder.beginCell()
                    .storeCell(buildStoragePricesCell((StoragePrices) v))
                    .endCell());

    return CellBuilder.beginCell().storeCell(dict).endCell();
  }

  private Cell buildStoragePricesCell(StoragePrices storagePrices) {
    if (storagePrices == null) {
      throw new IllegalArgumentException("StoragePrices value cannot be empty");
    }

    return CellBuilder.beginCell()
        .storeUint(0xcc, 8)
        .storeUint(normalizeUnsignedLong(storagePrices.getUtimeSince(), 32), 32)
        .storeUint(normalizeUnsignedBigInteger(storagePrices.getBitPricePs(), 64), 64)
        .storeUint(normalizeUnsignedBigInteger(storagePrices.getCellPricePs(), 64), 64)
        .storeUint(normalizeUnsignedBigInteger(storagePrices.getMcBitPricePs(), 64), 64)
        .storeUint(normalizeUnsignedBigInteger(storagePrices.getMcCellPricePs(), 64), 64)
        .endCell();
  }

  private Cell buildConfigParam11Cell(ConfigParams11 config) {
    ConfigVotingSetup votingSetup = config.getConfigVotingSetup();
    if (votingSetup == null) {
      throw new IllegalArgumentException("ConfigParam 11 voting setup cannot be empty");
    }

    Cell normalParamsCell = buildConfigProposalSetupCell(votingSetup.getNormalParams());
    Cell criticalParamsCell = buildConfigProposalSetupCell(votingSetup.getCriticalParams());

    return CellBuilder.beginCell()
        .storeUint(0x91, 8)
        .storeRef(normalParamsCell)
        .storeRef(criticalParamsCell)
        .endCell();
  }

  private Cell buildConfigProposalSetupCell(ConfigProposalSetup setup) {
    if (setup == null) {
      throw new IllegalArgumentException("Config proposal setup cannot be empty");
    }

    return CellBuilder.beginCell()
        .storeUint(0x36, 8)
        .storeUint(normalizeUnsignedLong(setup.getMinTotRounds(), 8), 8)
        .storeUint(normalizeUnsignedLong(setup.getMaxTotRounds(), 8), 8)
        .storeUint(normalizeUnsignedLong(setup.getMinWins(), 8), 8)
        .storeUint(normalizeUnsignedLong(setup.getMaxLosses(), 8), 8)
        .storeUint(normalizeUnsignedLong(setup.getMinStoreSec(), 32), 32)
        .storeUint(normalizeUnsignedLong(setup.getMaxStoreSec(), 32), 32)
        .storeUint(normalizeUnsignedLong(setup.getBitPrice(), 32), 32)
        .storeUint(normalizeUnsignedLong(setup.getCellPrice(), 32), 32)
        .endCell();
  }

  private Cell buildConfigParam17Cell(ConfigParams17 config) {
    return CellBuilder.beginCell()
        .storeCoins(sanitizeCoins(config.getMinStake()))
        .storeCoins(sanitizeCoins(config.getMaxStake()))
        .storeCoins(sanitizeCoins(config.getMinTotalStake()))
        .storeUint(normalizeUnsignedLong(config.getMaxStakeFactor(), 32), 32)
        .endCell();
  }

  private BigInteger sanitizeCoins(BigInteger value) {
    if (value == null || value.signum() < 0) {
      return BigInteger.ZERO;
    }
    return value;
  }

  private Cell buildConfigParam29Cell(ConfigParams29 config) throws Exception {
    ConsensusConfig consensusConfig = config.getConsensusConfig();
    if (consensusConfig == null) {
      throw new IllegalArgumentException("ConfigParam 29 consensus config cannot be empty");
    }
    Cell consensusCell = buildConsensusConfigCell(consensusConfig);
    return CellBuilder.beginCell().storeCell(consensusCell).endCell();
  }

  private Cell buildConsensusConfigCell(ConsensusConfig consensusConfig) throws Exception {
    if (consensusConfig instanceof ConsensusConfigV1 cfg) {
      long roundCandidates = Math.max(1L, normalizeUnsignedLong(cfg.getRoundCandidates(), 32));
      return CellBuilder.beginCell()
          .storeUint(0xd6, 8)
          .storeUint(roundCandidates, 32)
          .storeUint(normalizeUnsignedLong(cfg.getNextCandidateDelayMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getConsensusTimeoutMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getFastAttempts(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getAttemptDuration(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getCatchainNaxDeps(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxBlockBytes(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxCollatedBytes(), 32), 32)
          .endCell();
    }

    if (consensusConfig instanceof ConsensusConfigNew cfg) {
      long roundCandidates = Math.max(1L, normalizeUnsignedLong(cfg.getRoundCandidates(), 8));
      return CellBuilder.beginCell()
          .storeUint(0xd7, 8)
          .storeUint(0, 7)
          .storeBit(cfg.isNewCatchainIds())
          .storeUint(roundCandidates, 8)
          .storeUint(normalizeUnsignedLong(cfg.getNextCandidateDelayMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getConsensusTimeoutMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getFastAttempts(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getAttemptDuration(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getCatchainNaxDeps(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxBlockBytes(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxCollatedBytes(), 32), 32)
          .endCell();
    }

    if (consensusConfig instanceof ConsensusConfigV3 cfg) {
      long roundCandidates = Math.max(1L, normalizeUnsignedLong(cfg.getRoundCandidates(), 8));
      return CellBuilder.beginCell()
          .storeUint(0xd8, 8)
          .storeUint(0, 7)
          .storeBit(cfg.isNewCatchainIds())
          .storeUint(roundCandidates, 8)
          .storeUint(normalizeUnsignedLong(cfg.getNextCandidateDelayMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getConsensusTimeoutMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getFastAttempts(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getAttemptDuration(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getCatchainNaxDeps(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxBlockBytes(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxCollatedBytes(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getProtoVersion(), 16), 16)
          .endCell();
    }

    if (consensusConfig instanceof ConsensusConfigV4 cfg) {
      long roundCandidates = Math.max(1L, normalizeUnsignedLong(cfg.getRoundCandidates(), 8));
      return CellBuilder.beginCell()
          .storeUint(0xd9, 8)
          .storeUint(0, 7)
          .storeBit(cfg.isNewCatchainIds())
          .storeUint(roundCandidates, 8)
          .storeUint(normalizeUnsignedLong(cfg.getNextCandidateDelayMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getConsensusTimeoutMs(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getFastAttempts(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getAttemptDuration(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getCatchainNaxDeps(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxBlockBytes(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getMaxCollatedBytes(), 32), 32)
          .storeUint(normalizeUnsignedLong(cfg.getProtoVersion(), 16), 16)
          .storeUint(normalizeUnsignedLong(cfg.getCatchainMaxBlocksCoeff(), 32), 32)
          .endCell();
    }

    return invokeToCell(consensusConfig);
  }

  private ValidatorSet extractValidatorSetFromConfigParam(int paramId, Object value) {
    return switch (paramId) {
      case 32 -> value instanceof ConfigParams32 p ? p.getPrevValidatorSet() : null;
      case 33 -> value instanceof ConfigParams33 p ? p.getPrevTempValidatorSet() : null;
      case 34 -> value instanceof ConfigParams34 p ? p.getCurrValidatorSet() : null;
      case 35 -> value instanceof ConfigParams35 p ? p.getCurrTempValidatorSet() : null;
      case 36 -> value instanceof ConfigParams36 p ? p.getNextValidatorSet() : null;
      case 37 -> value instanceof ConfigParams37 p ? p.getNextTempValidatorSet() : null;
      default -> null;
    };
  }

  private ValidatorSet deserializeValidatorSetFixed(CellSlice cs) {
    int magic = cs.preloadUint(8).intValue();
    if (magic == 0x11) {
      return Validators.builder()
          .magic(cs.loadUint(8).intValue())
          .uTimeSince(cs.loadUint(32).longValue())
          .uTimeUntil(cs.loadUint(32).longValue())
          .total(cs.loadUint(16).intValue())
          .main(cs.loadUint(16).intValue())
          .list(
              cs.loadDict(
                  16,
                  k -> k.readUint(16).longValue(),
                  v -> deserializeValidatorDescrFixed(CellSlice.beginParse(v))))
          .build();
    }
    if (magic == 0x12) {
      return ValidatorsExt.builder()
          .magic(cs.loadUint(8).longValue())
          .uTimeSince(cs.loadUint(32).longValue())
          .uTimeUntil(cs.loadUint(32).longValue())
          .total(cs.loadUint(16).intValue())
          .main(cs.loadUint(16).intValue())
          .totalWeight(cs.loadUint(64))
          .list(
              cs.loadDictE(
                  16,
                  k -> k.readUint(16),
                  v -> deserializeValidatorDescrFixed(CellSlice.beginParse(v))))
          .build();
    }
    throw new IllegalArgumentException("Unsupported ValidatorSet magic: " + magic);
  }

  private ValidatorDescr deserializeValidatorDescrFixed(CellSlice cs) {
    int magic = cs.preloadUint(8).intValue();
    if (magic == 0x53) {
      return Validator.builder()
          .magic(cs.loadUint(8).longValue())
          .publicKey(deserializeSigPubKeyFixed(cs))
          .weight(cs.loadUint(64))
          .build();
    }
    if (magic == 0x73) {
      return ValidatorAddr.builder()
          .magic(cs.loadUint(8).intValue())
          .publicKey(deserializeSigPubKeyFixed(cs))
          .weight(cs.loadUint(64))
          .adnlAddr(cs.loadUint(256))
          .build();
    }
    throw new IllegalArgumentException("Unsupported ValidatorDescr magic: " + magic);
  }

  private SigPubKey deserializeSigPubKeyFixed(CellSlice cs) {
    return SigPubKey.builder()
        .magic(cs.loadUint(32).longValue())
        .pubkey(cs.loadUint(256))
        .build();
  }

  private Cell buildValidatorSetCell(ValidatorSet validatorSet) throws Exception {
    if (validatorSet instanceof Validators validators) {
      TonHashMap list = validators.getList();
      if (list == null) {
        throw new IllegalArgumentException("Validator list cannot be empty");
      }

      Cell dict =
          list.serialize(
              k ->
                  CellBuilder.beginCell()
                      .storeUint(normalizeUnsignedLong(asLongKey(k), 16), 16)
                      .endCell()
                      .getBits(),
              v ->
                  CellBuilder.beginCell()
                      .storeCell(buildValidatorDescrCellUnchecked((ValidatorDescr) v))
                      .endCell());

      long total = normalizeUnsignedLong(validators.getTotal(), 16);
      long main = normalizeUnsignedLong(validators.getMain(), 16);
      if (main < 1) {
        main = 1;
      }
      if (main > total) {
        total = main;
      }

      return CellBuilder.beginCell()
          .storeUint(0x11, 8)
          .storeUint(normalizeUnsignedLong(validators.getUTimeSince(), 32), 32)
          .storeUint(normalizeUnsignedLong(validators.getUTimeUntil(), 32), 32)
          .storeUint(total, 16)
          .storeUint(main, 16)
          .storeDict(dict)
          .endCell();
    }

    if (validatorSet instanceof ValidatorsExt validatorsExt) {
      TonHashMapE list = validatorsExt.getList();
      if (list == null) {
        list = new TonHashMapE(16);
      }

      Cell dict =
          list.serialize(
              k ->
                  CellBuilder.beginCell()
                      .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(k), 16), 16)
                      .endCell()
                      .getBits(),
              v ->
                  CellBuilder.beginCell()
                      .storeCell(buildValidatorDescrCellUnchecked((ValidatorDescr) v))
                      .endCell());

      long total = normalizeUnsignedLong(validatorsExt.getTotal(), 16);
      long main = normalizeUnsignedLong(validatorsExt.getMain(), 16);
      if (main < 1) {
        main = 1;
      }
      if (main > total) {
        total = main;
      }

      return CellBuilder.beginCell()
          .storeUint(0x12, 8)
          .storeUint(normalizeUnsignedLong(validatorsExt.getUTimeSince(), 32), 32)
          .storeUint(normalizeUnsignedLong(validatorsExt.getUTimeUntil(), 32), 32)
          .storeUint(total, 16)
          .storeUint(main, 16)
          .storeUint(normalizeUnsignedBigInteger(validatorsExt.getTotalWeight(), 64), 64)
          .storeDict(dict)
          .endCell();
    }

    return invokeToCell(validatorSet);
  }

  private Cell buildValidatorDescrCell(ValidatorDescr validatorDescr) throws Exception {
    if (validatorDescr instanceof Validator validator) {
      return CellBuilder.beginCell()
          .storeUint(0x53, 8)
          .storeCell(buildSigPubKeyCell(validator.getPublicKey()))
          .storeUint(normalizeUnsignedBigInteger(validator.getWeight(), 64), 64)
          .endCell();
    }

    if (validatorDescr instanceof ValidatorAddr validatorAddr) {
      return CellBuilder.beginCell()
          .storeUint(0x73, 8)
          .storeCell(buildSigPubKeyCell(validatorAddr.getPublicKey()))
          .storeUint(normalizeUnsignedBigInteger(validatorAddr.getWeight(), 64), 64)
          .storeUint(normalizeUnsignedBigInteger(validatorAddr.getAdnlAddr(), 256), 256)
          .endCell();
    }

    return invokeToCell(validatorDescr);
  }

  private Cell buildValidatorDescrCellUnchecked(ValidatorDescr validatorDescr) {
    try {
      return buildValidatorDescrCell(validatorDescr);
    } catch (Exception e) {
      throw new IllegalStateException("Cannot serialize validator descriptor", e);
    }
  }

  private Cell buildSigPubKeyCell(SigPubKey sigPubKey) {
    if (sigPubKey == null) {
      throw new IllegalArgumentException("Validator public key cannot be empty");
    }
    return CellBuilder.beginCell()
        .storeUint(0x8e81278aL, 32)
        .storeUint(normalizeUnsignedBigInteger(sigPubKey.getPubkey(), 256), 256)
        .endCell();
  }

  private long asLongKey(Object key) {
    if (key instanceof Long l) {
      return l;
    }
    if (key instanceof Integer i) {
      return i.longValue();
    }
    if (key instanceof BigInteger bi) {
      return bi.longValue();
    }
    return Long.parseLong(String.valueOf(key));
  }

  private BigInteger asBigIntegerKey(Object key) {
    if (key instanceof BigInteger bi) {
      return bi;
    }
    if (key instanceof Number number) {
      return BigInteger.valueOf(number.longValue());
    }
    return new BigInteger(String.valueOf(key));
  }

  private Cell buildConfigParam44Cell(ConfigParams44 config) {
    TonHashMapE suspendedAddressList = config.getSuspendedAddressList();
    if (suspendedAddressList == null) {
      suspendedAddressList = new TonHashMapE(288);
    }

    Cell dict =
        suspendedAddressList.serialize(
            k ->
                CellBuilder.beginCell()
                    .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(k), 288), 288)
                    .endCell()
                    .getBits(),
            v -> CellBuilder.beginCell().endCell());

    return CellBuilder.beginCell()
        .storeUint(0x00, 8)
        .storeDict(dict)
        .storeUint(normalizeUnsignedLong(config.getSuspendedUntil(), 32), 32)
        .endCell();
  }

  private Cell buildConfigParam45Cell(ConfigParams45 config) {
    TonHashMapE precompiledContractsList = config.getPrecompiledContractsList();
    if (precompiledContractsList == null) {
      precompiledContractsList = new TonHashMapE(256);
    }

    Cell dict =
        precompiledContractsList.serialize(
            k ->
                CellBuilder.beginCell()
                    .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(k), 256), 256)
                    .endCell()
                    .getBits(),
            v ->
                CellBuilder.beginCell()
                    .storeCell(buildPrecompiledSmcCell((PrecompiledSmc) v))
                    .endCell());

    return CellBuilder.beginCell()
        .storeUint(0xc0, 8)
        .storeDict(dict)
        .endCell();
  }

  private Cell buildPrecompiledSmcCell(PrecompiledSmc precompiledSmc) {
    if (precompiledSmc == null) {
      return CellBuilder.beginCell().storeUint(0xb0, 8).storeUint(BigInteger.ZERO, 64).endCell();
    }
    return CellBuilder.beginCell()
        .storeUint(0xb0, 8)
        .storeUint(normalizeUnsignedBigInteger(precompiledSmc.getGasUsage(), 64), 64)
        .endCell();
  }

  private Cell buildConfigParam79Cell(ConfigParams79 config) throws Exception {
    JettonBridgeParams bridge = config.getEthTonTokenBridge();
    if (bridge == null) {
      throw new IllegalArgumentException("ConfigParam 79 bridge params cannot be empty");
    }
    return CellBuilder.beginCell().storeCell(buildJettonBridgeParamsCell(bridge)).endCell();
  }

  private Cell buildConfigParam81Cell(ConfigParams81 config) throws Exception {
    JettonBridgeParams bridge = config.getBnbTonTokenBridge();
    if (bridge == null) {
      throw new IllegalArgumentException("ConfigParam 81 bridge params cannot be empty");
    }
    return CellBuilder.beginCell().storeCell(buildJettonBridgeParamsCell(bridge)).endCell();
  }

  private Cell buildConfigParam82Cell(ConfigParams82 config) throws Exception {
    JettonBridgeParams bridge = config.getPolygonTonTokenBridge();
    if (bridge == null) {
      throw new IllegalArgumentException("ConfigParam 82 bridge params cannot be empty");
    }
    return CellBuilder.beginCell().storeCell(buildJettonBridgeParamsCell(bridge)).endCell();
  }

  private Cell buildJettonBridgeParamsCell(JettonBridgeParams params) throws Exception {
    if (params instanceof JettonBridgeParamsV2 v2) {
      TonHashMapE oracles = v2.getOracles();
      if (oracles == null) {
        oracles = new TonHashMapE(256);
      }

      Cell dict =
          oracles.serialize(
              k ->
                  CellBuilder.beginCell()
                      .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(k), 256), 256)
                      .endCell()
                      .getBits(),
              v ->
                  CellBuilder.beginCell()
                      .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(v), 256), 256)
                      .endCell());

      return CellBuilder.beginCell()
          .storeUint(0x01, 8)
          .storeUint(normalizeUnsignedBigInteger(v2.getBridgeAddress(), 256), 256)
          .storeUint(normalizeUnsignedBigInteger(v2.getOracleAddress(), 256), 256)
          .storeDict(dict)
          .storeUint(normalizeUnsignedLong(v2.getStateFlags(), 8), 8)
          .storeRef(buildJettonBridgePricesCell(v2.getPrices()))
          .storeUint(normalizeUnsignedBigInteger(v2.getExternalChainAddress(), 256), 256)
          .endCell();
    }

    if (params instanceof JettonBridgeParamsV1 v1) {
      TonHashMapE oracles = v1.getOracles();
      if (oracles == null) {
        oracles = new TonHashMapE(256);
      }

      Cell dict =
          oracles.serialize(
              k ->
                  CellBuilder.beginCell()
                      .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(k), 256), 256)
                      .endCell()
                      .getBits(),
              v ->
                  CellBuilder.beginCell()
                      .storeUint(normalizeUnsignedBigInteger(asBigIntegerKey(v), 256), 256)
                      .endCell());

      return CellBuilder.beginCell()
          .storeUint(0x00, 8)
          .storeUint(normalizeUnsignedBigInteger(v1.getBridgeAddress(), 256), 256)
          .storeUint(normalizeUnsignedBigInteger(v1.getOracleAddress(), 256), 256)
          .storeDict(dict)
          .storeUint(normalizeUnsignedLong(v1.getStateFlags(), 8), 8)
          .storeCoins(sanitizeCoins(v1.getBurnBridgeFee()))
          .endCell();
    }

    return invokeToCell(params);
  }

  private Cell buildJettonBridgePricesCell(JettonBridgePrices prices) {
    JettonBridgePrices resolved =
        prices == null
            ? JettonBridgePrices.builder()
                .bridgeBurnFee(BigInteger.ZERO)
                .bridgeMintFee(BigInteger.ZERO)
                .walletMinTonsForStorage(BigInteger.ZERO)
                .walletGasConsumption(BigInteger.ZERO)
                .minterMinTonsForStorage(BigInteger.ZERO)
                .discoverGasConsumption(BigInteger.ZERO)
                .build()
            : prices;

    return CellBuilder.beginCell()
        .storeCoins(sanitizeCoins(resolved.getBridgeBurnFee()))
        .storeCoins(sanitizeCoins(resolved.getBridgeMintFee()))
        .storeCoins(sanitizeCoins(resolved.getWalletMinTonsForStorage()))
        .storeCoins(sanitizeCoins(resolved.getWalletGasConsumption()))
        .storeCoins(sanitizeCoins(resolved.getMinterMinTonsForStorage()))
        .storeCoins(sanitizeCoins(resolved.getDiscoverGasConsumption()))
        .endCell();
  }

  private long normalizeUnsignedLong(long value, int bits) {
    return normalizeUnsignedBigInteger(BigInteger.valueOf(value), bits).longValue();
  }

  private BigInteger normalizeUnsignedBigInteger(BigInteger value, int bits) {
    if (bits <= 0) {
      return value == null ? BigInteger.ZERO : value;
    }
    BigInteger modulus = BigInteger.ONE.shiftLeft(bits);
    BigInteger normalized = value == null ? BigInteger.ZERO : value.mod(modulus);
    if (normalized.signum() < 0) {
      normalized = normalized.add(modulus);
    }
    return normalized;
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
    if (javaType.equals(byte.class) || javaType.equals(Byte.class)) {
      return TypeSchema.intNumber(javaType);
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
        if (schema.javaType.equals(byte.class) || schema.javaType.equals(Byte.class)) {
          return parseByte(uiValue);
        }
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

  private Byte parseByte(Object value) {
    if (value == null) {
      return 0;
    }
    if (value instanceof Number number) {
      return (byte) number.intValue();
    }
    String raw = asString(value).trim();
    if (raw.isEmpty()) {
      return 0;
    }
    if (HEX_PATTERN.matcher(raw).matches() && (raw.startsWith("0x") || raw.startsWith("0X"))) {
      return (byte) new BigInteger(raw.substring(2), 16).intValue();
    }
    return (byte) Integer.parseInt(raw);
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
