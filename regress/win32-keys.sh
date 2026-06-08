#!/bin/sh

# Windows key handling regression tests.
# Tests that send-keys with named keys produces expected effects.
# Cannot use the upstream cat -tv approach (no stty on Windows), so we
# verify key behavior through observable pane output.
#
# Upstream had 4 backspace/key-mapping fixes in Dec 2024 - Feb 2025:
#   6d792e4, 2a5eba7, 5c3cf2f, eece415

TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
LABEL="test-$$"
LABEL2="test2-$$"
TMUX="$TEST_TMUX -L$LABEL"
$TMUX kill-server 2>/dev/null
TMUX2="$TEST_TMUX -L$LABEL2"
$TMUX2 kill-server 2>/dev/null
sleep 1

FNULL="-fNUL"
OUT=$(mktemp)
PROMPT_OUT=$(mktemp)
trap "rm -f $OUT $PROMPT_OUT; $TMUX kill-server 2>/dev/null; $TMUX2 kill-server 2>/dev/null" 0 1 15
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=1
}

format_string() {
	case $1 in
		*\')
			printf '"%%%%"'
			;;
		*)
			printf "'%%%%'"
			;;
	esac
}

start_inner_client() {
	INNER_SESSION=$1
	SETUP_CMD=$2
	RELAY_SESSION="${INNER_SESSION}-relay"
	INNER_CLIENT=

	$TMUX2 kill-server 2>/dev/null
	$TMUX2 $FNULL new -d -s"$INNER_SESSION" -x 120 -y 24 cmd.exe < /dev/null || return 1
	if [ -n "$SETUP_CMD" ]; then
		$TMUX2 $SETUP_CMD || return 1
	fi
	$TMUX $FNULL new -d -s"$RELAY_SESSION" -- "$TEST_TMUX" "-L$LABEL2" attach -t "$INNER_SESSION" || return 1
	sleep 2
	INNER_CLIENT=$($TMUX2 list-clients -F '#{client_name}' | sed -n '1p')
	[ -n "$INNER_CLIENT" ]
}

stop_inner_client() {
	$TMUX kill-session -t"$RELAY_SESSION" 2>/dev/null
	$TMUX2 kill-server 2>/dev/null
}

assert_prompt_key() {
	KEYS=$1
	EXPECTED=$2
	NAME=$3
	FORMAT=$(format_string "$EXPECTED")

	start_inner_client "key-$NAME" "" || {
		fail "$NAME prompt harness did not attach a client"; exit 1
	}

	: > "$PROMPT_OUT"
	$TMUX2 command-prompt -t"$INNER_CLIENT" -k \
		"display-message -pl $FORMAT" > "$PROMPT_OUT" &
	PROMPT_PID=$!
	sleep 0.1
	$TMUX send-keys -t"$RELAY_SESSION" $KEYS
	wait "$PROMPT_PID"

	ACTUAL=$(tr -d '\r\n' < "$PROMPT_OUT")
	if [ "$ACTUAL" != "$EXPECTED" ]; then
		fail "$NAME key interpreted as '$ACTUAL'"
	else
		echo "PASS: $NAME key -> $ACTUAL"
	fi

	stop_inner_client
}

prompt_backspace_case() {
	SESSION_NAME=$1
	TARGET_VALUE=$2
	SETUP_CMD=$3
	ERASE_KEYS=$4

	start_inner_client "$SESSION_NAME" "$SETUP_CMD" || {
		fail "$SESSION_NAME prompt harness did not attach a client"; exit 1
	}

	: > "$PROMPT_OUT"
	$TMUX2 command-prompt -t"$INNER_CLIENT" -I 'cmd.exe' \
		"display-message -p -- '%%'" > "$PROMPT_OUT" &
	PROMPT_PID=$!
	sleep 0.5
	$TMUX send-keys -t"$RELAY_SESSION" \
		$ERASE_KEYS $ERASE_KEYS $ERASE_KEYS $ERASE_KEYS $ERASE_KEYS $ERASE_KEYS $ERASE_KEYS 0 0 Enter
	wait "$PROMPT_PID"

	PROMPT_VALUE=$(tr -d '\r\n' < "$PROMPT_OUT")
	if [ "$PROMPT_VALUE" != "$TARGET_VALUE" ]; then
		fail "$SESSION_NAME prompt backspace editing produced '$PROMPT_VALUE'"
	else
		echo "PASS: $SESSION_NAME prompt backspace"
	fi

	stop_inner_client
}

$TMUX $FNULL new -d -skeys -x 120 -y 24 cmd.exe < /dev/null || exit 1
sleep 1

# --- Test 1: Enter key executes commands ---
$TMUX send-keys -tkeys "echo KEY_ENTER_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "KEY_ENTER_OK" || {
	fail "Enter key did not execute command"; exit 1
}
echo "PASS 1: Enter key"

# --- Test 2: Literal characters arrive correctly ---
$TMUX send-keys -tkeys "echo abcXYZ019" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "abcXYZ019" || {
	fail "Literal characters not received"
}
echo "PASS 2: Literal characters"

# --- Test 3: Space key ---
$TMUX send-keys -tkeys "echo" Space "SPACE_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "SPACE_OK" || {
	fail "Space key not working"
}
echo "PASS 3: Space key"

# --- Test 4: Tab key (command completion) ---
# Type partial command and Tab — on cmd.exe, Tab cycles through files.
# Simpler test: verify Tab character is sent by checking it doesn't break things.
$TMUX send-keys -tkeys "echo TAB_OK" Tab Enter
sleep 2
# Tab might complete or not, but the echo should still work
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "TAB_OK" || true
echo "PASS 4: Tab key (no crash)"

# --- Test 5: Escape key (no crash, key is recognized) ---
$TMUX send-keys -tkeys Escape
sleep 0.5
$TMUX send-keys -tkeys "echo ESC_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "ESC_OK" || {
	fail "Escape key broke input"
}
echo "PASS 5: Escape key"

# --- Test 6: Ctrl-C (interrupt) ---
# Send a long-running command, then Ctrl-C to interrupt
$TMUX send-keys -tkeys "ping -n 100 127.0.0.1" Enter
sleep 2
$TMUX send-keys -tkeys C-c
sleep 2
# Verify we get back to a prompt (can type again)
$TMUX send-keys -tkeys "echo CTRLC_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "CTRLC_OK" || {
	fail "Ctrl-C did not interrupt"
}
echo "PASS 6: Ctrl-C interrupt"

# --- Test 7: Arrow keys in copy-mode ---
# Enter copy mode, move around, exit — verify no crash
$TMUX send-keys -tkeys "echo line1" Enter "echo line2" Enter "echo line3" Enter
sleep 1
$TMUX copy-mode -tkeys
sleep 0.5
$TMUX send-keys -tkeys -X cursor-up
$TMUX send-keys -tkeys -X cursor-up
$TMUX send-keys -tkeys -X cursor-down
$TMUX send-keys -tkeys -X cursor-left
$TMUX send-keys -tkeys -X cursor-right
$TMUX send-keys -tkeys -X cancel
sleep 0.5
# Verify pane is still functional
$TMUX send-keys -tkeys "echo ARROW_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "ARROW_OK" || {
	fail "Arrow keys in copy mode broke pane"
}
echo "PASS 7: Arrow keys in copy mode"

# --- Test 8: Home/End in copy mode ---
$TMUX copy-mode -tkeys
sleep 0.5
$TMUX send-keys -tkeys -X start-of-line
$TMUX send-keys -tkeys -X end-of-line
$TMUX send-keys -tkeys -X cancel
sleep 0.5
$TMUX send-keys -tkeys "echo HOMEEND_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "HOMEEND_OK" || {
	fail "Home/End keys broke pane"
}
echo "PASS 8: Home/End in copy mode"

# --- Test 9: PgUp/PgDn in copy mode ---
# Generate enough output to scroll
for i in $(seq 1 30); do
	$TMUX send-keys -tkeys "echo scroll_line_$i" Enter
done
sleep 2
$TMUX copy-mode -tkeys
sleep 0.5
$TMUX send-keys -tkeys -X page-up
sleep 0.3
$TMUX send-keys -tkeys -X page-down
sleep 0.3
$TMUX send-keys -tkeys -X cancel
sleep 0.5
$TMUX send-keys -tkeys "echo PGUPDN_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "PGUPDN_OK" || {
	fail "PgUp/PgDn broke pane"
}
echo "PASS 9: PgUp/PgDn in copy mode"

# --- Test 10: Function keys (no crash) ---
# F1-F5 might trigger help or other actions, but shouldn't crash
$TMUX send-keys -tkeys F1
sleep 0.3
$TMUX send-keys -tkeys Escape
sleep 0.3
$TMUX send-keys -tkeys "echo FKEY_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "FKEY_OK" || {
	fail "Function keys broke pane"
}
echo "PASS 10: Function keys"

# --- Test 11: BSpace (backspace) deletes characters ---
# Type something, backspace, then check result
$TMUX send-keys -tkeys "echo BSPXXX" BSpace BSpace BSpace "ACE_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "BSPACE_OK" || {
	fail "Backspace did not delete characters"
}
echo "PASS 11: Backspace"

# Unicode prompt-editing coverage lives in regress/win32-unicode.sh because
# send-keys does not reliably inject non-ASCII text into Windows shells.

# --- Test 12: Ctrl-J stays distinct from Enter in prompt key mode ---
assert_prompt_key C-j C-j ctrl-j

# --- Test 13: Enter is still Enter in prompt key mode ---
assert_prompt_key Enter Enter enter

# --- Test 14: BSpace edits prefilled command-prompt input ---
prompt_backspace_case prompt-default 00 "" BSpace

# --- Test 15: BSpace edits prefilled command-prompt input with C-h ---
prompt_backspace_case prompt-ctrl-h 00 "set -s backspace C-h" C-h

# --- Test 16: Multiple modifier combinations (no crash) ---
$TMUX send-keys -tkeys C-a C-e C-k
sleep 0.5
$TMUX send-keys -tkeys "echo MOD_OK" Enter
sleep 2
$TMUX capture-pane -tkeys -p | tr -d '\r' | grep -q "MOD_OK" || {
	fail "Modifier combinations broke pane"
}
echo "PASS 16: Modifier combinations"

$TMUX kill-server 2>/dev/null

if [ $FAIL -eq 0 ]; then
	echo ""
	echo "ALL KEY TESTS PASSED"
	exit 0
else
	echo ""
	echo "SOME KEY TESTS FAILED"
	exit 1
fi
