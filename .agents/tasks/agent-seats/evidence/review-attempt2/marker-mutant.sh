#!/usr/bin/env bash
# AGENT_BOOTSTRAP_GENERATED
# Seat configuration for the multi-agent collaboration protocol.
# Seats are the fixed protocol vocabulary (tags); occupants are dynamic data in
# docs/agent-configs/seats.json. Bash only dispatches; one python3 program does
# the JSON work. The program is passed with `python3 -c` so the process keeps
# the caller's stdin (a real terminal stays interactive for `wizard`).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SEATS_FILE="${AGENT_SEATS_FILE:-$PROJECT_ROOT/docs/agent-configs/seats.json}"
LEGACY_PROFILES="${AGENT_SEATS_LEGACY_PROFILES:-$PROJECT_ROOT/docs/agent-configs/model-profiles.json}"
AGENTS_MD="${AGENT_SEATS_AGENTS_MD:-$PROJECT_ROOT/AGENTS.md}"

usage() {
  printf '%s\n' \
    "Usage:" \
    "  scripts/agent-seats.sh show                       # roster + warnings (read-only)" \
    "  scripts/agent-seats.sh validate                   # exit 1 on an invalid assignment (read-only)" \
    "  scripts/agent-seats.sh suggest                    # proposed roster (read-only)" \
    "  scripts/agent-seats.sh wizard [--yes]             # interactive assignment on a TTY; --yes accepts suggestions" \
    "  scripts/agent-seats.sh set <seat|route> --host <claude|codex|gemini|cursor|windsurf|human> \\" \
    "        [--model <id> --effort <e>] [--fallback-model <id> --fallback-effort <e>] [--no-fallback]" \
    "  scripts/agent-seats.sh init                       # create seats.json once (defaults or legacy migration); never overwrites" \
    "  scripts/agent-seats.sh reset                      # rewrite seats.json from bundle defaults (explicit)" \
    "  scripts/agent-seats.sh render                     # refresh the seat roster block in AGENTS.md" \
    "  scripts/agent-seats.sh roster-block               # print the roster block text (for generators)" \
    "  scripts/agent-seats.sh resolve <seat|route>       # 8 lines for launchers: seat tag phase host model effort fallback_model fallback_effort" \
    "  scripts/agent-seats.sh model-info <model>         # 3 lines: host default_effort efforts(space-separated)" \
    "  scripts/agent-seats.sh conflict <seat|route> <effective-model>   # prints 1 when @build launches with a @gate/@verify model" \
    "" \
    "Seats: @spec @gate @build @verify @audit @owner. Route aliases: planning=@gate coding=@build reviewing=@verify." \
    "Exit codes: 0 ok, 1 invalid/usage, 2 written-but-not-rendered, 3 roster markers unbalanced (nothing written)."
}

fail() {
  printf 'agent-seats: ERROR: %s\n' "$*" >&2
  exit 1
}

# Bash 3.2: read -d '' returns non-zero at EOF, hence the || true.
read -r -d '' SEATS_PY <<'PY' || true
import json
import os
import pathlib
import re
import sys

SEATS_FILE = pathlib.Path(os.environ["SEATS_FILE"])
LEGACY = pathlib.Path(os.environ["LEGACY_PROFILES"])
AGENTS_MD = pathlib.Path(os.environ["AGENTS_MD"])
ROSTER_BEGIN = "<!-- BEGIN MANAGED: multi-agent-bootstrap:seat-roster -->"
ROSTER_END = "<!-- END MANAGED: multi-agent-bootstrap:seat-roster -->"
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
args = sys.argv[2:]

SCHEMA = "agent-seats/v1"
HOSTS = ("claude", "codex", "gemini", "cursor", "windsurf", "human")
LAUNCHABLE = ("codex",)
ROUTE_ALIASES = {"planning": "gate", "coding": "build", "reviewing": "verify"}
SEAT_ORDER = ["spec", "gate", "build", "verify", "audit", "owner"]
SEAT_META = {
    "spec": {"tag": "@spec", "phase": "analysis", "duty": "analysis and specification"},
    "gate": {"tag": "@gate", "phase": "technical_review", "duty": "pre-coding technical review (blocking adequacy verdict)"},
    "build": {"tag": "@build", "phase": "implementation", "duty": "bounded implementation"},
    "verify": {"tag": "@verify", "phase": "verification", "duty": "final technical review"},
    "audit": {"tag": "@audit", "phase": "cross_review", "duty": "independent cross-review"},
    "owner": {"tag": "@owner", "phase": "resolution", "duty": "final decision"},
}
# Grammar: values that travel through launcher interfaces can never contain
# whitespace or delimiters.
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]*$")
EFFORT_RE = re.compile(r"^[a-z][a-z0-9_-]*$")
LEGACY_EFFORTS = ["none", "low", "medium", "high", "xhigh", "max"]
DEFAULT_CATALOG = {
    "gpt-6-astra": {"host": "codex", "efforts": ["none", "low", "medium", "high", "xhigh", "ultra"], "default_effort": "ultra"},
    "gpt-5.6-luna": {"host": "codex", "efforts": list(LEGACY_EFFORTS), "default_effort": "xhigh"},
    "gpt-5.6-terra": {"host": "codex", "efforts": list(LEGACY_EFFORTS), "default_effort": "xhigh"},
}
DEFAULT_SEATS = {
    "spec": {"host": "claude"},
    "gate": {"host": "codex", "model": "gpt-6-astra", "effort": "ultra", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"},
    "build": {"host": "codex", "model": "gpt-5.6-luna", "effort": "xhigh", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"},
    "verify": {"host": "codex", "model": "gpt-6-astra", "effort": "ultra", "fallback_model": "gpt-5.6-terra", "fallback_effort": "xhigh"},
    "audit": {"host": "claude"},
    "owner": {"host": "human"},
}


class SeatsError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def out(message=""):
    print(message)


def warn(message):
    print(f"agent-seats: warn: {message}", file=sys.stderr)


def note(message):
    print(f"agent-seats: note: {message}", file=sys.stderr)


def clone(value):
    return json.loads(json.dumps(value))


def default_document():
    return {
        "schema": SCHEMA,
        "catalog": {"models": clone(DEFAULT_CATALOG)},
        "seats": {seat: dict(SEAT_META[seat], occupant=clone(DEFAULT_SEATS[seat])) for seat in SEAT_ORDER},
    }


def read_json(path):
    """Return (document, error). error is None when the file parsed."""
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "missing"
    except (OSError, UnicodeError) as exc:
        return None, f"cannot read {path}: {exc}"
    except json.JSONDecodeError as exc:
        return None, f"malformed JSON in {path}: line {exc.lineno} column {exc.colno}"


def migrate_legacy(doc):
    """Seed codex seats from a valid legacy model-profiles.json. Returns notes.
    Never produces an invalid document: unknown models and efforts are added
    to the catalog explicitly, with a note."""
    legacy, error = read_json(LEGACY)
    if error == "missing":
        return []
    if error:
        raise SeatsError(f"legacy model-profiles.json is not usable: {error}")
    if not isinstance(legacy, dict) or legacy.get("schema") != "agent-model-profiles/v1":
        raise SeatsError("legacy model-profiles.json is not agent-model-profiles/v1")
    profiles = legacy.get("profiles") or {}
    profile = profiles.get(legacy.get("default_profile") or "") if isinstance(profiles, dict) else None
    if not isinstance(profile, dict):
        raise SeatsError("legacy model-profiles.json has no usable default profile")
    notes = []
    base_effort = profile.get("reasoning_effort")
    if not isinstance(base_effort, str) or not EFFORT_RE.match(base_effort):
        raise SeatsError("legacy reasoning_effort is missing or malformed")
    models = doc["catalog"]["models"]

    def ensure(model, effort):
        if not isinstance(model, str) or not MODEL_RE.match(model):
            raise SeatsError(f"legacy model id is not usable: {model!r}")
        if not isinstance(effort, str) or not EFFORT_RE.match(effort):
            raise SeatsError(f"legacy effort is not usable for {model}: {effort!r}")
        spec = models.get(model)
        if spec is None:
            spec = {"host": "codex", "efforts": list(LEGACY_EFFORTS), "default_effort": effort}
            models[model] = spec
            notes.append(f"catalog: added {model} from legacy model-profiles.json (efforts {', '.join(LEGACY_EFFORTS)}; default {effort})")
        if effort not in spec["efforts"]:
            spec["efforts"].append(effort)
            notes.append(f"catalog: {model} gains effort '{effort}' declared by the legacy profile")

    for route, seat in ROUTE_ALIASES.items():
        model = profile.get(f"{route}_model")
        if not isinstance(model, str) or not model:
            continue
        effort = profile.get(f"{route}_reasoning_effort", base_effort)
        ensure(model, effort)
        occ = {"host": "codex", "model": model, "effort": effort}
        fallback = profile.get(f"{route}_fallback_model")
        if isinstance(fallback, str) and fallback:
            fallback_effort = profile.get(f"{route}_fallback_reasoning_effort", base_effort)
            ensure(fallback, fallback_effort)
            occ["fallback_model"] = fallback
            occ["fallback_effort"] = fallback_effort
        doc["seats"][seat]["occupant"] = occ
        notes.append(f"{SEAT_META[seat]['tag']}: seeded from legacy route '{route}'")
    return notes


def validate(doc):
    errors, warnings = [], []
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return [f"schema must be {SCHEMA}"], warnings
    models = (doc.get("catalog") or {}).get("models")
    if not isinstance(models, dict) or not models:
        errors.append("catalog.models must be a non-empty object")
        models = {}
    for mid, spec in models.items():
        if not isinstance(mid, str) or not MODEL_RE.match(mid):
            errors.append(f"catalog model id {mid!r} violates the model grammar [A-Za-z0-9][A-Za-z0-9._:/-]*")
            continue
        if not isinstance(spec, dict) or spec.get("host") not in HOSTS:
            errors.append(f"catalog model {mid}: host must be one of {', '.join(HOSTS)}")
            continue
        efforts = spec.get("efforts")
        if not isinstance(efforts, list) or not efforts or not all(isinstance(e, str) and EFFORT_RE.match(e) for e in efforts):
            errors.append(f"catalog model {mid}: efforts must be a non-empty array matching [a-z][a-z0-9_-]*")
        elif spec.get("default_effort") not in efforts:
            errors.append(f"catalog model {mid}: default_effort must be one of its efforts")
    seats = doc.get("seats")
    if not isinstance(seats, dict):
        return errors + ["seats must be an object"], warnings
    for seat in SEAT_ORDER:
        entry = seats.get(seat)
        if not isinstance(entry, dict):
            errors.append(f"seat {seat}: missing")
            continue
        meta = SEAT_META[seat]
        if entry.get("tag") != meta["tag"] or entry.get("phase") != meta["phase"]:
            errors.append(f"seat {seat}: tag/phase are protocol constants ({meta['tag']}, {meta['phase']})")
        occ = entry.get("occupant")
        if not isinstance(occ, dict):
            errors.append(f"seat {seat}: occupant must be an object")
            continue
        host = occ.get("host")
        if host not in HOSTS:
            errors.append(f"seat {seat}: occupant.host must be one of {', '.join(HOSTS)}")
            continue
        if seat == "owner" and host != "human":
            errors.append("seat owner: occupant.host must be human")
        if host in LAUNCHABLE:
            for key, ekey in (("model", "effort"), ("fallback_model", "fallback_effort")):
                mid = occ.get(key)
                if key == "fallback_model" and mid is None:
                    warnings.append(f"seat {seat}: no fallback model; CODEX_USE_FALLBACK launches will be refused")
                    continue
                if not isinstance(mid, str) or not MODEL_RE.match(mid):
                    errors.append(f"seat {seat}: occupant.{key} is required for host {host} and must match the model grammar")
                    continue
                spec = models.get(mid)
                if spec is None:
                    errors.append(f"seat {seat}: model {mid} is not in catalog.models")
                    continue
                if spec.get("host") != host:
                    errors.append(f"seat {seat}: model {mid} belongs to host {spec.get('host')}, not {host}")
                eff = occ.get(ekey)
                if not isinstance(eff, str) or eff not in (spec.get("efforts") or []):
                    errors.append(f"seat {seat}: {ekey} '{eff}' is not supported by {mid} (supported: {', '.join(spec.get('efforts') or [])})")
        elif occ.get("model"):
            warnings.append(f"seat {seat}: host {host} is host-controlled; model '{occ.get('model')}' is informational only")
    for reviewer in ("gate", "verify"):
        oa = seats.get(reviewer, {}).get("occupant", {})
        ob = seats.get("build", {}).get("occupant", {})
        if oa.get("host") == "codex" and ob.get("host") == "codex":
            shared = {oa.get("model"), oa.get("fallback_model")} & {ob.get("model"), ob.get("fallback_model")} - {None}
            if shared:
                warnings.append(f"{SEAT_META[reviewer]['tag']} and @build share {', '.join(sorted(shared))}: review independence is by session only; such @build launches carry policy_exception=gate_coding")
    return errors, warnings


def occupant_text(occ):
    host = occ.get("host", "?")
    if host in LAUNCHABLE:
        text = f"{host} {occ.get('model')} @ {occ.get('effort')}"
        if occ.get("fallback_model"):
            text += f" (fallback {occ.get('fallback_model')} @ {occ.get('fallback_effort')})"
        else:
            text += " (no fallback)"
        return text
    if host == "human":
        return "human (user)"
    return f"{host} (host-controlled model)"


def roster_lines(doc):
    return [f"- `{doc['seats'][s]['tag']}` · {doc['seats'][s]['phase']} · {occupant_text(doc['seats'][s]['occupant'])}" for s in SEAT_ORDER]


def print_roster(doc, title):
    out(title)
    for line in roster_lines(doc):
        out(line)


def report(errors, warnings):
    for w in warnings:
        warn(w)
    for e in errors:
        print(f"agent-seats: ERROR: {e}", file=sys.stderr)


def save(doc):
    errors, _ = validate(doc)
    if errors:
        report(errors, [])
        raise SeatsError("refusing to write an invalid seats.json")
    SEATS_FILE.parent.mkdir(parents=True, exist_ok=True)
    SEATS_FILE.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def load_current():
    """Current seats.json or a SeatsError with guidance. Legacy is never consulted here."""
    doc, error = read_json(SEATS_FILE)
    if error == "missing":
        raise SeatsError(f"{SEATS_FILE} is missing; run scripts/agent-seats.sh init (or wizard --yes)")
    if error:
        raise SeatsError(f"{error}; fix it by hand or run scripts/agent-seats.sh reset")
    return doc


def proposal():
    """Lifecycle: valid seats.json -> itself; missing -> legacy migration when a
    legacy profile exists, else defaults; malformed seats.json -> error."""
    doc, error = read_json(SEATS_FILE)
    if error is None:
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("current seats.json is invalid; run set/reset to repair it")
        return doc, "current", []
    if error != "missing":
        raise SeatsError(f"{error}; run scripts/agent-seats.sh reset to start over")
    doc = default_document()
    if LEGACY.exists():
        notes = migrate_legacy(doc)
        return doc, "legacy", notes
    return doc, "defaults", []


def render_block_bytes(doc, newline):
    lines = [ROSTER_BEGIN] + roster_lines(doc) + [ROSTER_END]
    return newline.join(lines).encode("utf-8")


def render(doc):
    """Replace exactly one balanced roster block or append one; every byte
    outside the block is preserved. Unbalanced markers -> exit 3, no write."""
    if not AGENTS_MD.is_file():
        raise SeatsError(f"{AGENTS_MD} is missing; cannot render the seat roster")
    data = AGENTS_MD.read_bytes()
    newline = "\r\n" if b"\r\n" in data else "\n"
    begin, end = ROSTER_BEGIN.encode("utf-8"), ROSTER_END.encode("utf-8")
    nb, ne = data.count(begin), data.count(end)
    if nb == 0 and ne == 0:
        section = ("" if data.endswith(newline.encode("utf-8")) or not data else newline) + newline + "## Seat Roster" + newline + newline
        new = data + section.encode("utf-8") + render_block_bytes(doc, newline) + newline.encode("utf-8")
    else:
        start = data.index(begin)
        stop = data.index(end) + len(end)
        new = data[:start] + render_block_bytes(doc, newline) + data[stop:]
    if new != data:
        AGENTS_MD.write_bytes(new)
        out("agent-seats: rendered seat roster into AGENTS.md")
    else:
        out("agent-seats: seat roster already current in AGENTS.md")


def write_and_render(doc, title):
    save(doc)
    print_roster(doc, title)
    try:
        render(doc)
    except SeatsError as exc:
        print(f"agent-seats: ERROR: seats.json was written but the roster was NOT rendered: {exc}", file=sys.stderr)
        raise SeatsError(str(exc), code=2)


def seat_from_arg(value):
    key = value.lstrip("@")
    key = ROUTE_ALIASES.get(key, key)
    if key not in SEAT_META:
        raise SeatsError(f"unknown seat or route: {value}")
    return key


def parse_opts(tokens):
    opts = {}
    it = iter(tokens)
    for token in it:
        if token == "--no-fallback":
            opts["no_fallback"] = True
            continue
        if token.startswith("--"):
            try:
                opts[token[2:].replace("-", "_")] = next(it)
            except StopIteration:
                raise SeatsError(f"{token} requires a value")
        else:
            raise SeatsError(f"unexpected argument: {token}")
    return opts


def ask(prompt, default=""):
    try:
        answer = input(prompt)
    except EOFError:
        return default
    answer = answer.strip()
    return answer if answer else default


def interactive_wizard(doc):
    models = doc["catalog"]["models"]
    codex_models = [m for m, s in models.items() if s.get("host") == "codex"]
    host_map = {"1": "claude", "2": "codex", "3": "gemini", "4": "cursor", "5": "windsurf"}
    for seat in SEAT_ORDER:
        entry = doc["seats"][seat]
        occ = entry["occupant"]
        out("")
        out(f"{entry['tag']} — {entry['duty']} (phase {entry['phase']})")
        out(f"  suggestion: {occupant_text(occ)}")
        if seat == "owner":
            out("  @owner is always the human user.")
            continue
        out("  hosts: 1) claude  2) codex  3) gemini  4) cursor  5) windsurf   [Enter = keep suggestion]")
        choice = ask("  host> ")
        if choice in host_map and host_map[choice] != occ.get("host"):
            new_host = host_map[choice]
            if new_host == "codex":
                seed = clone(DEFAULT_SEATS[seat]) if DEFAULT_SEATS[seat].get("host") == "codex" else {"host": "codex", "model": codex_models[0], "effort": models[codex_models[0]]["default_effort"]}
                occ = seed
            else:
                occ = {"host": new_host}
            entry["occupant"] = occ
        elif choice and choice not in host_map:
            out("  (unknown choice, keeping suggestion)")
        if entry["occupant"].get("host") != "codex":
            continue
        occ = entry["occupant"]
        for i, m in enumerate(codex_models, 1):
            spec = models[m]
            out(f"    {i}) {m}  efforts: {', '.join(spec['efforts'])}  default: {spec['default_effort']}")
        pick = ask(f"  model [{occ.get('model')}]> ")
        if pick.isdigit() and 1 <= int(pick) <= len(codex_models):
            m = codex_models[int(pick) - 1]
            if m != occ.get("model"):
                occ["model"] = m
                occ["effort"] = models[m]["default_effort"]
        eff = ask(f"  effort [{occ.get('effort')}]> ")
        if eff:
            occ["effort"] = eff
        fb = ask(f"  fallback model number, or 'none' [{occ.get('fallback_model') or 'none'}]> ")
        if fb == "none":
            occ.pop("fallback_model", None)
            occ.pop("fallback_effort", None)
        elif fb.isdigit() and 1 <= int(fb) <= len(codex_models):
            m = codex_models[int(fb) - 1]
            if m != occ.get("fallback_model"):
                occ["fallback_model"] = m
                occ["fallback_effort"] = models[m]["default_effort"]
        if occ.get("fallback_model"):
            fbe = ask(f"  fallback effort [{occ.get('fallback_effort')}]> ")
            if fbe:
                occ["fallback_effort"] = fbe
        errors, warnings = validate(doc)
        seat_errors = [e for e in errors if e.startswith(f"seat {seat}:")]
        if seat_errors:
            report(seat_errors, [])
            raise SeatsError("choice rejected; nothing written. Rerun the wizard")
    return doc


def main():
    if cmd == "suggest":
        doc, source, notes = proposal()
        print_roster(doc, {"current": "Current seats (seats.json):", "legacy": "Suggested seats (migrated from model-profiles.json):", "defaults": "Suggested seats (bundle defaults):"}[source])
        for n in notes:
            note(n)
        return 0
    if cmd == "reset":
        doc = default_document()
        write_and_render(doc, "seats.json reset to bundle defaults:")
        return 0
    if cmd == "init":
        doc, error = read_json(SEATS_FILE)
        if error is None:
            errors, warnings = validate(doc)
            report(errors, warnings)
            if errors:
                raise SeatsError("existing seats.json is invalid; init does not overwrite. Run set/reset")
            out("agent-seats: seats.json present and valid; nothing written")
            return 0
        if error != "missing":
            raise SeatsError(f"{error}; init does not overwrite. Run reset")
        doc = default_document()
        source = "defaults"
        notes = []
        if LEGACY.exists():
            notes = migrate_legacy(doc)
            source = "legacy"
        save(doc)
        for n in notes:
            note(n)
        print_roster(doc, f"seats.json created from {source}:")
        return 0
    if cmd == "wizard":
        accept_all = "--yes" in args
        doc, source, notes = proposal()
        for n in notes:
            note(n)
        if source == "current":
            note("starting from the current seats.json")
        interactive = sys.stdin.isatty() and not accept_all
        if interactive:
            doc = interactive_wizard(doc)
        write_and_render(doc, "seats.json written:")
        return 0
    if cmd == "show":
        doc = load_current()
        errors, warnings = validate(doc)
        print_roster(doc, "Seats:")
        report(errors, warnings)
        return 1 if errors else 0
    if cmd == "validate":
        doc = load_current()
        errors, warnings = validate(doc)
        report(errors, warnings)
        if errors:
            return 1
        out("agent-seats: seats.json valid")
        return 0
    if cmd == "render":
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("refusing to render an invalid assignment")
        render(doc)
        return 0
    if cmd == "roster-block":
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("invalid assignment")
        sys.stdout.write(render_block_bytes(doc, "\n").decode("utf-8") + "\n")
        return 0
    if cmd == "resolve":
        if not args:
            raise SeatsError("resolve requires a seat or route")
        seat = seat_from_arg(args[0])
        doc = load_current()
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            return 1
        entry = doc["seats"][seat]
        occ = entry["occupant"]
        for value in (seat, entry["tag"], entry["phase"], occ.get("host", ""), occ.get("model") or "", occ.get("effort") or "", occ.get("fallback_model") or "", occ.get("fallback_effort") or ""):
            out(value)
        return 0
    if cmd == "model-info":
        if not args:
            raise SeatsError("model-info requires a model id")
        doc = load_current()
        spec = doc["catalog"]["models"].get(args[0])
        if not isinstance(spec, dict):
            raise SeatsError(f"model {args[0]} is not in catalog.models; add it with scripts/agent-seats.sh (edit seats.json catalog) before launching")
        out(spec.get("host", ""))
        out(spec.get("default_effort", ""))
        out(" ".join(spec.get("efforts") or []))
        return 0
    if cmd == "conflict":
        if len(args) < 2:
            raise SeatsError("conflict requires a seat and the effective model")
        seat = seat_from_arg(args[0])
        model = args[1]
        doc = load_current()
        if seat != "build":
            out("0")
            return 0
        reviewer_models = set()
        for reviewer in ("gate", "verify"):
            occ = doc["seats"][reviewer]["occupant"]
            if occ.get("host") == "codex":
                reviewer_models |= {occ.get("model"), occ.get("fallback_model")} - {None}
        if model in reviewer_models:
            note(f"@build effective model {model} is also a @gate/@verify model; the launch must carry policy_exception=gate_coding")
            out("1")
        else:
            out("0")
        return 0
    if cmd == "set":
        if not args:
            raise SeatsError("set requires a seat")
        seat = seat_from_arg(args[0])
        doc, source, notes = proposal()
        for n in notes:
            note(n)
        opts = parse_opts(args[1:])
        prev = doc["seats"][seat]["occupant"]
        host = opts.get("host") or prev.get("host")
        occ = {"host": host}
        if host in LAUNCHABLE:
            models = doc["catalog"]["models"]
            occ["model"] = opts.get("model", prev.get("model"))
            if "effort" in opts:
                occ["effort"] = opts["effort"]
            elif prev.get("model") == occ["model"] and prev.get("effort"):
                occ["effort"] = prev["effort"]
            else:
                occ["effort"] = (models.get(occ["model"]) or {}).get("default_effort")
            if not opts.get("no_fallback"):
                fb = opts.get("fallback_model", prev.get("fallback_model"))
                if fb:
                    occ["fallback_model"] = fb
                    if "fallback_effort" in opts:
                        occ["fallback_effort"] = opts["fallback_effort"]
                    elif prev.get("fallback_model") == fb and prev.get("fallback_effort"):
                        occ["fallback_effort"] = prev["fallback_effort"]
                    else:
                        occ["fallback_effort"] = (models.get(fb) or {}).get("default_effort")
        doc["seats"][seat]["occupant"] = occ
        errors, warnings = validate(doc)
        report(errors, warnings)
        if errors:
            raise SeatsError("assignment is invalid; nothing written")
        write_and_render(doc, f"agent-seats: {SEAT_META[seat]['tag']} -> {occupant_text(occ)}")
        return 0
    raise SeatsError(f"unknown command: {cmd}")


try:
    sys.exit(main())
except SeatsError as exc:
    print(f"agent-seats: ERROR: {exc}", file=sys.stderr)
    sys.exit(exc.code)
PY

cmd="${1:-}"
case "$cmd" in
  show|validate|suggest|wizard|set|init|reset|render|roster-block|resolve|model-info|conflict)
    command -v python3 >/dev/null 2>&1 || fail "python3 is required"
    shift
    SEATS_FILE="$SEATS_FILE" LEGACY_PROFILES="$LEGACY_PROFILES" AGENTS_MD="$AGENTS_MD" \
      python3 -c "$SEATS_PY" "$cmd" "$@"
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    fail "unknown command: $cmd"
    ;;
esac
