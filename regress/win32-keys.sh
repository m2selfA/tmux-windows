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

start_keys_session() {
	KEYS_SESSION=$1

	$TMUX kill-session -t"$KEYS_SESSION" 2>/dev/null
	$TMUX $FNULL new -d -s"$KEYS_SESSION" -x 120 -y 24 cmd.exe < /dev/null || return 1
	sleep 1
}

stop_keys_session() {
	$TMUX kill-session -t"$1" 2>/dev/null
}

wait_for_pane_text() {
	KEYS_SESSION=$1
	PATTERN=$2
	COUNT=0

	while [ $COUNT -lt 20 ]; do
		if $TMUX capture-pane -t"$KEYS_SESSION" -p | tr -d '\r' | grep -q "$PATTERN"; then
			return 0
		fi
		sleep 0.5
		COUNT=$((COUNT + 1))
	done
	return 1
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

# --- Test 1: Enter key executes commands ---
start_keys_session keys-enter || {
	fail "Enter key harness did not start"; exit 1
}
$TMUX send-keys -tkeys-enter "echo KEY_ENTER_OK" Enter
if wait_for_pane_text keys-enter "KEY_ENTER_OK"; then
	echo "PASS 1: Enter key"
else
	fail "Enter key did not execute command"
fi
stop_keys_session keys-enter

# --- Test 2: Literal characters arrive correctly ---
start_keys_session keys-literal || {
	fail "Literal characters harness did not start"; exit 1
}
$TMUX send-keys -tkeys-literal "echo abcXYZ019" Enter
if wait_for_pane_text keys-literal "abcXYZ019"; then
	echo "PASS 2: Literal characters"
else
	fail "Literal characters not received"
fi
stop_keys_session keys-literal

# --- Test 3: Space key ---
start_keys_session keys-space || {
	fail "Space key harness did not start"; exit 1
}
$TMUX send-keys -tkeys-space "echo" Space "SPACE_OK" Enter
if wait_for_pane_text keys-space "SPACE_OK"; then
	echo "PASS 3: Space key"
else
	fail "Space key not working"
fi
stop_keys_session keys-space

# --- Test 4: Tab key (command completion) ---
start_keys_session keys-tab || {
	fail "Tab key harness did not start"; exit 1
}
$TMUX send-keys -tkeys-tab Tab
sleep 0.5
$TMUX send-keys -tkeys-tab C-c
sleep 0.5
$TMUX send-keys -tkeys-tab "echo TAB_OK" Enter
if wait_for_pane_text keys-tab "TAB_OK"; then
	echo "PASS 4: Tab key (no crash)"
else
	fail "Tab key broke input"
fi
stop_keys_session keys-tab

# --- Test 5: Escape key (no crash, key is recognized) ---
start_keys_session keys-escape || {
	fail "Escape key harness did not start"; exit 1
}
$TMUX send-keys -tkeys-escape Escape
sleep 0.5
$TMUX send-keys -tkeys-escape "echo ESC_OK" Enter
if wait_for_pane_text keys-escape "ESC_OK"; then
	echo "PASS 5: Escape key"
else
	fail "Escape key broke input"
fi
stop_keys_session keys-escape

# --- Test 6: Ctrl-C (interrupt) ---
start_keys_session keys-ctrlc || {
	fail "Ctrl-C harness did not start"; exit 1
}
$TMUX send-keys -tkeys-ctrlc "ping -n 100 127.0.0.1" Enter
sleep 2
$TMUX send-keys -tkeys-ctrlc C-c
sleep 0.5
$TMUX send-keys -tkeys-ctrlc "echo CTRLC_OK" Enter
if wait_for_pane_text keys-ctrlc "CTRLC_OK"; then
	echo "PASS 6: Ctrl-C interrupt"
else
	fail "Ctrl-C did not interrupt"
fi
stop_keys_session keys-ctrlc

# --- Test 7: Arrow keys in copy-mode ---
start_keys_session keys-arrow || {
	fail "Arrow keys harness did not start"; exit 1
}
$TMUX send-keys -tkeys-arrow "echo line1" Enter "echo line2" Enter "echo line3" Enter
sleep 1
$TMUX copy-mode -tkeys-arrow
sleep 0.5
$TMUX send-keys -tkeys-arrow -X cursor-up
$TMUX send-keys -tkeys-arrow -X cursor-up
$TMUX send-keys -tkeys-arrow -X cursor-down
$TMUX send-keys -tkeys-arrow -X cursor-left
$TMUX send-keys -tkeys-arrow -X cursor-right
$TMUX send-keys -tkeys-arrow -X cancel
sleep 0.5
$TMUX send-keys -tkeys-arrow "echo ARROW_OK" Enter
if wait_for_pane_text keys-arrow "ARROW_OK"; then
	echo "PASS 7: Arrow keys in copy mode"
else
	fail "Arrow keys in copy mode broke pane"
fi
stop_keys_session keys-arrow

# --- Test 8: Home/End in copy mode ---
start_keys_session keys-homeend || {
	fail "Home/End harness did not start"; exit 1
}
$TMUX send-keys -tkeys-homeend "echo line1" Enter
sleep 1
$TMUX copy-mode -tkeys-homeend
sleep 0.5
$TMUX send-keys -tkeys-homeend -X start-of-line
$TMUX send-keys -tkeys-homeend -X end-of-line
$TMUX send-keys -tkeys-homeend -X cancel
sleep 0.5
$TMUX send-keys -tkeys-homeend "echo HOMEEND_OK" Enter
if wait_for_pane_text keys-homeend "HOMEEND_OK"; then
	echo "PASS 8: Home/End in copy mode"
else
	fail "Home/End keys broke pane"
fi
stop_keys_session keys-homeend

# --- Test 9: PgUp/PgDn in copy mode ---
start_keys_session keys-pgupdn || {
	fail "PgUp/PgDn harness did not start"; exit 1
}
for i in $(seq 1 30); do
	$TMUX send-keys -tkeys-pgupdn "echo scroll_line_$i" Enter
done
sleep 1
$TMUX copy-mode -tkeys-pgupdn
sleep 0.5
$TMUX send-keys -tkeys-pgupdn -X page-up
sleep 0.3
$TMUX send-keys -tkeys-pgupdn -X page-down
sleep 0.3
$TMUX send-keys -tkeys-pgupdn -X cancel
sleep 0.5
$TMUX send-keys -tkeys-pgupdn "echo PGUPDN_OK" Enter
if wait_for_pane_text keys-pgupdn "PGUPDN_OK"; then
	echo "PASS 9: PgUp/PgDn in copy mode"
else
	fail "PgUp/PgDn broke pane"
fi
stop_keys_session keys-pgupdn

# --- Test 10: Function keys (no crash) ---
start_keys_session keys-fkey || {
	fail "Function keys harness did not start"; exit 1
}
$TMUX send-keys -tkeys-fkey F1
sleep 0.3
$TMUX send-keys -tkeys-fkey Escape
sleep 0.3
$TMUX send-keys -tkeys-fkey "echo FKEY_OK" Enter
if wait_for_pane_text keys-fkey "FKEY_OK"; then
	echo "PASS 10: Function keys"
else
	fail "Function keys broke pane"
fi
stop_keys_session keys-fkey

# --- Test 11: BSpace (backspace) deletes characters ---
start_keys_session keys-bspace || {
	fail "Backspace harness did not start"; exit 1
}
$TMUX send-keys -tkeys-bspace "echo BSPXXX" BSpace BSpace BSpace "ACE_OK" Enter
if wait_for_pane_text keys-bspace "BSPACE_OK"; then
	echo "PASS 11: Backspace"
else
	fail "Backspace did not delete characters"
fi
stop_keys_session keys-bspace

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
start_keys_session keys-mod || {
	fail "Modifier combinations harness did not start"; exit 1
}
$TMUX send-keys -tkeys-mod C-a C-e C-k
sleep 0.5
$TMUX send-keys -tkeys-mod "echo MOD_OK" Enter
if wait_for_pane_text keys-mod "MOD_OK"; then
	echo "PASS 16: Modifier combinations"
else
	fail "Modifier combinations broke pane"
fi
stop_keys_session keys-mod

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
