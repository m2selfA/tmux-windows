#!/bin/sh

# Windows pane-facing terminal semantics regression tests.
# Verifies bracketed paste markers and payload delivery to child processes.

TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
LABEL="terms-$$"
LABEL2="terms2-$$"
TMUX="$TEST_TMUX -L$LABEL"
$TMUX kill-server 2>/dev/null
TMUX2="$TEST_TMUX -L$LABEL2"
$TMUX2 kill-server 2>/dev/null
sleep 1

FNULL="-fNUL"
OUT=$(mktemp)
TEST_DIR=$(dirname "$TEST_TMUX")
PROBE="$TEST_DIR/win32-terminal-probe.exe"
trap "rm -f $OUT; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" 0 1 15
FAIL=0
DIRECT_SESSION=
INNER_CLIENT=

if [ ! -x "$PROBE" ]; then
	echo "FAIL: win32-terminal-probe.exe not found"
	exit 1
fi

fail() {
	echo "FAIL: $1"
	FAIL=1
}

start_direct_probe() {
	DIRECT_SESSION=$1
	shift

	: > "$OUT"
	$TMUX kill-session -t"$DIRECT_SESSION" 2>/dev/null
	$TMUX $FNULL set -g remain-on-exit on \; \
		new -d -s"$DIRECT_SESSION" -x 120 -y 24 -- "$@" || return 1
	sleep 1
}

stop_direct_probe() {
	$TMUX kill-session -t"$DIRECT_SESSION" 2>/dev/null
}

start_inner_probe() {
	SESSION_NAME=$1
	RELAY_SESSION="${SESSION_NAME}-relay"
	shift

	: > "$OUT"
	INNER_CLIENT=
	$TMUX2 kill-server 2>/dev/null
	$TMUX2 $FNULL set -g remain-on-exit on \; \
		new -d -s"$SESSION_NAME" -x 120 -y 24 -- "$@" || return 1
	$TMUX $FNULL new -d -s"$RELAY_SESSION" -- \
		"$TEST_TMUX" "-L$LABEL2" attach -t "$SESSION_NAME" || return 1
	ATTACHED=0
	COUNT=0
	while [ $COUNT -lt 10 ]; do
		INNER_CLIENT=$($TMUX2 list-clients -F '#{client_name}' | sed -n '1p')
		if [ -n "$INNER_CLIENT" ]; then
			ATTACHED=1
			break
		fi
		sleep 1
		COUNT=$((COUNT + 1))
	done
	[ $ATTACHED -eq 1 ] || return 1
	sleep 1
}

stop_inner_probe() {
	$TMUX kill-session -t"$RELAY_SESSION" 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
}

send_bracketed_paste() {
	$TMUX send-keys -t"$RELAY_SESSION" Escape '[' '2' '0' '0' '~'
	$TMUX send-keys -t"$RELAY_SESSION" -l -- 'hel'
	$TMUX send-keys -t"$RELAY_SESSION" -l -- 'lo'
	$TMUX send-keys -t"$RELAY_SESSION" Escape '[' '2' '0' '1' '~'
}

# --- Test 1: Pane-facing Ctrl-J stays LF ---
start_direct_probe key-ctrl-j \
	"$PROBE" --out "$OUT" --bytes 1 --timeout-ms 3000 --raw-vt-input || exit 1
	$TMUX send-keys -t"$DIRECT_SESSION" C-j
	sleep 3
	if [ "$(tr -d '\r\n' < "$OUT")" != "0a" ]; then
		fail "pane Ctrl-J was not delivered as LF"
	else
		echo "PASS 1: pane Ctrl-J stays LF"
	fi
stop_direct_probe

# --- Test 2: Pane-facing Enter stays CR ---
start_direct_probe key-enter \
	"$PROBE" --out "$OUT" --bytes 1 --timeout-ms 3000 --raw-vt-input || exit 1
	$TMUX send-keys -t"$DIRECT_SESSION" Enter
	sleep 3
	if [ "$(tr -d '\r\n' < "$OUT")" != "0d" ]; then
		fail "pane Enter was not delivered as CR"
	else
		echo "PASS 2: pane Enter stays CR"
	fi
stop_direct_probe

# --- Test 3: Without bracketed paste mode, pane only receives payload ---
start_inner_probe paste-plain \
	"$PROBE" --out "$OUT" --bytes 5 --timeout-ms 5000 --raw-vt-input || exit 1
	send_bracketed_paste
	sleep 3
	if [ "$(tr -d '\r\n' < "$OUT")" != "68 65 6c 6c 6f" ]; then
		fail "plain paste probe did not receive payload only"
	else
		echo "PASS 3: plain paste strips markers"
	fi
stop_inner_probe

# --- Test 4: With bracketed paste mode, pane receives markers and chunked payload ---
start_inner_probe paste-bracket \
	"$PROBE" --out "$OUT" --bytes 17 --timeout-ms 5000 \
		--raw-vt-input --enable-bracket-paste || exit 1
	send_bracketed_paste
	sleep 3
	if [ "$(tr -d '\r\n' < "$OUT")" != "1b 5b 32 30 30 7e 68 65 6c 6c 6f 1b 5b 32 30 31 7e" ]; then
		fail "bracketed paste probe did not receive full transaction"
	else
		echo "PASS 4: bracketed paste preserves markers and chunked payload"
	fi
stop_inner_probe

# --- Test 5: Bracket paste delimiters clear transient key tables ---
start_inner_probe paste-prefix-reset \
	"$PROBE" --out "$OUT" --bytes 18 --timeout-ms 5000 \
		--raw-vt-input --enable-bracket-paste || exit 1
	$TMUX2 switch-client -t"$INNER_CLIENT" -T prefix || {
		fail "prefix-reset probe did not expose an attached client"
		stop_inner_probe
		exit 1
	}
	send_bracketed_paste
	$TMUX send-keys -t"$RELAY_SESSION" -l -- 'c'
	sleep 3
	if [ "$(tr -d '\r\n' < "$OUT")" != "1b 5b 32 30 30 7e 68 65 6c 6c 6f 1b 5b 32 30 31 7e 63" ]; then
		fail "bracket paste did not reset the client key table"
	elif [ "$($TMUX2 list-windows | wc -l | tr -d ' ')" != "1" ]; then
		fail "bracket paste left prefix table active and opened a new window"
	else
		echo "PASS 5: bracket paste clears transient key tables"
	fi
stop_inner_probe

# --- Test 6: Large pane input is delivered completely ---
PAYLOAD_DATA=$(yes x | tr -d '\n' | head -c 5000)
start_direct_probe bulk-input \
	"$PROBE" --out "$OUT" --bytes 5000 --timeout-ms 10000 \
		--raw-vt-input --count-only || exit 1
	$TMUX set-buffer -b bulk-input "$PAYLOAD_DATA" || exit 1
	$TMUX paste-buffer -b bulk-input -d -t"$DIRECT_SESSION"
	sleep 5
	if [ "$(tr -d '\r\n' < "$OUT")" != "5000" ]; then
		fail "large pane input was truncated before reaching the child process"
	else
		echo "PASS 6: large pane input is delivered completely"
	fi
stop_direct_probe

$TMUX kill-server 2>/dev/null
$TMUX2 kill-server 2>/dev/null

if [ $FAIL -eq 0 ]; then
	echo ""
	echo "ALL TERMINAL SEMANTICS TESTS PASSED"
	exit 0
else
	echo ""
	echo "SOME TERMINAL SEMANTICS TESTS FAILED"
	exit 1
fi
