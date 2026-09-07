#!/usr/bin/env bash
# Seat B probe set. usage: probes.sh <script-to-test>   (runs on /tmp/council/targets/seatB/t)
set -u
SCRIPT_UNDER_TEST=$1
source /tmp/council/targets/seatB/lib.sh
cp "$SCRIPT_UNDER_TEST" "$S"; chmod +x "$S"; chmod -R a+rwX "$T"; restore
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }
rc_of() { bash "$S" "$@" >/tmp/council/targets/seatB/.o 2>/tmp/council/targets/seatB/.e; echo $?; }
expect_rc() { local name=$1 want=$2; shift 2; local got; got=$(rc_of "$@"); if [ "$got" = "$want" ] && ! grep -q Traceback /tmp/council/targets/seatB/.e; then ok "$name"; else bad "$name" "rc=$got want=$want $(grep -c Traceback /tmp/council/targets/seatB/.e) traceback(s)"; fi; }
fmt() { python3 -c "import json;json.dump(json.load(open('$F')),open('$F','w'),indent=4)"; }
wiz() { python3 /tmp/council/targets/seatB/ptywiz.py "$T" "$@" 2>&1 | head -1; }

# R2 family (validate must be rc 1, resolve never != 8 lines)
mut 'd["catalog"]["models"]["custom\n"]={"host":"codex","efforts":["high"],"default_effort":"high"}; d["seats"]["gate"]["occupant"]={"host":"codex","model":"custom\n","effort":"high"}'; expect_rc "R2a model LF" 1 validate
mut 'd["catalog"]["models"]["gpt-6-astra"]["efforts"].append("high\n"); d["seats"]["gate"]["occupant"]["effort"]="high\n"'; expect_rc "R2b effort LF" 1 validate
mut 'd["seats"]["gate"]["occupant"]={"host":"claude","model":"info\nmodel"}'; expect_rc "R2c informational model LF" 1 validate
mut 'o=d["seats"]["gate"]["occupant"]; o.pop("fallback_model"); o["fallback_effort"]="high\nxhigh"'; expect_rc "R2d orphan fallback_effort" 1 validate
mut 'd["seats"]["spec"]["occupant"]={"host":"claude","effort":"a\nb","fallback_model":"x y","fallback_effort":"Q\n"}'; expect_rc "R2e non-codex effort/fallback fields" 1 validate
restore; n=$(bash "$S" resolve gate | wc -l); [ "$n" = 8 ] && ok "resolve baseline 8 lines" || bad "resolve baseline" "$n lines"
# R3 / wizard (PTY)
restore; fmt; r=$(wiz 99); case "$r" in "rc=1 prompts=1 "*"changed=False") ok "R3a host 99";; *) bad "R3a host 99" "$r";; esac
restore; fmt; r=$(wiz "" "" 99); case "$r" in "rc=1 prompts=3 "*"changed=False") ok "R3b model 99";; *) bad "R3b model 99" "$r";; esac
restore; fmt; r=$(wiz "" "" "" "" 99); case "$r" in "rc=1 prompts=5 "*"changed=False") ok "R3c fallback 99";; *) bad "R3c fallback 99" "$r";; esac
restore; fmt; r=$(wiz "" "" "" "" gpt-5.6-luna); case "$r" in "rc=1 "*"changed=False") ok "R3d fallback by name";; *) bad "R3d fallback by name" "$r";; esac
restore; fmt; r=$(wiz --eof-at 0); case "$r" in "rc=1 "*"changed=False") ok "F7 Ctrl-D aborts, nothing written";; *) bad "F7 Ctrl-D" "$r";; esac
mut 'for s in d["seats"].values(): s.pop("duty",None)'; fmt; r=$(wiz ""); case "$r" in "rc=0 prompts=17 "*) ok "F6 no duty key";; *) bad "F6 no duty" "$r";; esac
mut 'd["catalog"]["models"]={"m1":{"host":"claude","efforts":["x"],"default_effort":"x"}}
for s in ("gate","build","verify"): d["seats"][s]["occupant"]={"host":"claude"}'; fmt; r=$(wiz 2); case "$r" in "rc=1 "*"changed=False") ok "F8a no codex model -> clean rc 1";; *) bad "F8a no codex model" "$r";; esac
mut 'del d["catalog"]["models"]["gpt-6-astra"]
for s in ("gate","verify"): d["seats"][s]["occupant"]={"host":"claude"}'; fmt; r=$(wiz "" 2 "" "" "" ""); case "$r" in "rc=0 "*) ok "F8b default absent -> catalog seed";; *) bad "F8b default absent" "$r";; esac
# R4 / F1 / F9 file handling
restore; chmod 444 AGENTS.md; B=$(sha "$F"); su nobody -s /bin/bash -c "cd $T && bash scripts/agent-seats.sh set build --effort high" >/dev/null 2>/tmp/council/targets/seatB/.e; got=$?; chmod 644 AGENTS.md
if [ $got = 2 ] && grep -q "NOT rendered" /tmp/council/targets/seatB/.e && ! grep -q Traceback /tmp/council/targets/seatB/.e && [ "$(sha "$F")" != "$B" ]; then ok "R4 read-only AGENTS.md -> rc 2 + message"; else bad "R4" "rc=$got"; fi
restore; A=$(sha AGENTS.md); ( ulimit -f 4; bash "$S" set build --effort high ) >/dev/null 2>/tmp/council/targets/seatB/.e; got=$?
if [ $got = 2 ] && [ "$(sha AGENTS.md)" = "$A" ] && grep -q "NOT rendered" /tmp/council/targets/seatB/.e; then ok "F1a failed render write: AGENTS.md intact, rc 2"; else bad "F1a" "rc=$got intact=$([ "$(sha AGENTS.md)" = "$A" ] && echo y || echo n)"; fi
restore; B=$(sha "$F"); ( ulimit -f 1; bash "$S" set build --effort high ) >/dev/null 2>/tmp/council/targets/seatB/.e; got=$?
if [ $got = 1 ] && [ "$(sha "$F")" = "$B" ] && ! grep -q Traceback /tmp/council/targets/seatB/.e; then ok "F1b failed seats write: intact, rc 1, no traceback"; else bad "F1b" "rc=$got"; fi
restore; lost=0; for i in $(seq 1 20); do restore; bash "$S" set spec --host gemini >/dev/null 2>&1 & p1=$!; bash "$S" set audit --host cursor >/dev/null 2>&1 & p2=$!; wait $p1; r1=$?; wait $p2; r2=$?; r=$(python3 -c "import json;d=json.load(open('$F'))['seats'];print(d['spec']['occupant']['host'],d['audit']['occupant']['host'])" 2>/dev/null); { [ $r1 -ne 0 ] || [ $r2 -ne 0 ] || [ "$r" != "gemini cursor" ]; } && lost=$((lost+1)); done 2>/dev/null; [ $lost = 0 ] && ok "F2 concurrent set x20: no lost update / torn read" || bad "F2 concurrent" "$lost/20 bad"
# F3 structural
mut 'd["catalog"]=["x"]'; expect_rc "F3a catalog list" 1 validate
mut 'd["seats"]["gate"]="x"'; expect_rc "F3b seat string" 1 validate
mut 'd["seats"]["gate"]["occupant"]=[]'; expect_rc "F3c occupant list" 1 validate
mut 'd["seats"]["gate"]["occupant"]=None'; expect_rc "F3d occupant null" 1 validate
printf '[]\n' > "$F"; expect_rc "F3e top-level list show" 1 show; expect_rc "F3f top-level list model-info" 1 model-info gpt-6-astra; expect_rc "F3g top-level list conflict" 1 conflict build x
mut 'del d["seats"]["verify"]'; expect_rc "F3h missing seat show" 1 show; mut 'del d["seats"]["gate"]'; expect_rc "F3i missing seat conflict" 1 conflict build x
# F4 set options
restore; B=$(sha "$F"); expect_rc "F4a typo option" 1 set build --efort high; expect_rc "F4b --model on claude seat" 1 set spec --host claude --model gpt-6-astra
expect_rc "F4c --no-fallback + --fallback-model" 1 set gate --no-fallback --fallback-model gpt-5.6-luna; expect_rc "F4d --host=x form" 1 set gate --host=claude --no-fallback; expect_rc "F4e empty --host" 1 set gate --host ""
bash "$S" set gate --no-fallback >/dev/null 2>&1; expect_rc "F4f orphan --fallback-effort" 1 set gate --fallback-effort max; restore
[ "$(sha "$F")" = "$B" ] && ok "F4 file unchanged after rejected sets" || bad "F4 file changed" ""
# F5 repair
mut 'd["seats"]["gate"]["occupant"]["effort"]="turbo"'; expect_rc "F5 set repairs invalid seat" 0 set gate --effort ultra; expect_rc "F5 validate after repair" 0 validate
# F9/F10 misc
restore; mv AGENTS.md AGENTS.md.bak; mkdir AGENTS.md; rc_of render >/dev/null; grep -q "not a regular file" /tmp/council/targets/seatB/.e && ok "F9a directory message" || bad "F9a" "$(cat /tmp/council/targets/seatB/.e)"; rmdir AGENTS.md; mv AGENTS.md.bak AGENTS.md
rm -f "$F"; mkdir "$F"; expect_rc "F9b seats.json directory reset" 1 reset; rmdir "$F"; restore
mut 'd["catalog"]["models"]["gpt-6-astra"]["efforts"]=["ultra","ultra","high"]'; expect_rc "F10a duplicate efforts (warning)" 0 validate
python3 -c "open('$F','wb').write(b'\xef\xbb\xbf'+open('$BASE','rb').read())"; expect_rc "F10b BOM accepted" 0 validate
# self-critique cases (round 2)
restore; mv AGENTS.md real.md; ln -s real.md AGENTS.md; bash "$S" set build --effort high >/dev/null 2>&1; got=$?; if [ $got = 0 ] && [ -L AGENTS.md ] && grep -q '@ high' real.md; then ok "S1 symlinked AGENTS.md written through, link kept"; else bad "S1 symlink" "rc=$got link=$([ -L AGENTS.md ] && echo y || echo n)"; fi; rm -f AGENTS.md; mv real.md AGENTS.md; restore
mv "$F" "$T/real-seats.json"; ln -s ../../real-seats.json "$F"; bash "$S" set build --effort high >/dev/null 2>&1; got=$?; if [ $got = 0 ] && [ -L "$F" ] && grep -q '"high"' "$T/real-seats.json"; then ok "S2 symlinked seats.json written through, link kept"; else bad "S2 symlink seats" "rc=$got"; fi; rm -f "$F"; mv "$T/real-seats.json" "$F"; restore
chmod 666 AGENTS.md "$F"; touch "$T/docs/agent-configs/.seats.json.lock"; chmod 644 "$T/docs/agent-configs/.seats.json.lock"; su nobody -s /bin/bash -c "cd $T && bash scripts/agent-seats.sh set build --effort high" >/dev/null 2>/tmp/council/targets/seatB/.e; got=$?; [ $got = 0 ] && ok "S3 other user's stale lock file does not block" || bad "S3 lock ownership" "rc=$got $(grep ERROR /tmp/council/targets/seatB/.e | head -1)"; rm -f "$T/docs/agent-configs/.seats.json.lock"; restore
fmt; python3 - <<'PYEOF' &
import os, pty, subprocess, time
T="/tmp/council/targets/seatB/t"; m,s=pty.openpty(); p=subprocess.Popen(["bash",T+"/scripts/agent-seats.sh","wizard"],cwd=T,stdin=s,stdout=s,stderr=s); os.close(s); time.sleep(14); p.kill(); p.wait(); os.close(m)
PYEOF
sleep 1; timeout 13 bash "$S" set audit --host gemini >/dev/null 2>/tmp/council/targets/seatB/.e; got=$?; wait; if [ $got = 1 ] && grep -q "in progress" /tmp/council/targets/seatB/.e; then ok "S4 wizard at prompt: concurrent set fails fast with rc 1 (bounded wait)"; else bad "S4 lock wait" "rc=$got $(tail -1 /tmp/council/targets/seatB/.e)"; fi; restore
# regression guards
restore; expect_rc "baseline validate" 0 validate; expect_rc "baseline set" 0 set build --effort high; expect_rc "baseline resolve alias" 0 resolve planning; expect_rc "baseline conflict" 0 conflict build gpt-6-astra
restore; rm -f "$T/docs/agent-configs/.seats.json.lock"
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
