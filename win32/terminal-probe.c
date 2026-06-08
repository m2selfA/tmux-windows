#include <windows.h>

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void
usage(void)
{
	fprintf(stderr,
	    "usage: win32-terminal-probe --out PATH --bytes N "
	    "[--timeout-ms N] [--enable-bracket-paste] "
	    "[--enable-extended-keys] [--raw-vt-input] "
	    "[--count-only]\n");
}

static int
parse_u32(const char *value, DWORD *out)
{
	char *end;
	unsigned long parsed;

	errno = 0;
	parsed = strtoul(value, &end, 10);
	if (errno != 0 || *value == '\0' || *end != '\0' || parsed > 0xffffffffUL)
		return (-1);
	*out = (DWORD)parsed;
	return (0);
}

static int
write_hex_file(const char *path, const unsigned char *buf, DWORD len)
{
	FILE *fp;
	DWORD i;

	fp = fopen(path, "wb");
	if (fp == NULL)
		return (-1);
	for (i = 0; i < len; i++) {
		if (i != 0 && fputc(' ', fp) == EOF) {
			fclose(fp);
			return (-1);
		}
		if (fprintf(fp, "%02x", buf[i]) < 0) {
			fclose(fp);
			return (-1);
		}
	}
	if (fclose(fp) != 0)
		return (-1);
	return (0);
}

static int
write_count_file(const char *path, DWORD len)
{
	FILE *fp;

	fp = fopen(path, "wb");
	if (fp == NULL)
		return (-1);
	if (fprintf(fp, "%lu", (unsigned long)len) < 0) {
		fclose(fp);
		return (-1);
	}
	if (fclose(fp) != 0)
		return (-1);
	return (0);
}

struct reader_state {
	HANDLE		 hinput;
	unsigned char	*buf;
	DWORD		 requested;
	DWORD		 total;
};

static DWORD WINAPI
reader_thread(LPVOID data)
{
	struct reader_state *state = data;
	DWORD got, chunk;

	while (state->total < state->requested) {
		chunk = state->requested - state->total;
		if (!ReadFile(state->hinput, state->buf + state->total, chunk, &got,
		    NULL) || got == 0)
			break;
		state->total += got;
	}
	return (0);
}

int
main(int argc, char **argv)
{
	static const char bracketed_paste[] = "\033[?2004h";
	static const char extended_keys[] = "\033[>4;2m";
	const char *out_path = NULL;
	HANDLE hinput, houtput, thread = NULL;
	DWORD requested = 0, timeout_ms = 3000, original_mode = 0, new_mode;
	DWORD got, wait_result;
	unsigned char *buf = NULL;
	struct reader_state state;
	int enable_bracket = 0, enable_extkeys = 0, raw_vt_input = 0;
	int count_only = 0;
	int have_original_mode = 0;
	int i, status = 1;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--out") == 0) {
			if (++i >= argc) {
				usage();
				return (2);
			}
			out_path = argv[i];
		} else if (strcmp(argv[i], "--bytes") == 0) {
			if (++i >= argc || parse_u32(argv[i], &requested) != 0) {
				usage();
				return (2);
			}
		} else if (strcmp(argv[i], "--timeout-ms") == 0) {
			if (++i >= argc || parse_u32(argv[i], &timeout_ms) != 0) {
				usage();
				return (2);
			}
		} else if (strcmp(argv[i], "--enable-bracket-paste") == 0) {
			enable_bracket = 1;
		} else if (strcmp(argv[i], "--enable-extended-keys") == 0) {
			enable_extkeys = 1;
		} else if (strcmp(argv[i], "--raw-vt-input") == 0) {
			raw_vt_input = 1;
		} else if (strcmp(argv[i], "--count-only") == 0) {
			count_only = 1;
		} else {
			usage();
			return (2);
		}
	}

	if (out_path == NULL || requested == 0) {
		usage();
		return (2);
	}

	hinput = GetStdHandle(STD_INPUT_HANDLE);
	houtput = GetStdHandle(STD_OUTPUT_HANDLE);
	if (hinput == INVALID_HANDLE_VALUE || houtput == INVALID_HANDLE_VALUE)
		goto out;

	if (raw_vt_input && GetConsoleMode(hinput, &original_mode)) {
		have_original_mode = 1;
		new_mode = original_mode | ENABLE_VIRTUAL_TERMINAL_INPUT;
		new_mode &= ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT |
		    ENABLE_ECHO_INPUT);
		SetConsoleMode(hinput, new_mode);
	}

	if (enable_bracket) {
		if (!WriteFile(houtput, bracketed_paste,
		    (DWORD)(sizeof bracketed_paste - 1), &got, NULL))
			goto restore;
	}
	if (enable_extkeys) {
		if (!WriteFile(houtput, extended_keys,
		    (DWORD)(sizeof extended_keys - 1), &got, NULL))
			goto restore;
	}

	buf = calloc(requested, 1);
	if (buf == NULL)
		goto restore;

	memset(&state, 0, sizeof state);
	state.hinput = hinput;
	state.buf = buf;
	state.requested = requested;
	thread = CreateThread(NULL, 0, reader_thread, &state, 0, NULL);
	if (thread == NULL)
		goto restore;
	wait_result = WaitForSingleObject(thread, timeout_ms);
	if (wait_result == WAIT_TIMEOUT) {
		CancelSynchronousIo(thread);
		WaitForSingleObject(thread, INFINITE);
	}

	if ((!count_only && write_hex_file(out_path, buf, state.total) != 0) ||
	    (count_only && write_count_file(out_path, state.total) != 0))
		goto restore;
	status = 0;

restore:
	if (thread != NULL)
		CloseHandle(thread);
	if (have_original_mode)
		SetConsoleMode(hinput, original_mode);
out:
	free(buf);
	return (status);
}
