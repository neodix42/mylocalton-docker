#!/usr/bin/env python3
"""Owned IPv4 rules for a RAM Docker daemon with Docker firewalling disabled.

The caller saves plan() in its ownership receipt before install(), and passes a
persist callback to record each created chain. No command changes Docker's own
chains, a global policy, or host sysctls. Published ports use docker-proxy.
"""
import ipaddress
import re
import shlex
import subprocess


class FirewallError(RuntimeError):
    pass


def plan(compose_subnet, bridge_subnet, token):
    if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{12,64}", token):
        raise FirewallError("firewall ownership token must contain 12–64 lowercase hex digits")
    networks = []
    for bridge, value in (("tonram0", bridge_subnet), ("tonram1", compose_subnet)):
        try:
            network = ipaddress.IPv4Network(value, strict=True)
        except (ValueError, TypeError) as error:
            raise FirewallError("firewall requires canonical IPv4 subnets") from error
        private = any(network.subnet_of(ipaddress.IPv4Network(block))
                      for block in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
        if not private or network.prefixlen > 30 or (bridge == "tonram1" and network.prefixlen != 24):
            raise FirewallError("firewall requires RFC1918 RAM networks; Compose must be /24 and bridge at most /30")
        networks.append({"bridge": bridge, "subnet": str(network)})
    if ipaddress.IPv4Network(networks[0]["subnet"]).overlaps(ipaddress.IPv4Network(networks[1]["subnet"])):
        raise FirewallError("RAM bridge and Compose subnets must not overlap")
    forward = "TONRAM_F_" + token[:16]
    nat = "TONRAM_N_" + token[:16]
    comment = ["-m", "comment", "--comment", "mylocalton-ram:" + token]
    chains = [{"table": "filter", "name": forward}, {"table": "nat", "name": nat}]
    rules, jumps = [], []
    for network in networks:
        bridge, subnet = network["bridge"], network["subnet"]
        # New flows may originate on RAM bridges; only established replies may
        # enter them through FORWARD. Host docker-proxy traffic uses OUTPUT.
        for match in (["-i", bridge, "-s", subnet],
                      ["-o", bridge, "-d", subnet, "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED"]):
            rules.append({"table": "filter", "chain": forward,
                          "args": match + comment + ["-j", "ACCEPT"]})
            jumps.append({"table": "filter", "chain": "FORWARD",
                          "args": match + comment + ["-j", forward]})
        match = ["-s", subnet, "!", "-o", bridge]
        rules.append({"table": "nat", "chain": nat,
                      "args": match + comment + ["-j", "MASQUERADE"]})
        jumps.append({"table": "nat", "chain": "POSTROUTING",
                      "args": match + comment + ["-j", nat]})
    return {"schema": "native-physical-ram-firewall-v1", "token": token,
            "networks": networks, "chains": chains, "rules": rules, "jumps": jumps,
            "created_chains": []}


def validate(receipt):
    try:
        expected = plan(receipt["networks"][1]["subnet"], receipt["networks"][0]["subnet"], receipt["token"])
        created = receipt["created_chains"]
        expected["created_chains"] = created
        if receipt != expected or not isinstance(created, list) or any(c not in expected["chains"] for c in created):
            raise FirewallError("firewall receipt differs from its exact owned rule plan")
        if len({(c["table"], c["name"]) for c in created}) != len(created):
            raise FirewallError("duplicate chain ownership in firewall receipt")
    except (KeyError, TypeError, IndexError) as error:
        raise FirewallError("invalid firewall ownership receipt") from error


def _runner(argv):
    return subprocess.run(argv, check=False, text=True, capture_output=True, timeout=30)


def _command(run, table, *args, optional=False):
    result = run(["iptables", "-w", "10", "-t", table, *args])
    # iptables uses 1 for an absent rule/chain. Permission, argument, resource,
    # and backend errors must not be mistaken for successful cleanup.
    if result.returncode and not (optional and result.returncode == 1):
        raise FirewallError("iptables " + " ".join(args[:2]) + ": " +
                            (result.stderr or result.stdout or str(result.returncode)).strip())
    return result


def _chain_rules(run, chain):
    result = _command(run, chain["table"], "-S", chain["name"], optional=True)
    if result.returncode:
        return None
    rules = []
    for line in result.stdout.splitlines():
        row = shlex.split(line)
        if row == ["-N", chain["name"]]:
            continue
        if len(row) < 2 or row[:2] != ["-A", chain["name"]]:
            raise FirewallError("unexpected rule while checking owned firewall chain")
        rules.append(row[2:])
    return rules


def _canonical(args):
    # -S groups built-in matches before extensions, regardless of input order.
    # Retain negation and multiplicity; unknown or duplicated matches cannot
    # compare equal to the small exact grammar generated by plan().
    groups, index = [], 0
    options = {"-i", "-o", "-s", "-d", "-m", "--ctstate", "--comment", "-j"}
    while index < len(args):
        negate = args[index] == "!"
        if negate:
            index += 1
        if index + 1 >= len(args) or args[index] not in options:
            raise FirewallError("unexpected option in owned firewall chain")
        option, value = args[index:index + 2]
        if option == "--ctstate":
            value = ",".join(sorted(value.split(",")))
        groups.append((option, value, negate))
        index += 2
    return tuple(sorted(groups))


def install(receipt, run=None, persist=None):
    """Install a fresh plan; a partial failure remains removable from receipt."""
    validate(receipt)
    if receipt["created_chains"]:
        raise FirewallError("firewall install requires a fresh ownership plan")
    run, persist = run or _runner, persist or (lambda: None)
    # Detect both collisions before creating either chain. Never adopt them.
    for chain in receipt["chains"]:
        if _chain_rules(run, chain) is not None:
            raise FirewallError("planned firewall chain already exists; refusing to adopt it")
    for chain in receipt["chains"]:
        _command(run, chain["table"], "-N", chain["name"])
        receipt["created_chains"].append(dict(chain))
        persist()
    for rule in receipt["rules"]:
        _command(run, rule["table"], "-A", rule["chain"], *rule["args"])
    # Put narrowly matched jumps before an existing Docker DROP policy/rules.
    # Their order is immaterial: each matches only a RAM bridge/subnet pair.
    for rule in receipt["jumps"]:
        _command(run, rule["table"], "-I", rule["chain"], "1", *rule["args"])


def remove(receipt, run=None, persist=None):
    """Remove exact owned rules; refuse altered chains, and tolerate absence."""
    validate(receipt)
    run, persist = run or _runner, persist or (lambda: None)
    created = list(receipt["created_chains"])
    existing = {}
    # Validate every owned chain before changing any rule. A foreign rule or
    # duplicate means ownership changed: preserve all remaining state.
    for chain in created:
        actual = _chain_rules(run, chain)
        existing[(chain["table"], chain["name"])] = actual
        allowed = [_canonical(r["args"]) for r in receipt["rules"]
                   if r["table"] == chain["table"] and r["chain"] == chain["name"]]
        if actual is not None:
            normalized = [_canonical(a) for a in actual]
            if any(a not in allowed for a in normalized) or len({tuple(a) for a in normalized}) != len(normalized):
                raise FirewallError("owned firewall chain contains unexpected rules; nothing removed")
    owned = set(existing)
    for rule in reversed(receipt["jumps"]):
        if (rule["table"], rule["args"][-1]) not in owned:
            continue
        if _command(run, rule["table"], "-C", rule["chain"], *rule["args"], optional=True).returncode == 0:
            _command(run, rule["table"], "-D", rule["chain"], *rule["args"])
    for chain in reversed(created):
        if existing[(chain["table"], chain["name"])] is not None:
            for rule in reversed(receipt["rules"]):
                if rule["table"] == chain["table"] and rule["chain"] == chain["name"]:
                    if _command(run, rule["table"], "-C", rule["chain"], *rule["args"], optional=True).returncode == 0:
                        _command(run, rule["table"], "-D", rule["chain"], *rule["args"])
            # -X only succeeds for an empty, unreferenced chain. Do not flush.
            _command(run, chain["table"], "-X", chain["name"])
        receipt["created_chains"].remove(chain)
        persist()
