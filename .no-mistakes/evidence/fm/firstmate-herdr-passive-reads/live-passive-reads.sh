#!/usr/bin/env bash
# Live proof: fm_backend_herdr_capture is passive on an idle fullscreen Claude
# Code pane, the old text recent read harvests, the guard refuses the text
# shape before herdr, and primary-screen captures match the old text read.
set -u
ROOT=${ROOT:?}
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name passive-reads)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-passive-reads.XXXXXX")
FAKEBIN=$TMP_ROOT/fakebin; mkdir -p "$FAKEBIN"
CALLLOG=$TMP_ROOT/herdr-calls.log; : > "$CALLLOG"
echo "session: $SESSION"
cleanup() { local rc=$?; trap - EXIT; PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && echo "teardown: ok"; rm -rf "$TMP_ROOT"; exit $rc; }
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused" >&2; exit 97; }
args=("\${args[@]:0:\$((n-2))}")
printf '%s\n' "\${args[*]}" >> "$CALLLOG"
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || exit 1
export PATH="$FAKEBIN:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
idle_wait() { local i=0 st; while [ $i -lt ${2:-90} ]; do st=$(lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty'); case "$st" in idle|done) return 0;; esac; i=$((i+1)); sleep 1; done; return 1; }
RESULT=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; RESULT=1; }

# ---------- Scenario: primary-screen shell pane ----------
WS=$(lab workspace create --cwd "$TMP_ROOT" --label fm-passive-prim --no-focus) || exit 1
PP=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
lab pane run "$PP" "for i in \$(seq 1 300); do printf '\\033[1;3%dmrow %03d\\033[0m  tail\\t \\n' \$((i%7)) \$i; done; printf '\\033[44m   \\033[0m\\n\\n'" >/dev/null
sleep 3
for n in 5 40 250; do
  newcap=$(fm_backend_herdr_capture "$SESSION:$PP" "$n"); rc=$?
  old=$(lab pane read "$PP" --source recent --lines $([ $n -ge 200 ] && echo $n || echo 200) | tail -n "$n")
  printf '%s' "$newcap" > "$TMP_ROOT/new-$n"; printf '%s' "$old" > "$TMP_ROOT/old-$n"
  lines=$(printf '%s\n' "$newcap" | wc -l)
  if [ $rc = 0 ] && cmp -s "$TMP_ROOT/new-$n" "$TMP_ROOT/old-$n" && ! grep -q $'\r\|\e' "$TMP_ROOT/new-$n"; then
    ok "primary-screen capture N=$n: $lines lines, no CR/ESC, byte-identical to text-format recent read (sha $(sha256sum < "$TMP_ROOT/new-$n" | cut -c1-12))"
  else bad "primary-screen capture N=$n differs from text read (rc=$rc)"; diff <(cat -A "$TMP_ROOT/old-$n") <(cat -A "$TMP_ROOT/new-$n") | head -20; fi
done
echo "--- primary capture N=5 (cat -A) ---"; printf '%s\n' "$(fm_backend_herdr_capture "$SESSION:$PP" 5)" | cat -A

# ---------- Scenario: guard ----------
: > "$CALLLOG"
for form in "pane read $PP" "pane read $PP --source recent --lines 200" "pane read $PP --source=recent-unwrapped" "agent read $PP" "agent read $PP --format text --source recent" "pane read $PP --format=text"; do
  # shellcheck disable=SC2086
  err=$(fm_backend_herdr_cli "$SESSION" $form 2>&1 >/dev/null); rc=$?
  if [ $rc = 2 ] && printf '%s' "$err" | grep -q "refusing 'herdr"; then ok "guard refused: herdr $form (rc=2)"; else bad "guard did not refuse: $form rc=$rc"; fi
done
if [ ! -s "$CALLLOG" ]; then ok "no refused read reached herdr (call log empty)"; else bad "refused reads reached herdr:"; cat "$CALLLOG"; fi
echo "refusal message: $err"
for form in "pane read $PP --source recent --lines 200 --format ansi" "pane read $PP --source visible" "pane read $PP --source detection" "pane read $PP --ansi" "pane read $PP --raw" "agent read $PP --source visible"; do
  # shellcheck disable=SC2086
  out=$(fm_backend_herdr_cli "$SESSION" $form 2>/dev/null); rc=$?
  if [ $rc = 0 ] && [ -n "$out" ]; then ok "guard allowed: herdr $form"; else bad "guard blocked allowed form: $form rc=$rc"; fi
done

# ---------- Scenario: fullscreen Claude Code ----------
WS2=$(lab workspace create --cwd "$TMP_ROOT" --label fm-passive-cc --no-focus) || exit 1
CP=$(printf '%s' "$WS2" | jq -er '.result.root_pane.pane_id')
lab pane run "$CP" "env -u XDG_CONFIG_HOME CLAUDE_CODE_NO_FLICKER=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
trusted=0; ready=0
for i in $(seq 1 60); do
  scr=$(lab pane read "$CP" --source visible 2>/dev/null)
  case "$scr" in
    *'Yes, I trust this folder'*) [ $trusted = 0 ] && { trusted=1; lab pane send-keys "$CP" down enter >/dev/null; } ;;
    *'bypass permissions on'*) idle_wait "$CP" 5 && { ready=1; break; } ;;
  esac
  sleep 1
done
[ $ready = 1 ] || { bad "Claude never reached idle composer"; lab pane read "$CP" --source visible; exit 1; }
lab pane send-text "$CP" "Print the integers 1 through 150, one per line, as plain text with no code block and no other words." >/dev/null
sleep 0.5; lab pane send-keys "$CP" enter >/dev/null
sleep 5; idle_wait "$CP" 120 || bad "Claude did not return to idle"
sleep 3
echo "agent: $(lab agent get "$CP" | jq -c '.result.agent | {agent,agent_status}')"
VIS=$(lab pane read "$CP" --source visible); VROWS=$(printf '%s\n' "$VIS" | wc -l)
echo "visible viewport rows (text, trimmed): $VROWS"

sampler() { # <outfile> <seconds>
  local end=$(( $(date +%s%N) + $2*1000000000 ))
  while [ "$(date +%s%N)" -lt $end ]; do lab pane read "$CP" --source visible | sha256sum | cut -c1-16 >> "$1"; done
}
# new adapter capture x5 with concurrent viewport sampler
sampler "$TMP_ROOT/s-new" 8 & SP=$!
sleep 1
for k in 1 2 3 4 5; do fm_backend_herdr_capture "$SESSION:$CP" 200 > "$TMP_ROOT/cap-$k"; sleep 0.8; done
wait $SP
NEWDISTINCT=$(sort -u "$TMP_ROOT/s-new" | wc -l); NEWSAMPLES=$(wc -l < "$TMP_ROOT/s-new")
CAPROWS=$(wc -l < "$TMP_ROOT/cap-1"); CAPDISTINCT=$(cat "$TMP_ROOT"/cap-* | md5sum >/dev/null; for k in 1 2 3 4 5; do sha256sum < "$TMP_ROOT/cap-$k"; done | sort -u | wc -l)
echo "NEW capture: rows=$CAPROWS distinct-captures=$CAPDISTINCT; viewport samples=$NEWSAMPLES distinct=$NEWDISTINCT"
grep -q $'\r\|\e' "$TMP_ROOT/cap-1" && bad "capture has CR/ESC" || ok "fullscreen capture has no CR/ESC"
[ "$NEWDISTINCT" = 1 ] && ok "viewport never moved during 5 adapter captures ($NEWSAMPLES samples, 1 distinct)" || bad "viewport changed during adapter captures ($NEWDISTINCT distinct)"
cmp -s <(printf '%s\n' "$VIS") "$TMP_ROOT/cap-1" && ok "fullscreen capture equals the visible viewport text" || { echo "(capture vs visible diff)"; diff <(printf '%s\n' "$VIS") "$TMP_ROOT/cap-1" | head; }
echo "--- capture tail (cat -A, last 8) ---"; tail -n 8 "$TMP_ROOT/cap-1" | cat -A

# old shape (base commit): text recent read, x3, with sampler
sampler "$TMP_ROOT/s-old" 8 & SP=$!
sleep 1
for k in 1 2 3; do lab pane read "$CP" --source recent --lines 200 > "$TMP_ROOT/old-cc-$k"; sleep 1.5; done
wait $SP
OLDDISTINCT=$(sort -u "$TMP_ROOT/s-old" | wc -l); OLDSAMPLES=$(wc -l < "$TMP_ROOT/s-old")
OLDROWS=$(wc -l < "$TMP_ROOT/old-cc-1")
echo "OLD text read: rows=$OLDROWS (viewport $VROWS); viewport samples=$OLDSAMPLES distinct=$OLDDISTINCT"
echo "old read contains early integers: $(grep -cxE '\s*[0-9]{1,2}' "$TMP_ROOT/old-cc-1") short-number rows; new capture: $(grep -cxE '\s*[0-9]{1,2}' "$TMP_ROOT/cap-1")"
exit $RESULT
