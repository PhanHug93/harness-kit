#!/usr/bin/env bash
# Tests the one-shot entry script against a local "remote" (no network).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ENTRY="$ROOT/agent-bootstrap/harness-kit-one-shot.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
git_q() { git -c user.name=t -c user.email=t@t.invalid -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

V1=2099.01.01.1; V2=2099.01.02.1; VBAD=2099.01.01.0
REMOTE="$W/remote"; mkdir -p "$REMOTE"; git_q init -q "$REMOTE"
mkdir -p "$REMOTE/agent-bootstrap"
cp "$ROOT/agent-bootstrap/harness-kit-one-shot.sh" "$REMOTE/agent-bootstrap/"
cat > "$REMOTE/agent-bootstrap/harness-kit-run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
exit 0
STUB
release() { echo "$1" > "$REMOTE/agent-bootstrap/VERSION"; git_q -C "$REMOTE" add -A; git_q -C "$REMOTE" commit -q -m "$1"; git_q -C "$REMOTE" tag "$2"; }
release $V1 v$V1
release $V2 v$V2
echo "2099.09.09.9" > "$REMOTE/agent-bootstrap/VERSION"; git_q -C "$REMOTE" add -A; git_q -C "$REMOTE" commit -q -m bad; git_q -C "$REMOTE" tag v$VBAD
export STUB_OUT="$W/stub.out"

newproj() { local p="$W/$1"; mkdir -p "$p"; git_q init -q "$p"; echo "$p"; }
run() { bash "$ENTRY" "$@"; }
has_arg() { grep -qxF -- "$1" "$STUB_OUT" || fail "stub missing arg '$1': $(tr '\n' ' ' < "$STUB_OUT")"; }

# fresh project
P="$(newproj fresh)"
(cd "$P" && run --repo "$REMOTE" --to $V1 --plan) || fail "fresh run failed"
[ -f "$P/.harness-kit/v$V1/agent-bootstrap/VERSION" ] || fail "kit not fetched"
[ "$(grep -cxF '/.harness-kit/' "$P/.git/info/exclude")" = 1 ] || fail "harness-kit exclude not once"
[ "$(grep -cxF '/.tools/' "$P/.git/info/exclude")" = 1 ] || fail "tools exclude not once"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "status not clean"
has_arg --target; has_arg "$(cd "$P" && pwd -P)"; has_arg --kit-version; has_arg $V1; has_arg --plan

# rerun reuses
sum1="$(cd "$P/.harness-kit" && find . -type f | sort | xargs shasum | shasum)"
(cd "$P" && run --repo "$REMOTE" --to $V1 --plan) || fail "rerun failed"
sum2="$(cd "$P/.harness-kit" && find . -type f | sort | xargs shasum | shasum)"
[ "$sum1" = "$sum2" ] || fail "rerun changed files"
[ -z "$(ls -d "$P"/.harness-kit/.fetch-* 2>/dev/null)" ] || fail "temp dir left"
[ "$(grep -cxF '/.harness-kit/' "$P/.git/info/exclude")" = 1 ] || fail "exclude duplicated"

# latest
run --repo "$REMOTE" --target "$P" --to latest >/dev/null || fail "latest failed"
[ -d "$P/.harness-kit/v$V2/agent-bootstrap" ] || fail "latest did not pick $V2"
has_arg $V2

# old flags pass through
run --repo "$REMOTE" --target "$P" --to $V1 --no-branch --allow-dirty >/dev/null
has_arg --no-branch; has_arg --allow-dirty

# the old one-shot's --ref selects the version like --to (leading v accepted)
run --repo "$REMOTE" --target "$P" --ref "v$V1" >/dev/null || fail "--ref failed"
has_arg $V1

# VERSION mismatch
P="$(newproj mismatch)"
if run --repo "$REMOTE" --target "$P" --to $VBAD 2>"$W/err"; then fail "mismatch accepted"; fi
[ ! -e "$P/.harness-kit/v$VBAD" ] || fail "v dir left after mismatch"
[ -z "$(ls -d "$P"/.harness-kit/.fetch-* 2>/dev/null)" ] || fail "temp left after mismatch"

# failed fetch
if run --repo "$W/nonexistent" --target "$P" --to $V1 2>"$W/err"; then fail "bad repo accepted"; fi
[ ! -e "$P/.harness-kit/v$V1" ] || fail "v dir left after failed fetch"
[ -z "$(ls -d "$P"/.harness-kit/.fetch-* 2>/dev/null)" ] || fail "temp left after failed fetch"

# existing invalid v dir
mkdir -p "$P/.harness-kit/v$V1"
if run --repo "$REMOTE" --target "$P" --to $V1 2>"$W/err"; then fail "invalid dir accepted"; fi
grep -q "v$V1" "$W/err" || fail "refusal does not name the path"
[ -z "$(ls -A "$P/.harness-kit/v$V1")" ] || fail "invalid dir modified"

# symlinked .harness-kit
P="$(newproj symlink)"; mkdir "$W/elsewhere"; ln -s "$W/elsewhere" "$P/.harness-kit"
if run --repo "$REMOTE" --target "$P" --to $V1 2>/dev/null; then fail "symlink accepted"; fi

# non-git target
mkdir "$W/plain"
if run --repo "$REMOTE" --target "$W/plain" --to $V1 2>"$W/err"; then fail "non-git accepted"; fi
grep -qi "git work tree" "$W/err" || fail "non-git message unclear"
[ ! -e "$W/plain/.harness-kit" ] || fail "wrote into non-git dir"

# subdirectory target
P="$(newproj sub)"; mkdir -p "$P/apps/web"
run --repo "$REMOTE" --target "$P/apps/web" --to $V1 >/dev/null || fail "subdir failed"
grep -qxF '/apps/web/.harness-kit/' "$P/.git/info/exclude" || fail "prefixed harness-kit exclude missing"
grep -qxF '/apps/web/.tools/' "$P/.git/info/exclude" || fail "prefixed tools exclude missing"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "subdir status not clean"

# --source-dir offline
P="$(newproj offline)"; SRC="$W/srcdir"; mkdir -p "$SRC"; cp -R "$REMOTE/agent-bootstrap" "$SRC/"
run --source-dir "$SRC" --repo "$W/nonexistent" --target "$P" --to latest >/dev/null || fail "source-dir failed"
[ -f "$P/.harness-kit/v2099.09.09.9/agent-bootstrap/VERSION" ] || fail "source-dir latest used wrong version"
echo "$V1" > "$SRC/agent-bootstrap/VERSION"
run --source-dir "$SRC" --target "$P" --to $V1 >/dev/null || fail "source-dir explicit failed"

# old-name copy identical
cmp -s "$ROOT/agent-bootstrap/harness-kit-one-shot.sh" "$ROOT/agent-bootstrap/harness-kit-one-shot-upgrade.sh" || fail "entry files differ"
echo "ok: harness-kit entry"
