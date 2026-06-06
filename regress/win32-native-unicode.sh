#!/bin/sh

PATH=/bin:/usr/bin
TERM=screen

[ -z "$TEST_TMUX" ] && TEST_TMUX=$(readlink -f ../tmux)
TMUX="$TEST_TMUX -Ltest"
FNULL="-fNUL"
POWERSHELL=/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
OUT=$(mktemp)
trap "rm -f $OUT; $TMUX kill-server 2>/dev/null" 0 1 15

fail() {
	echo "FAIL: $1"
	exit 1
}

capture_first_line() {
	$TMUX capture-pane -tnative:0.0 -p | tr -d '\r' | sed -n '1p' >"$OUT"
}

assert_first_line() {
	expected=$1

	if ! LC_ALL=C grep -Fqx "$expected" "$OUT"; then
		echo "Expected: $expected"
		echo "Actual:"
		cat "$OUT"
		fail "$2"
	fi
}

encode_command() {
	cmd=$1
	"$POWERSHELL" -NoLogo -NoProfile -Command \
		"\$cmd = '$cmd'; [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(\$cmd))" |
		tr -d '\r\n'
}

run_case() {
	encoded=$1

	$TMUX kill-server 2>/dev/null
	$TMUX $FNULL new-session -d -snative -- \
		C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
		-NoLogo -NoProfile -EncodedCommand "$encoded" || exit 1
	sleep 2
	capture_first_line
}

ONE_BS_CMD='[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; [Console]::Write(([string]([char]0x4F60)+[char]0x597D)); [Console]::Write("`bX"); Start-Sleep -Seconds 9999'
TWO_BS_CMD='[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; [Console]::Write(([string]([char]0x4F60)+[char]0x597D)); [Console]::Write("`b`bX"); Start-Sleep -Seconds 9999'
EXPECTED="$(printf '\344\275\240X')"

run_case "$(encode_command "$ONE_BS_CMD")"
assert_first_line "$EXPECTED" "native PowerShell one-backspace rewrite left a gap"
echo "PASS 1: native PowerShell one-backspace rewrite"

run_case "$(encode_command "$TWO_BS_CMD")"
assert_first_line "$EXPECTED" "native PowerShell two-backspace rewrite left a gap"
echo "PASS 2: native PowerShell two-backspace rewrite"

exit 0
