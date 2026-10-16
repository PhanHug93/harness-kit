#!/usr/bin/env python3
"""Tests for agent-bootstrap/lib/knowledge.py (project knowledge file)."""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(ROOT, "agent-bootstrap", "lib", "knowledge.py")
SCHEMA = os.path.join(ROOT, "agent-bootstrap", "schemas", "harness-project-knowledge-v1.schema.json")
REL = ".tools/agent-state/project-knowledge.json"


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


class Base(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.t = os.path.realpath(self._tmp.name)
        self.write("a.txt", "alpha\n")
        self.write("b.txt", "bravo-local\n")
        self.write("docs/agent-configs/agent-bootstrap.lock.json", '{"version":"1"}\n')
        self.write("docs/superpowers/specs/project-tech-stack.json", '{"schema":"x"}\n')
        self.write(".tools/agent-state/harness-baseline/files/a.txt", "alpha\n")
        self.write(".tools/agent-state/harness-baseline/files/b.txt", "bravo\n")
        self.plan = os.path.join(self.t, "plan.json")
        self.write_plan(["a.txt", "b.txt", "c.txt"])

    def write(self, rel, text):
        path = os.path.join(self.t, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            handle.write(text)

    def write_plan(self, paths):
        doc = {"schema": "agent-bootstrap-upgrade-plan/v1", "target": self.t,
               "files": [{"path": p, "action": "update"} for p in paths]}
        with open(self.plan, "w") as handle:
            json.dump(doc, handle)

    def run_cli(self, *args, ok=True):
        proc = subprocess.run([sys.executable, "-B", "-I", ENGINE, "--target", self.t] + list(args),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        if ok:
            self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc

    def refresh(self):
        return self.run_cli("refresh", "--plan-json", self.plan, "--kit-version", "2026.10.14.1",
                            "--kit-source", ".harness-kit/v1/agent-bootstrap")

    def load(self):
        with open(os.path.join(self.t, REL)) as handle:
            return json.load(handle)


class Knowledge(Base):
    def test_refresh_builds_files_and_kit(self):
        self.refresh()
        doc = self.load()
        self.assertEqual(doc["schema"], "harness-project-knowledge/v1")
        self.assertEqual(doc["kit"]["version"], "2026.10.14.1")
        self.assertEqual(doc["kit"]["lock_sha256"], sha('{"version":"1"}\n'))
        self.assertEqual(doc["kit"]["contract_sha256"], sha('{"schema":"x"}\n'))
        lines = sorted("%s\0%s\n" % (p, sha(t)) for p, t in (("a.txt", "alpha\n"), ("b.txt", "bravo\n")))
        self.assertEqual(doc["kit"]["baseline_sha256"], sha("".join(lines)))
        self.assertEqual(doc["files"]["a.txt"]["state"], "clean")
        self.assertEqual(doc["files"]["b.txt"]["state"], "patched")
        self.assertEqual(doc["files"]["b.txt"]["local_sha256"], sha("bravo-local\n"))
        self.assertEqual(doc["files"]["b.txt"]["baseline_sha256"], sha("bravo\n"))
        self.assertEqual(doc["files"]["c.txt"]["local_sha256"], "")
        self.assertEqual(doc["ignore_target"], "exclude")

    def test_resolution_kept_then_stale_or_dropped(self):
        self.refresh()
        self.run_cli("resolve", "a.txt", "--kind", "resolved", "--reason", "merged")
        self.run_cli("resolve", "b.txt", "--kind", "keep-local", "--reason", "custom")
        self.refresh()
        doc = self.load()
        self.assertEqual(doc["files"]["a.txt"]["resolution"]["kind"], "resolved")
        self.assertFalse(doc["files"]["a.txt"]["resolution"]["stale"])
        self.assertEqual(doc["files"]["b.txt"]["state"], "pinned")
        self.assertEqual(self.run_cli("pins").stdout.split(), ["b.txt"])
        self.write("a.txt", "alpha2\n")
        self.write("b.txt", "bravo-edited\n")
        self.refresh()
        doc = self.load()
        self.assertNotIn("resolution", doc["files"]["a.txt"])
        self.assertTrue(doc["files"]["b.txt"]["resolution"]["stale"])
        self.assertEqual(doc["files"]["b.txt"]["state"], "patched")
        self.assertEqual(self.run_cli("pins").stdout.strip(), "")
        self.assertIn("stale", self.run_cli("summary").stdout)

    def test_decisions(self):
        self.run_cli("decision", "m1", "--status", "pending", "--facts-sha256", "f1")
        self.run_cli("decision", "m2", "--status", "pending", "--facts-sha256", "f2")
        self.run_cli("decision", "m2", "--status", "accepted", "--facts-sha256", "f2")
        self.assertEqual(self.run_cli("decisions", "--pending").stdout.split(), ["m1"])
        self.assertEqual(self.load()["migrations"]["m2"]["status"], "accepted")

    def test_ignore_target(self):
        self.assertEqual(self.run_cli("ignore-target").stdout.strip(), "exclude")
        self.run_cli("ignore-target", "gitignore")
        self.assertEqual(self.run_cli("ignore-target").stdout.strip(), "gitignore")
        self.assertEqual(self.run_cli("ignore-target", "bogus", ok=False).returncode, 2)

    def test_runs_capped(self):
        for i in range(7):
            self.run_cli("record-run", "--stamp", "s%d" % i, "--mode", "update", "--from", "1", "--to", "2",
                         "--result", "done")
        runs = self.load()["runs"]
        self.assertEqual([r["stamp"] for r in runs], ["s2", "s3", "s4", "s5", "s6"])

    def test_summary_short_with_reason_and_pending(self):
        self.refresh()
        self.run_cli("resolve", "b.txt", "--kind", "resolved", "--reason", "needs-custom-header")
        for i in range(6):
            self.run_cli("decision", "mig%d" % i, "--status", "pending", "--facts-sha256", "f")
            self.run_cli("record-run", "--stamp", "s%d" % i, "--mode", "install", "--from", "", "--to", "2",
                         "--result", "done")
        out = self.run_cli("summary").stdout
        self.assertLessEqual(len(out.splitlines()), 15)
        self.assertIn("needs-custom-header", out)
        self.assertIn("mig0", out)

    def test_symlinked_state_refused(self):
        other = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(other, ignore_errors=True))
        import shutil
        shutil.rmtree(os.path.join(self.t, ".tools/agent-state/harness-baseline"))
        os.rmdir(os.path.join(self.t, ".tools/agent-state"))
        os.symlink(other, os.path.join(self.t, ".tools/agent-state"))
        proc = self.run_cli("ignore-target", "gitignore", ok=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("link", proc.stderr)
        self.assertEqual(os.listdir(other), [])
        os.unlink(os.path.join(self.t, ".tools/agent-state"))
        shutil.rmtree(os.path.join(self.t, ".tools"))
        os.symlink(other, os.path.join(self.t, ".tools"))
        self.assertEqual(self.run_cli("ignore-target", "gitignore", ok=False).returncode, 1)
        self.assertEqual(os.listdir(other), [])

    def test_symlinked_knowledge_file_refused(self):
        self.refresh()
        path = os.path.join(self.t, REL)
        os.rename(path, path + ".real")
        os.symlink(path + ".real", path)
        self.assertEqual(self.run_cli("pins", ok=False).returncode, 1)
        self.assertEqual(self.run_cli("ignore-target", "gitignore", ok=False).returncode, 1)

    def test_atomic_write_leaves_no_temp(self):
        self.refresh()
        self.run_cli("ignore-target", "gitignore")
        names = os.listdir(os.path.join(self.t, ".tools/agent-state"))
        self.assertEqual(sorted(n for n in names if n != "harness-baseline"), ["project-knowledge.json"])

    def test_schema_matches_output(self):
        with open(SCHEMA) as handle:
            schema = json.load(handle)
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.run_cli("resolve", "a.txt", "--kind", "resolved")
        self.run_cli("decision", "m", "--status", "pending", "--facts-sha256", "f")
        self.run_cli("record-run", "--stamp", "s", "--mode", "update", "--from", "1", "--to", "2", "--result", "done")
        self.refresh()
        doc = self.load()
        self.assertEqual(set(schema["required"]), set(doc))
        self.assertEqual(set(schema["properties"]["kit"]["required"]), set(doc["kit"]))
        fschema = schema["properties"]["files"]["additionalProperties"]
        for entry in doc["files"].values():
            self.assertTrue(set(fschema["required"]) <= set(entry))
            self.assertTrue(set(entry) <= set(fschema["properties"]))
        mschema = schema["properties"]["migrations"]["additionalProperties"]
        for entry in doc["migrations"].values():
            self.assertEqual(set(mschema["required"]), set(entry))
        rschema = schema["properties"]["runs"]["items"]
        for entry in doc["runs"]:
            self.assertEqual(set(rschema["required"]), set(entry))


if __name__ == "__main__":
    unittest.main()
