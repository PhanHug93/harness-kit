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
    "  scripts/agent-seats.sh conflict <seat|route> <effective-model>   # prints 1 when @build launches with the primary model of @gate or @verify" \
    "" \
    "Seats: @spec @gate @build @verify @audit @owner. Route aliases: planning=@gate coding=@build reviewing=@verify." \
    "Exit codes: 0 ok; 1 invalid input, refused (lock busy, end of input, unwritable) or usage — nothing written;" \
    "            2 seats.json written but the roster was not rendered; 3 roster markers unbalanced (nothing written);" \
    "            130 interrupted (if 'seats.json written' was printed, run render)."
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
MODEL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/-]*")
EFFORT_RE = re.compile(r"[a-z][a-z0-9_-]*")
OCCUPANT_KEYS = ("model", "effort", "fallback_model", "fallback_effort")


def is_model(v):
    return isinstance(v, str) and MODEL_RE.fullmatch(v) is not None


def is_effort(v):
    return isinstance(v, str) and EFFORT_RE.fullmatch(v) is not None
LEGACY_EFFORTS = ["none", "low", "medium", "high", "xhigh", "max"]
LEGACY_ROUTE_KEYS = ("planning_model", "coding_model", "reviewing_model",
                     "planning_fallback_model", "coding_fallback_model", "reviewing_fallback_model")
# The profile the old generator emitted by default. A legacy file equal to it
# carries no user decision, so seat defaults apply instead of migrating it.
LEGACY_BUNDLE_DEFAULT = {"reasoning_effort": "xhigh", "planning_model": "gpt-5.6-sol", "coding_model": "gpt-5.6-luna",
                         "reviewing_model": "gpt-5.6-sol", "planning_fallback_model": "gpt-5.6-terra",
                         "coding_fallback_model": "gpt-5.6-terra", "reviewing_fallback_model": "gpt-5.6-terra"}
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
        return json.loads(path.read_text(encoding="utf-8-sig")), None
    except FileNotFoundError:
        return None, "missing"
    except (OSError, UnicodeError) as exc:
        return None, f"cannot read {path}: {exc}"
    except json.JSONDecodeError as exc:
        return None, f"malformed JSON in {path}: line {exc.lineno} column {exc.colno}"


def migrate_legacy(doc):
    """Seed codex seats from a valid legacy model-profiles.json.
    Returns (source, notes): source is "legacy" when seats were seeded, or
    "defaults" when the legacy profile equals the old generator default (no user
    decision). Acceptance mirrors the old launcher: all seven v1 keys present,
    model ids and efforts within the grammar, reasoning_effort in the old set.
    Never produces an invalid document: unknown models and efforts are added
    to the catalog explicitly, with a note."""
    legacy, error = read_json(LEGACY)
    if error == "missing":
        return "defaults", []
    if error:
        raise SeatsError(f"legacy model-profiles.json is not usable: {error}")
    if not isinstance(legacy, dict) or legacy.get("schema") != "agent-model-profiles/v1":
        raise SeatsError("legacy model-profiles.json is not agent-model-profiles/v1")
    default_profile = legacy.get("default_profile")
    if not isinstance(default_profile, str) or not default_profile:
        raise SeatsError("legacy model-profiles.json default_profile must be a non-empty string; fix it, or delete the file and run scripts/agent-seats.sh reset")
    profiles = legacy.get("profiles") or {}
    profile = profiles.get(default_profile) if isinstance(profiles, dict) else None
    if not isinstance(profile, dict):
        raise SeatsError("legacy model-profiles.json has no usable default profile")
    notes = []
    for key in ("reasoning_effort",) + LEGACY_ROUTE_KEYS:
        value = profile.get(key)
        if not isinstance(value, str) or not value:
            raise SeatsError(f"legacy model-profiles.json: profile '{legacy.get('default_profile')}' is missing required field '{key}'; fix it, or delete the file and run scripts/agent-seats.sh reset")
    base_effort = profile["reasoning_effort"]
    if base_effort not in LEGACY_EFFORTS:
        raise SeatsError(f"legacy model-profiles.json: unsupported reasoning_effort '{base_effort}' (old launcher set: {', '.join(LEGACY_EFFORTS)})")
    for key in LEGACY_ROUTE_KEYS:
        if not is_model(profile[key]):
            raise SeatsError(f"legacy model-profiles.json: invalid model id for '{key}'")
    extra_effort_keys = [k for k in profile if k.endswith("_reasoning_effort") and k != "reasoning_effort"]
    if not extra_effort_keys and all(profile.get(k) == v for k, v in LEGACY_BUNDLE_DEFAULT.items()):
        return "defaults", ["legacy model-profiles.json equals the old generator default (no user customization); seat defaults apply. seats.json is authoritative; the legacy file can be deleted"]
    models = doc["catalog"]["models"]

    def ensure(model, effort):
        if not is_model(model):
            raise SeatsError(f"legacy model id is not usable: {model!r}")
        if not is_effort(effort):
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
        model = profile[f"{route}_model"]
        effort = profile.get(f"{route}_reasoning_effort", base_effort)
        ensure(model, effort)
        occ = {"host": "codex", "model": model, "effort": effort}
        fallback = profile[f"{route}_fallback_model"]
        fallback_effort = profile.get(f"{route}_fallback_reasoning_effort", base_effort)
        ensure(fallback, fallback_effort)
        occ["fallback_model"] = fallback
        occ["fallback_effort"] = fallback_effort
        doc["seats"][seat]["occupant"] = occ
        notes.append(f"{SEAT_META[seat]['tag']}: seeded from legacy route '{route}'")
    return "legacy", notes


def model_spec(models, mid):
    """Catalog entry for mid, or None when absent or not an object. Callers must
    never dereference a raw catalog value: a hand-edited seats.json can hold a
    string, list or boolean there (gate attempt 3, F2)."""
    if not isinstance(models, dict):
        return None
    spec = models.get(mid)
    return spec if isinstance(spec, dict) else None


def catalog_default_effort(models, mid):
    """Return a catalog default only for a typed model identifier.

    Repair mode intentionally starts from structurally sound but semantically
    invalid documents. Do not pass a hand-edited list/dict/bool through dict
    lookup while rebuilding an occupant; validation below will report it and
    keep the original file untouched.
    """
    if not is_model(mid):
        return None
    spec = model_spec(models, mid)
    return spec.get("default_effort") if spec is not None else None


def validate(doc):
    errors, warnings = [], []
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return [f"schema must be {SCHEMA}"], warnings
    catalog = doc.get("catalog")
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, dict) or not models:
        errors.append("catalog.models must be a non-empty object")
        models = {}
    for mid, spec in models.items():
        if not is_model(mid):
            errors.append(f"catalog model id {mid!r} violates the model grammar [A-Za-z0-9][A-Za-z0-9._:/-]*")
            continue
        if not isinstance(spec, dict) or spec.get("host") not in HOSTS:
            errors.append(f"catalog model {mid}: host must be one of {', '.join(HOSTS)}")
            continue
        efforts = spec.get("efforts")
        if not isinstance(efforts, list) or not efforts or not all(is_effort(e) for e in efforts):
            errors.append(f"catalog model {mid}: efforts must be a non-empty array matching [a-z][a-z0-9_-]*")
        elif spec.get("default_effort") not in efforts:
            errors.append(f"catalog model {mid}: default_effort must be one of its efforts")
        elif len(set(efforts)) != len(efforts):
            warnings.append(f"catalog model {mid}: efforts lists duplicates")
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
        # Every serialized field obeys the grammar whatever the host (resolve emits them all).
        for key in OCCUPANT_KEYS:
            if key in occ and occ[key] is not None and not (is_model(occ[key]) if "model" in key else is_effort(occ[key])):
                errors.append(f"seat {seat}: occupant.{key} {occ[key]!r} violates the grammar")
        if occ.get("fallback_effort") is not None and occ.get("fallback_model") is None:
            errors.append(f"seat {seat}: fallback_effort without fallback_model")
        if host in LAUNCHABLE:
            for key, ekey in (("model", "effort"), ("fallback_model", "fallback_effort")):
                mid = occ.get(key)
                if key == "fallback_model" and mid is None:
                    warnings.append(f"seat {seat}: no fallback model; CODEX_USE_FALLBACK launches will be refused")
                    continue
                if not is_model(mid):
                    errors.append(f"seat {seat}: occupant.{key} is required for host {host} and must match the model grammar")
                    continue
                if mid not in models:
                    errors.append(f"seat {seat}: model {mid} is not in catalog.models")
                    continue
                spec = model_spec(models, mid)
                if spec is None:
                    errors.append(f"seat {seat}: catalog entry for {mid} must be an object, not {type(models.get(mid)).__name__}")
                    continue
                if spec.get("host") != host:
                    errors.append(f"seat {seat}: model {mid} belongs to host {spec.get('host')}, not {host}")
                eff = occ.get(ekey)
                supported = [e for e in (spec.get("efforts") or []) if isinstance(e, str)] if isinstance(spec.get("efforts"), list) else []
                if not isinstance(eff, str) or eff not in supported:
                    errors.append(f"seat {seat}: {ekey} '{eff}' is not supported by {mid} (supported: {', '.join(supported)})")
        elif occ.get("model"):
            warnings.append(f"seat {seat}: host {host} is host-controlled; model '{occ.get('model')}' is informational only")
    def occupant_of(seat):
        entry = seats.get(seat)
        occ = entry.get("occupant") if isinstance(entry, dict) else None
        return occ if isinstance(occ, dict) else {}

    for reviewer in ("gate", "verify"):
        oa = occupant_of(reviewer)
        ob = occupant_of("build")
        if oa.get("host") == "codex" and ob.get("host") == "codex":
            # Primary models only: fallbacks are capacity substitutes, not the
            # review authority, so a shared fallback is not a conflict.
            if oa.get("model") and oa.get("model") == ob.get("model"):
                warnings.append(f"{SEAT_META[reviewer]['tag']} and @build share the primary model {oa.get('model')}: review independence is by session only; such @build launches carry policy_exception=gate_coding")
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


def write_atomic(path, data):
    """Write bytes via a sibling temp file + rename so readers never see a
    truncated file and a failed write leaves the old content intact."""
    path = pathlib.Path(os.path.realpath(path))  # write through symlinks, never replace the link
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    if path.exists() and not os.access(path, os.W_OK):
        # honour a read-only file instead of renaming over it
        raise PermissionError(f"[Errno 13] Permission denied (read-only): '{path}'")
    try:
        mode = path.stat().st_mode & 0o7777 if path.exists() else None
        with open(tmp, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


SAVED = {"seats": False}


def save(doc):
    errors, _ = validate(doc)
    if errors:
        report(errors, [])
        raise SeatsError("refusing to write an invalid seats.json")
    try:
        SEATS_FILE.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(SEATS_FILE, (json.dumps(doc, indent=2) + "\n").encode("utf-8"))
    except OSError as exc:
        raise SeatsError(f"cannot write {SEATS_FILE}: {exc}; nothing written")
    SAVED["seats"] = True


def load_current():
    """Current seats.json or a SeatsError with guidance. Legacy is never consulted here."""
    doc, error = read_json(SEATS_FILE)
    if error == "missing":
        raise SeatsError(f"{SEATS_FILE} is missing; run scripts/agent-seats.sh init (or wizard --yes)")
    if error:
        raise SeatsError(f"{error}; fix it by hand or run scripts/agent-seats.sh reset")
    return doc


def structural_errors(doc):
    """Errors that make the document unusable as a starting point for set."""
    if not isinstance(doc, dict) or doc.get("schema") != SCHEMA:
        return [f"schema must be {SCHEMA}"]
    seats = doc.get("seats")
    if not isinstance(seats, dict):
        return ["seats must be an object"]
    errs = []
    for seat in SEAT_ORDER:
        entry = seats.get(seat)
        if not isinstance(entry, dict) or not isinstance(entry.get("occupant"), dict):
            errs.append(f"seat {seat}: missing or occupant is not an object")
    catalog = doc.get("catalog")
    models = catalog.get("models") if isinstance(catalog, dict) else None
    if not isinstance(models, dict):
        errs.append("catalog.models must be an object")
    else:
        for mid, spec in models.items():
            if not isinstance(spec, dict):
                errs.append(f"catalog.models[{mid!r}] must be an object, not {type(spec).__name__}")
    return errs


def proposal(repairing=False):
    """Lifecycle: valid seats.json -> itself; missing -> legacy migration when a
    legacy profile exists, else defaults; malformed seats.json -> error.
    repairing=True (set) accepts a structurally sound but invalid file so the
    result can be validated instead."""
    doc, error = read_json(SEATS_FILE)
    if error is None:
        errors, _ = validate(doc)
        if errors and repairing and not structural_errors(doc):
            for e in errors:
                warn(f"current seats.json: {e}")
            return doc, "current", []
        if errors:
            report(errors, [])
            raise SeatsError("current seats.json is invalid; fix it by hand, repair the offending seat with set, or run reset")
        return doc, "current", []
    if error != "missing":
        raise SeatsError(f"{error}; run scripts/agent-seats.sh reset to start over")
    doc = default_document()
    if LEGACY.exists():
        source, notes = migrate_legacy(doc)
        return doc, source, notes
    return doc, "defaults", []


def render_block_bytes(doc, newline):
    lines = [ROSTER_BEGIN] + roster_lines(doc) + [ROSTER_END]
    return newline.join(lines).encode("utf-8")


def render(doc):
    """Replace exactly one balanced roster block or append one; every byte
    outside the block is preserved. Unbalanced markers -> exit 3, no write."""
    if not AGENTS_MD.exists():
        raise SeatsError(f"{AGENTS_MD} is missing; cannot render the seat roster")
    if not AGENTS_MD.is_file():
        raise SeatsError(f"{AGENTS_MD} is not a regular file; cannot render the seat roster")
    try:
        data = AGENTS_MD.read_bytes()
    except OSError as exc:
        raise SeatsError(f"cannot read {AGENTS_MD}: {exc}")
    newline = "\r\n" if b"\r\n" in data else "\n"
    begin, end = ROSTER_BEGIN.encode("utf-8"), ROSTER_END.encode("utf-8")
    nb, ne = data.count(begin), data.count(end)
    if nb == 0 and ne == 0:
        section = ("" if data.endswith(newline.encode("utf-8")) or not data else newline) + newline + "## Seat Roster" + newline + newline
        new = data + section.encode("utf-8") + render_block_bytes(doc, newline) + newline.encode("utf-8")
    elif nb == 1 and ne == 1 and data.index(begin) < data.index(end):
        start = data.index(begin)
        stop = data.index(end) + len(end)
        new = data[:start] + render_block_bytes(doc, newline) + data[stop:]
    else:
        raise SeatsError(f"seat roster markers in {AGENTS_MD} are unbalanced (BEGIN={nb}, END={ne}); repair the markers by hand, then rerun render", code=3)
    if new != data:
        try:
            write_atomic(AGENTS_MD, new)
        except OSError as exc:
            raise SeatsError(f"cannot write {AGENTS_MD}: {exc}")
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
    except Exception as exc:  # noqa: BLE001 - the configuration is effective; report the stale roster
        print(f"agent-seats: ERROR: seats.json was written but the roster was NOT rendered: {exc}", file=sys.stderr)
        raise SeatsError(str(exc), code=2)


def seat_from_arg(value):
    key = value.lstrip("@")
    key = ROUTE_ALIASES.get(key, key)
    if key not in SEAT_META:
        raise SeatsError(f"unknown seat or route: {value}")
    return key


SET_OPTIONS = ("host", "model", "effort", "fallback_model", "fallback_effort")


def parse_opts(tokens):
    opts = {}
    it = iter(tokens)
    for token in it:
        if token == "--no-fallback":
            opts["no_fallback"] = True
            continue
        if token.startswith("--"):
            key = token[2:].replace("-", "_")
            if key not in SET_OPTIONS:
                raise SeatsError(f"unknown option {token} (see --help)")
            try:
                value = next(it)
            except StopIteration:
                raise SeatsError(f"{token} requires a value")
            if not value or value.startswith("--"):
                raise SeatsError(f"{token} requires a non-empty value")
            opts[key] = value
        else:
            raise SeatsError(f"unexpected argument: {token}")
    if opts.get("no_fallback") and ("fallback_model" in opts or "fallback_effort" in opts):
        raise SeatsError("--no-fallback cannot be combined with --fallback-model/--fallback-effort")
    return opts


NO_ARG_COMMANDS = ("show", "validate", "suggest", "init", "reset", "render", "roster-block")


def validate_command_args():
    """Reject command-specific usage before taking a write lock or reading state."""
    if cmd in NO_ARG_COMMANDS:
        if args:
            raise SeatsError(f"{cmd} takes no arguments (see --help)")
        return
    if cmd == "wizard":
        if args not in ([], ["--yes"]):
            raise SeatsError("wizard accepts only --yes (see --help)")
        return
    if cmd == "set":
        if not args:
            raise SeatsError("set requires a seat")
        seat_from_arg(args[0])
        parse_opts(args[1:])
        return
    if cmd == "resolve":
        if len(args) != 1:
            raise SeatsError("resolve requires exactly one seat or route (see --help)")
        seat_from_arg(args[0])
        return
    if cmd == "model-info":
        if len(args) != 1 or not args[0]:
            raise SeatsError("model-info requires exactly one model id (see --help)")
        return
    if cmd == "conflict":
        if len(args) != 2:
            raise SeatsError("conflict requires exactly a seat and an effective model (see --help)")
        seat_from_arg(args[0])
        if not is_model(args[1]):
            raise SeatsError("conflict effective model must match the model grammar (see --help)")
        return


def ask(prompt, default=""):
    # input(prompt) sends the prompt to stderr on a TTY (CPython stdio readline);
    # write it ourselves so menu and prompt share stdout and `2>/dev/null` cannot hide it.
    sys.stdout.write(prompt)
    sys.stdout.flush()
    try:
        answer = input()
    except EOFError:
        out("")
        raise SeatsError("wizard aborted (end of input); nothing written")
    answer = answer.strip()
    return answer if answer else default


def pick_number(answer, options, what):
    """Enter -> None (keep). A number in range -> index. Anything else -> exit 1."""
    if not answer:
        return None
    if answer.isdigit() and 1 <= int(answer) <= len(options):
        return int(answer) - 1
    raise SeatsError(f"invalid {what} choice {answer!r}: enter a number 1-{len(options)} or press Enter; nothing written")


def interactive_wizard(doc):
    models = doc["catalog"]["models"]
    codex_models = [m for m in models if (model_spec(models, m) or {}).get("host") == "codex"]
    host_map = {"1": "claude", "2": "codex", "3": "gemini", "4": "cursor", "5": "windsurf"}
    for seat in SEAT_ORDER:
        entry = doc["seats"][seat]
        occ = entry["occupant"]
        out("")
        out(f"{entry['tag']} — {entry.get('duty') or SEAT_META[seat]['duty']} (phase {entry['phase']})")
        out(f"  suggestion: {occupant_text(occ)}")
        if seat == "owner":
            out("  @owner is always the human user.")
            continue
        out("  hosts: 1) claude  2) codex  3) gemini  4) cursor  5) windsurf   [Enter = keep suggestion]")
        choice = ask("  host> ")
        if choice and choice not in host_map:
            raise SeatsError(f"invalid host choice {choice!r}: enter a number 1-5 or press Enter; nothing written")
        if choice in host_map and host_map[choice] != occ.get("host"):
            new_host = host_map[choice]
            if new_host == "codex":
                if not codex_models:
                    raise SeatsError("the catalog has no codex model; add one to seats.json catalog first. Nothing written")
                default = DEFAULT_SEATS[seat]
                if default.get("host") == "codex" and default["model"] in models and default.get("fallback_model", default["model"]) in models:
                    occ = clone(default)
                else:
                    occ = {"host": "codex", "model": codex_models[0], "effort": (model_spec(models, codex_models[0]) or {}).get("default_effort")}
            else:
                occ = {"host": new_host}
            entry["occupant"] = occ
        if entry["occupant"].get("host") != "codex":
            continue
        occ = entry["occupant"]
        for i, m in enumerate(codex_models, 1):
            spec = model_spec(models, m) or {}
            out(f"    {i}) {m}  efforts: {', '.join(spec['efforts'])}  default: {spec['default_effort']}")
        pick = pick_number(ask(f"  model [{occ.get('model')}]> "), codex_models, "model")
        if pick is not None:
            m = codex_models[pick]
            if m != occ.get("model"):
                occ["model"] = m
                occ["effort"] = (model_spec(models, m) or {}).get("default_effort")
        eff = ask(f"  effort [{occ.get('effort')}]> ")
        if eff:
            occ["effort"] = eff
        fb = ask(f"  fallback model number, or 'none' [{occ.get('fallback_model') or 'none'}]> ")
        if fb == "none":
            occ.pop("fallback_model", None)
            occ.pop("fallback_effort", None)
        elif pick_number(fb, codex_models, "fallback model") is not None:
            m = codex_models[int(fb) - 1]
            if m != occ.get("fallback_model"):
                occ["fallback_model"] = m
                occ["fallback_effort"] = (model_spec(models, m) or {}).get("default_effort")
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


LOCK_FD = None


def lock_for_write(wait_seconds=10.0):
    """One writer at a time: set/wizard/init/reset/render read-modify-write
    seats.json and AGENTS.md. flock on the config directory itself (no lock
    file, so ownership never matters); bounded wait instead of blocking behind
    an interactive wizard; a filesystem without flock only costs a warning."""
    global LOCK_FD
    import fcntl
    import time
    try:
        SEATS_FILE.parent.mkdir(parents=True, exist_ok=True)
        LOCK_FD = os.open(str(SEATS_FILE.parent), os.O_RDONLY)
    except OSError as exc:
        raise SeatsError(f"cannot open {SEATS_FILE.parent} for locking: {exc}")
    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            fcntl.flock(LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise SeatsError(f"another agent-seats write is in progress on {SEATS_FILE.parent} (waited {wait_seconds:.0f}s); retry")
            time.sleep(0.05)
        except OSError as exc:  # e.g. ENOLCK/EOPNOTSUPP on a network filesystem
            warn(f"cannot lock {SEATS_FILE.parent} ({exc}); continuing without a lock")
            return


def main():
    validate_command_args()
    if cmd in ("set", "wizard", "reset", "render"):
        lock_for_write()
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
        def init_precheck(appeared):
            """True when a file is already there and valid. Raises on anything
            present but unusable. Only a 'missing' result may create the file,
            and the fast path and the post-lock recheck apply the same rules
            (gate attempt 3, F1: a file that appeared during the wait was
            overwritten with defaults and init still reported success)."""
            doc, error = read_json(SEATS_FILE)
            where = " (it appeared while waiting for the lock)" if appeared else ""
            if error is None:
                errors, _ = validate(doc)
                if errors:
                    report(errors, [])
                    raise SeatsError(f"existing seats.json is invalid{where}; init does not overwrite. Fix it by hand, repair the seat with set, or run reset")
                return True
            if error != "missing":
                raise SeatsError(f"{error}{where}; init does not overwrite. Run reset")
            return False

        # Read-only fast path: a present file never takes the lock and never
        # prompts, so generators and launchers can call init unconditionally.
        if init_precheck(False):
            out("agent-seats: seats.json present and valid; nothing written")
            return 0
        lock_for_write()
        if init_precheck(True):  # same rules under the lock
            out("agent-seats: seats.json appeared while waiting for the lock; nothing written")
            return 0
        doc = default_document()
        source, notes = "defaults", []
        if LEGACY.exists():
            source, notes = migrate_legacy(doc)
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
        if not errors:
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
        if structural_errors(doc):
            report(structural_errors(doc), [])
            raise SeatsError("seats.json is structurally invalid; run validate")
        spec = model_spec(doc.get("catalog", {}).get("models"), args[0])
        if spec is None:
            raise SeatsError(f"model {args[0]} is not in catalog.models; add it with scripts/agent-seats.sh (edit seats.json catalog) before launching")
        errors, _ = validate(doc)
        if errors:
            report(errors, [])
            raise SeatsError("seats.json is invalid; run validate")
        out(spec.get("host", ""))
        out(spec.get("default_effort", ""))
        out(" ".join(spec.get("efforts") or []))
        return 0
    if cmd == "conflict":
        seat = seat_from_arg(args[0])
        model = args[1]
        doc = load_current()
        errors, warnings = validate(doc)
        report(errors, warnings)
        if errors:
            raise SeatsError("seats.json is invalid; run validate")
        if seat != "build":
            out("0")
            return 0
        reviewer_models = set()
        for reviewer in ("gate", "verify"):
            occ = doc["seats"][reviewer]["occupant"]
            if occ.get("host") == "codex" and occ.get("model"):
                reviewer_models.add(occ["model"])
        if model in reviewer_models:
            note(f"@build effective model {model} is the primary model of @gate or @verify; the launch must carry policy_exception=gate_coding")
            out("1")
        else:
            out("0")
        return 0
    if cmd == "set":
        if not args:
            raise SeatsError("set requires a seat")
        seat = seat_from_arg(args[0])
        opts = parse_opts(args[1:])
        if read_json(SEATS_FILE)[1] == "missing":
            raise SeatsError(f"{SEATS_FILE} is missing; run scripts/agent-seats.sh init first (set never creates the file)")
        doc, source, notes = proposal(repairing=True)
        for n in notes:
            note(n)
        prev = doc["seats"][seat]["occupant"]
        host = opts.get("host") or prev.get("host")
        occ = {"host": host}
        if host not in LAUNCHABLE:
            inapplicable = [k for k in ("model", "effort", "fallback_model", "fallback_effort", "no_fallback") if k in opts]
            if inapplicable:
                raise SeatsError(f"host {host} is host-controlled; {', '.join('--' + k.replace('_', '-') for k in inapplicable)} do not apply; nothing written")
        if host in LAUNCHABLE:
            if "fallback_effort" in opts and not (opts.get("fallback_model") or prev.get("fallback_model")):
                raise SeatsError("--fallback-effort requires a fallback model; nothing written")
            models = doc["catalog"]["models"]
            occ["model"] = opts.get("model", prev.get("model"))
            if "effort" in opts:
                occ["effort"] = opts["effort"]
            elif prev.get("model") == occ["model"] and prev.get("effort"):
                occ["effort"] = prev["effort"]
            else:
                occ["effort"] = catalog_default_effort(models, occ["model"])
            if not opts.get("no_fallback"):
                fb = opts.get("fallback_model", prev.get("fallback_model"))
                if fb:
                    occ["fallback_model"] = fb
                    if "fallback_effort" in opts:
                        occ["fallback_effort"] = opts["fallback_effort"]
                    elif prev.get("fallback_model") == fb and prev.get("fallback_effort"):
                        occ["fallback_effort"] = prev["fallback_effort"]
                    else:
                        occ["fallback_effort"] = catalog_default_effort(models, fb)
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
except KeyboardInterrupt:
    if SAVED["seats"]:
        print("\nagent-seats: ERROR: interrupted after seats.json was written; the roster may be stale: run scripts/agent-seats.sh render", file=sys.stderr)
    else:
        print("\nagent-seats: ERROR: interrupted; nothing written", file=sys.stderr)
    sys.exit(130)
PY

cmd="${1:-}"
case "$cmd" in
  show|validate|suggest|wizard|set|init|reset|render|roster-block|resolve|model-info|conflict)
    python3 -c 'import sys' >/dev/null 2>&1 || fail "python3 is required (a working interpreter, not the macOS command-line-tools stub)"
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
