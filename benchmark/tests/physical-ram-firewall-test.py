#!/usr/bin/env python3
"""Offline firewall lifecycle tests; no host firewall commands are executed."""
import copy
import importlib.util
from pathlib import Path
import shlex
import subprocess
import unittest

SPEC = importlib.util.spec_from_file_location("ram_firewall", Path(__file__).resolve().parents[1] / "physical-ram-firewall.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FirewallFixture:
    def __init__(self):
        self.chains = {("filter", "FORWARD"): [["-j", "DOCKER-USER"], ["-j", "DOCKER-FORWARD"]],
                       ("filter", "DOCKER-USER"): [["-j", "RETURN"]],
                       ("filter", "DOCKER-FORWARD"): [["-i", "br-production", "-j", "ACCEPT"]],
                       ("nat", "POSTROUTING"): [["-s", "172.28.1.0/24", "-j", "MASQUERADE"]],
                       ("nat", "DOCKER"): [["-p", "tcp", "--dport", "443", "-j", "DNAT", "--to", "172.28.1.10"]]}
        self.original = copy.deepcopy(self.chains)
        self.commands = []
        self.fail_when = lambda argv: False

    def __call__(self, argv):
        self.commands.append(argv)
        if self.fail_when(argv):
            return subprocess.CompletedProcess(argv, 4, "", "fixture resource failure")
        assert argv[:3] == ["iptables", "-w", "10"]
        assert argv[3] == "-t"
        table, action, name, *args = argv[4:]
        key = table, name
        exists = key in self.chains
        rc, stdout = 0, ""
        if action == "-S":
            if exists:
                stdout = "-N " + name + "\n" + "\n".join(shlex.join(["-A", name, *r]) for r in self.chains[key])
            else:
                rc = 1
        elif action == "-N":
            if exists:
                rc = 1
            else:
                self.chains[key] = []
        elif action in ("-A", "-I"):
            assert exists
            if action == "-I":
                assert args.pop(0) == "1"
                self.chains[key].insert(0, args)
            else:
                self.chains[key].append(args)
        elif action == "-C":
            rc = 0 if exists and args in self.chains[key] else 1
        elif action == "-D":
            if exists and args in self.chains[key]:
                self.chains[key].remove(args)
            else:
                rc = 1
        elif action == "-X":
            if exists and not self.chains[key] and not any(["-j", name] == row[-2:] for rows in self.chains.values() for row in rows):
                del self.chains[key]
            else:
                rc = 1
        else:
            raise AssertionError("Forbidden/unimplemented mutation: " + action)
        return subprocess.CompletedProcess(argv, rc, stdout, "" if rc == 0 else "absent or referenced")


class FirewallTests(unittest.TestCase):
    def setUp(self):
        self.plan = MODULE.plan("10.203.1.0/24", "10.203.2.0/24", "a" * 32)
        self.fixture = FirewallFixture()
        self.saved = []

    def install(self):
        MODULE.install(self.plan, self.fixture, lambda: self.saved.append(copy.deepcopy(self.plan)))

    def test_lifecycle_preserves_original_daemon_rules(self):
        self.install()
        self.assertEqual(len(self.saved), 2)
        for key, rows in self.fixture.original.items():
            for row in rows:
                self.assertIn(row, self.fixture.chains[key])
        MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, self.fixture.original)
        self.assertEqual(self.plan["created_chains"], [])
        MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, self.fixture.original)

    def test_all_jumps_restrict_ram_network_and_interface(self):
        for rule in self.plan["jumps"]:
            args = rule["args"]
            self.assertTrue(any(n["subnet"] in args for n in self.plan["networks"]))
            self.assertTrue(any(n["bridge"] in args for n in self.plan["networks"]))
            self.assertIn("--comment", args)
        inbound = [r for r in self.plan["rules"] if r["table"] == "filter" and "-o" in r["args"]]
        self.assertEqual(len(inbound), 2)
        self.assertTrue(all("RELATED,ESTABLISHED" in r["args"] for r in inbound))

    def test_partial_install_failure_is_removable(self):
        self.fixture.fail_when = lambda argv: "-I" in argv and "POSTROUTING" in argv
        with self.assertRaisesRegex(MODULE.FirewallError, "resource failure"):
            self.install()
        self.fixture.fail_when = lambda argv: False
        MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, self.fixture.original)

    def test_second_chain_creation_failure_records_first_chain(self):
        self.fixture.fail_when = lambda argv: "-N" in argv and "nat" in argv
        with self.assertRaises(MODULE.FirewallError):
            self.install()
        self.assertEqual(len(self.plan["created_chains"]), 1)
        self.assertEqual(len(self.saved), 1)
        self.fixture.fail_when = lambda argv: False
        MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, self.fixture.original)

    def test_existing_chain_collision_is_never_adopted(self):
        chain = self.plan["chains"][1]
        self.fixture.chains[chain["table"], chain["name"]] = []
        before = copy.deepcopy(self.fixture.chains)
        with self.assertRaisesRegex(MODULE.FirewallError, "already exists"):
            self.install()
        MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, before)
        self.assertFalse(self.plan["created_chains"])

    def test_changed_chain_prevents_all_cleanup(self):
        self.install()
        chain = self.plan["chains"][1]
        self.fixture.chains[chain["table"], chain["name"]].append(["-j", "ACCEPT"])
        before = copy.deepcopy(self.fixture.chains)
        with self.assertRaisesRegex(MODULE.FirewallError, "unexpected rules"):
            MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, before)

    def test_altered_receipt_cannot_target_original_rules(self):
        self.install()
        self.plan["rules"][0]["chain"] = "DOCKER-FORWARD"
        before = copy.deepcopy(self.fixture.chains)
        with self.assertRaises(MODULE.FirewallError):
            MODULE.remove(self.plan, self.fixture)
        self.assertEqual(self.fixture.chains, before)

    def test_backend_error_is_not_absent_chain(self):
        self.fixture.fail_when = lambda argv: True
        with self.assertRaisesRegex(MODULE.FirewallError, "resource failure"):
            self.install()
        self.assertFalse(self.plan["created_chains"])

    def test_conntrack_canonicalization_is_accepted(self):
        self.install()
        for rows in self.fixture.chains.values():
            for row in rows:
                if "--ctstate" in row:
                    row[row.index("--ctstate") + 1] = "ESTABLISHED,RELATED"
        # Real -C accepts either state order; make the fixture do the same.
        def run(argv):
            return self.fixture(["ESTABLISHED,RELATED" if a == "RELATED,ESTABLISHED" else a for a in argv])
        MODULE.remove(self.plan, run)
        self.assertEqual(self.fixture.chains, self.fixture.original)

    def test_realistic_iptables_s_match_order_is_accepted(self):
        self.install()
        for rows in self.fixture.chains.values():
            for row in rows:
                if "--comment" in row and "-i" in row and "-s" in row:
                    # Input -i bridge -s subnet is serialized as -s subnet -i bridge.
                    self.assertEqual(row[:4:2], ["-i", "-s"])
                    row[:4] = row[2:4] + row[:2]
                if "--comment" in row and "-o" in row and "-d" in row:
                    self.assertEqual(row[:4:2], ["-o", "-d"])
                    row[:4] = row[2:4] + row[:2]
        def run(argv):
            if "-C" in argv or "-D" in argv:
                argv = list(argv)
                offset = 7
                if argv[offset:offset + 4:2] in (["-i", "-s"], ["-o", "-d"]):
                    argv[offset:offset + 4] = argv[offset + 2:offset + 4] + argv[offset:offset + 2]
            return self.fixture(argv)
        MODULE.remove(self.plan, run)
        self.assertEqual(self.fixture.chains, self.fixture.original)

    def test_bridge_prefix_configuration_is_supported_without_overlap(self):
        valid = MODULE.plan("10.203.1.0/24", "10.205.0.0/20", "a" * 32)
        self.assertEqual(valid["networks"][0]["subnet"], "10.205.0.0/20")
        with self.assertRaisesRegex(MODULE.FirewallError, "overlap"):
            MODULE.plan("10.203.1.0/24", "10.203.0.0/16", "a" * 32)

    def test_negation_and_duplicate_matches_are_not_normalized_away(self):
        expected = ["-s", "10.203.2.0/24", "!", "-o", "tonram0", "-j", "MASQUERADE"]
        changed = [a for a in expected if a != "!"]
        self.assertNotEqual(MODULE._canonical(expected), MODULE._canonical(changed))
        self.assertNotEqual(MODULE._canonical(expected), MODULE._canonical(expected + ["-s", "10.203.2.0/24"]))

    def test_invalid_or_overlapping_plan_is_rejected(self):
        for subnet, bridge, token in [("0.0.0.0/0", "10.203.2.0/24", "a" * 32),
                                      ("10.203.1.0/24", "10.203.1.0/24", "a" * 32),
                                      ("10.203.1.2/24", "10.203.2.0/24", "a" * 32),
                                      ("10.203.1.0/24", "10.203.2.0/24", "; rm")]:
            with self.assertRaises(MODULE.FirewallError):
                MODULE.plan(subnet, bridge, token)


if __name__ == "__main__":
    unittest.main()
