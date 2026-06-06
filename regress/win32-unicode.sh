#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
FNULL="-fNUL"
SPAWN_SH=$(cygpath -w "$(command -v sh)")
OUT=$(mktemp)
SCRIPT=$(mktemp)
trap "rm -f $OUT $SCRIPT; $TMUX kill-server 2>/dev/null" 0 1 15

assert_line() {
	line=$1

	if ! LC_ALL=C grep -Fqx "$line" "$OUT"; then
		echo "FAIL: missing line: $line"
		exit 1
	fi
}

cat >"$SCRIPT" <<'EOF'
printf '\033[H\033[J'
printf '\033[3;1H\316\233\033[3;1H\314\2120\n'
printf '\033[4;1H\316\233\033[4;2H\314\2121\n'
printf '\033[5;1H👍\033[5;1H🏻2\n'
printf '\033[6;1H👍\033[6;3H🏻3\n'
printf '\033[7;1H👍\033[7;10H👍\033[7;3H🏻\033[7;12H🏻4\n'
printf '\033[8;1H\360\237\244\267\342\200\215\342\231\202\357\270\2175\n'
printf '\033[9;1H\360\237\244\267\033[9;1H\342\200\215\342\231\202\357\270\2176\n'
printf '\033[9;1H\360\237\244\267\033[9;1H\342\200\215\342\231\202\357\270\2177\n'
printf '\033[10;1H\360\237\244\267\033[10;3H\342\200\215\342\231\202\357\270\2178\n'
printf '\033[11;1H\360\237\244\267\033[11;3H\342\200\215\033[11;3H\342\231\202\357\270\2179\n'
printf '\033[12;1H\360\237\244\267\033[12;3H\342\200\215\342\231\202\357\270\21710\n'
printf '\033[13;1H\360\237\207\25211\n'
printf '\033[14;1H\360\237\207\270\360\237\207\25212\n'
printf '\033[15;1H\360\237\207\270  \010\010\360\237\207\25213\n'
printf '\033[16;1H\344\275\240\345\245\275\033[16;3H X14\n'
EOF

$TMUX kill-server 2>/dev/null

$TMUX $FNULL \
	set -g remain-on-exit on \; \
	set -g remain-on-exit-format '' \; \
	new-session -d -sunicode -- "$SPAWN_SH" "$SCRIPT" || exit 1
sleep 2

$TMUX capture-pane -tunicode -p | tr -d '\r' >"$OUT"

assert_line "0"
assert_line "$(printf '\316\233\314\2121')"
assert_line "$(printf '\360\237\217\2732')"
assert_line "$(printf '\360\237\221\215\360\237\217\2733')"
assert_line "$(printf '\360\237\244\267\342\200\215\342\231\202\357\270\2175')"
assert_line "$(printf '\342\231\202\357\270\2177')"
assert_line "$(printf '\360\237\244\267\342\200\215\342\231\202\357\270\2178')"
assert_line "$(printf '\360\237\244\267\342\200\215\342\231\202\357\270\21710')"
assert_line "$(printf '\360\237\207\25211')"
assert_line "$(printf '\360\237\207\270\360\237\207\25212')"
assert_line "$(printf '\360\237\207\270\360\237\207\25213')"
assert_line "$(printf '\344\275\240 X14')"

$TMUX kill-server 2>/dev/null
exit 0
