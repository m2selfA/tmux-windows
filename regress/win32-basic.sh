#!/bin/sh

# Windows-specific basic functionality tests.
# Tests ConPTY spawn, I/O, split windows, pane exit cleanup, session size,
# /dev/null config translation, Unix -S path warning, and default-shell guard.
# Must be run on Windows (Git Bash or similar).

PATH=${PATH:+$PATH:}/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
$TMUX kill-server 2>/dev/null

OUT=$(mktemp)
trap "rm -f $OUT; $TMUX kill-server 2>/dev/null" 0 1 15

# On Windows, -f/dev/null doesn't work (native exe can't open Unix path).
# Use NUL instead.
FNULL="-fNUL"

wait_for_file_contains() {
	FILE=$1
	TEXT=$2
	TRIES=0

	while [ "$TRIES" -lt 10 ]; do
		if [ -f "$FILE" ] && grep -q "$TEXT" "$FILE"; then
			return 0
		fi
		sleep 1
		TRIES=$((TRIES + 1))
	done
	return 1
}

shell_write_cmd() {
	NAME=$1
	TEXT=$2
	FILE=$3

	case "$NAME" in
	powershell|pwsh)
		printf "[System.IO.File]::WriteAllText('%s','%s')" "$FILE" "$TEXT"
		;;
	bash)
		printf "printf '%%s' '%s' > '%s'" "$TEXT" "$FILE"
		;;
	*)
		printf "echo %s > %s" "$TEXT" "$FILE"
		;;
	esac
}

helper_cmd_write() {
	TEXT=$1
	FILE=$2

	printf "if exist NUL (echo %s > %s)" "$TEXT" "$FILE"
}

test_shell_family() {
	NAME=$1
	SHELL_PATH=$2
	TMUXF="$TEST_TMUX -L$NAME"
	SESSION="${NAME}s"
	WORKDIR=$(mktemp -d)
	NEW_FILE="$WORKDIR/new.txt"
	DEF_FILE="$WORKDIR/default.txt"
	RUN_FILE="$WORKDIR/run.txt"
	EXEC_FILE="$WORKDIR/exec.txt"
	NEW_M=$(cygpath -m "$NEW_FILE")
	DEF_M=$(cygpath -m "$DEF_FILE")
	RUN_M=$(cygpath -m "$RUN_FILE")
	EXEC_M=$(cygpath -m "$EXEC_FILE")
	DEF_CMD=$(shell_write_cmd "$NAME" "${NAME}_default" "$DEF_M")
	NEW_CMD=$(shell_write_cmd "$NAME" "${NAME}_new" "$NEW_M")
	EXEC_CMD=$(shell_write_cmd "$NAME" "${NAME}_exec" "$EXEC_M")

	$TMUXF kill-server 2>/dev/null
	$TMUXF $FNULL new -d -s"$SESSION" < /dev/null || exit 1
	$TMUXF set-option -g default-shell "$SHELL_PATH" || exit 1
	sleep 1
	$TMUXF show-options -gqv default-shell | tr -d '\r' >$OUT
	printf '%s\n' "$SHELL_PATH" | cmp -s $OUT - || exit 1

	# Interactive shell stays alive.
	$TMUXF new-window -dt"$SESSION" || exit 1
	sleep 1
	$TMUXF list-panes -t"$SESSION":1 -F '#{pane_dead}' | tr -d '\r' >$OUT
	printf '0\n' | cmp -s $OUT - || exit 1

	# default-command follows the selected shell family.
	$TMUXF set-option -g default-command "$DEF_CMD" || exit 1
	$TMUXF new-window -dt"$SESSION" || exit 1
	wait_for_file_contains "$DEF_FILE" "${NAME}_default" || exit 1
	$TMUXF set-option -gu default-command

	# One-argument new-window shell command follows the selected shell family.
	$TMUXF new-window -dt"$SESSION" "$NEW_CMD" || exit 1
	wait_for_file_contains "$NEW_FILE" "${NAME}_new" || exit 1

	# tmux -c follows the selected default shell.
	$TMUXF -c "$EXEC_CMD" || exit 1
	wait_for_file_contains "$EXEC_FILE" "${NAME}_exec" || exit 1

	$TMUXF kill-server 2>/dev/null
	rm -rf "$WORKDIR"
}

test_helper_shell_uses_cmd() {
	NAME=$1
	SHELL_PATH=$2
	TMUXH="$TEST_TMUX -Lhelper_$NAME"
	SESSION="helper_${NAME}"
	IFVAR="IF_${NAME}"
	RUN_OUT=""

	$TMUXH kill-server 2>/dev/null
	$TMUXH $FNULL new -d -s"$SESSION" < /dev/null || exit 1
	$TMUXH set-option -g default-shell "$SHELL_PATH" || exit 1

	# Helper jobs must stay on cmd-compatible _PATH_BSHELL.
	RUN_OUT=$($TMUXH run-shell "echo %CMDEXTVERSION%" | tr -d '\r')
	printf '%s\n' "$RUN_OUT" | grep -Eq '^[0-9]+$' || exit 1
	$TMUXH if-shell "if 1==1 (exit 0) else (exit 1)" \
		"set-environment -g ${IFVAR} 1" \
		"set-environment -g ${IFVAR} 0" || exit 1
	$TMUXH show-environment -g "$IFVAR" | tr -d '\r' >$OUT
	printf '%s=1\n' "$IFVAR" | cmp -s $OUT - || exit 1

	$TMUXH kill-server 2>/dev/null
}

test_copy_pipe_eof() {
	TMUXC="$TEST_TMUX -Lcopyeof"
	TRIES=0
	JOBS=""

	$TMUXC kill-server 2>/dev/null
	$TMUXC $FNULL new -d -scopyeof < /dev/null || exit 1
	$TMUXC set-option -g default-shell "$BASH_SHELL" || exit 1
	$TMUXC new-window -dtcopyeof "printf 'zebra\n'; cat" || exit 1
	sleep 1

	$TMUXC copy-mode -tcopyeof:1.0 || exit 1
	$TMUXC send-keys -tcopyeof:1.0 -X history-top
	$TMUXC send-keys -tcopyeof:1.0 -X start-of-line
	$TMUXC send-keys -tcopyeof:1.0 -X select-line
	$TMUXC send-keys -tcopyeof:1.0 -X copy-pipe-and-cancel "sort" \
		|| exit 1

	while [ "$TRIES" -lt 10 ]; do
		JOBS=$($TMUXC show-messages -J | tr -d '\r')
		printf '%s\n' "$JOBS" | grep -q "sort" || break
		sleep 1
		TRIES=$((TRIES + 1))
	done
	printf '%s\n' "$JOBS" | grep -q "sort" && exit 1

	$TMUXC kill-server 2>/dev/null
}

# 1. Session lifecycle: new, ls, kill-session
$TMUX $FNULL new -d -sfoo < /dev/null || exit 1
$TMUX ls -F '#{session_name}' | tr -d '\r' >$OUT
printf "foo\n" | cmp -s $OUT - || exit 1
$TMUX kill-session -tfoo
$TMUX kill-server 2>/dev/null
sleep 1

# 2. Send-keys + capture-pane
$TMUX $FNULL new -d -sio < /dev/null || exit 1
sleep 1
$TMUX send-keys -tio "echo TMUX_TEST_OK" Enter
sleep 2
$TMUX capture-pane -tio -p | tr -d '\r' >$OUT
grep -q "TMUX_TEST_OK" $OUT || exit 1
$TMUX kill-server 2>/dev/null
sleep 1

# 3. Split-window + list-panes
$TMUX $FNULL new -d -ssplit < /dev/null || exit 1
sleep 1
$TMUX split-window -tsplit || exit 1
sleep 1
COUNT=$($TMUX list-panes -tsplit | wc -l)
[ "$COUNT" -eq 2 ] || exit 1
$TMUX kill-server 2>/dev/null
sleep 1

# 4. Pane exit cleanup (tests server_destroy_pane ConPTY path)
$TMUX $FNULL new -d -sexit < /dev/null || exit 1
sleep 1
$TMUX split-window -texit || exit 1
sleep 1
# Kill the second pane by sending exit
$TMUX send-keys -texit:0.1 "exit" Enter
sleep 3
COUNT=$($TMUX list-panes -texit | wc -l)
[ "$COUNT" -eq 1 ] || exit 1
$TMUX kill-server 2>/dev/null
sleep 1

# 5. Detached session size with explicit dimensions
$TMUX $FNULL new -d -x 120 -y 40 < /dev/null || exit 1
sleep 1
$TMUX ls -F "#{window_width} #{window_height}" | tr -d '\r' >$OUT
printf "120 40\n" | cmp -s $OUT - || exit 1
$TMUX kill-server 2>/dev/null
sleep 1

# 6. -f /dev/null translation: should work identically to -fNUL
$TMUX -f /dev/null new -d -snull < /dev/null || exit 1
$TMUX ls -F '#{session_name}' | tr -d '\r' >$OUT
printf "null\n" | cmp -s $OUT - || exit 1
$TMUX kill-server 2>/dev/null
sleep 1

# 7. -S with Unix path: should work as IPC label and emit warning
# MSYS_NO_PATHCONV prevents Git Bash from translating /tmp to C:/...
WARN=$(MSYS_NO_PATHCONV=1 $TEST_TMUX -S /tmp/unix-test-sock -fNUL new -d -sunix 2>&1)
echo "$WARN" | grep -qi "unix" || exit 1
MSYS_NO_PATHCONV=1 $TEST_TMUX -S /tmp/unix-test-sock ls -F '#{session_name}' | tr -d '\r' >$OUT
printf "unix\n" | cmp -s $OUT - || exit 1
MSYS_NO_PATHCONV=1 $TEST_TMUX -S /tmp/unix-test-sock kill-server 2>/dev/null
sleep 1

# 8. default-shell guard: Unix shell path falls back to cmd.exe
CFG=$(mktemp)
printf 'set -g default-shell /bin/bash\n' >$CFG
$TMUX -f "$CFG" new -d -sshell < /dev/null || exit 1
sleep 1
# Pane should still be alive (cmd.exe fallback worked)
COUNT=$($TMUX list-panes -tshell | wc -l)
[ "$COUNT" -eq 1 ] || exit 1
$TMUX kill-server 2>/dev/null
rm -f "$CFG"
sleep 1

# 9. Supported Windows shell families work across command flows
CMD_SHELL='C:/Windows/System32/cmd.exe'
POWERSHELL_SHELL='C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
BASH_SHELL=$(cygpath -m "$(type -P bash.exe)")

test_shell_family cmd "$CMD_SHELL"
test_shell_family powershell "$POWERSHELL_SHELL"
test_shell_family bash "$BASH_SHELL"
if command -v pwsh >/dev/null 2>&1; then
	PWSH_SHELL=$(cygpath -m "$(type -P pwsh.exe)")
	test_shell_family pwsh "$PWSH_SHELL"
fi

# 10. Helper jobs stay on cmd-compatible _PATH_BSHELL even with non-cmd default-shell
test_helper_shell_uses_cmd powershell "$POWERSHELL_SHELL"
test_helper_shell_uses_cmd bash "$BASH_SHELL"

# 11. copy-pipe jobs receive EOF and complete on Windows
test_copy_pipe_eof

# 12. Unsupported Windows executables are rejected as default shells
$TMUX $FNULL new -d -sreject < /dev/null || exit 1
if $TMUX set-option -g default-shell 'C:/Windows/System32/notepad.exe' \
	>/dev/null 2>&1; then
	exit 1
fi
$TMUX kill-server 2>/dev/null

# 13. SHELL with forward-slash Windows path seeds default-shell and new windows stay alive
SHELL=C:/Windows/System32/cmd.exe $TMUX $FNULL new -d -senvshell < /dev/null || exit 1
sleep 1
$TMUX show-options -gqv default-shell | tr -d '\r' >$OUT
grep -Eq '^C:[/\\]Windows[/\\]System32[/\\]cmd\.exe$' $OUT || exit 1
$TMUX new-window -tenvshell || exit 1
sleep 1
$TMUX list-panes -tenvshell:1 -F '#{pane_dead}' | tr -d '\r' >$OUT
printf '0\n' | cmp -s $OUT - || exit 1
$TMUX kill-server 2>/dev/null

exit 0
