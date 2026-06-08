/*
 * ConPTY wrapper for Windows.
 * Creates pseudo-consoles and spawns child processes with them.
 * Bridges ConPTY pipe output to a socket for libevent integration.
 */

#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "win32-platform.h"

struct win32_pty {
	HPCON    hPC;        /* ConPTY handle */
	HANDLE   hPipeIn;    /* Write end: input to PTY */
	HANDLE   hPipeOut;   /* Read end: output from PTY */
	HANDLE   hProcess;   /* Child process handle */
	HANDLE   hThread;    /* Child main thread handle */
	HANDLE   process_thread; /* Waits for child exit and closes PTY pipes */
	DWORD    dwProcessId;
	SOCKET   sock;       /* Socket FD for libevent (read end of bridge) */
	SOCKET   bridge_peer;/* Write end of bridge socket pair */
	HANDLE   bridge_thread; /* Thread: hPipeOut -> bridge_peer (output) */
	HANDLE   input_thread;  /* Thread: bridge_peer -> hPipeIn (input) */
	volatile int closing;
};

static void
close_handle_once(HANDLE *handle)
{
	HANDLE h;

	h = (HANDLE)InterlockedExchangePointer((PVOID volatile *)handle, NULL);
	if (h != NULL && h != INVALID_HANDLE_VALUE)
		CloseHandle(h);
}

static void
close_pseudoconsole_once(HPCON *hpc)
{
	HPCON h;

	h = (HPCON)InterlockedExchangePointer((PVOID volatile *)hpc, NULL);
	if (h != NULL)
		ClosePseudoConsole(h);
}

static void
close_socket_once(SOCKET *sock)
{
	SOCKET s;

	s = (SOCKET)(UINT_PTR)InterlockedExchangePointer(
	    (PVOID volatile *)sock, (PVOID)(UINT_PTR)INVALID_SOCKET);
	if (s != INVALID_SOCKET)
		closesocket(s);
}

static int
pty_socket_send_all(SOCKET sock, const char *buf, size_t len)
{
	fd_set		 wfds;
	struct timeval	 tv;
	size_t		 off = 0;
	int		 n, err, ready;

	while (off < len) {
		n = send(sock, buf + off, (int)(len - off), 0);
		if (n > 0) {
			off += (size_t)n;
			continue;
		}
		if (n == 0)
			return (-1);

		err = WSAGetLastError();
		if (err != WSAEWOULDBLOCK && err != WSAENOBUFS)
			return (-1);

		FD_ZERO(&wfds);
		FD_SET(sock, &wfds);
		tv.tv_sec = 0;
		tv.tv_usec = 100000;
		ready = select(0, NULL, &wfds, NULL, &tv);
		if (ready == SOCKET_ERROR)
			return (-1);
	}
	return (0);
}

static int
pty_handle_write_all(HANDLE h, const char *buf, size_t len)
{
	DWORD	 written, chunk;
	size_t	 off = 0;

	while (off < len) {
		if (len - off > 0xffffffffUL)
			chunk = 0xffffffffUL;
		else
			chunk = (DWORD)(len - off);
		if (!WriteFile(h, buf + off, chunk, &written, NULL) ||
		    written == 0)
			return (-1);
		off += written;
	}
	return (0);
}

/* Output bridge: reads from ConPTY pipe, sends to socket (child -> server). */
static DWORD WINAPI
pty_bridge_thread(LPVOID arg)
{
	struct win32_pty *pty = (struct win32_pty *)arg;
	char buf[4096];
	DWORD n;

	while (!pty->closing) {
		if (!ReadFile(pty->hPipeOut, buf, sizeof buf, &n, NULL))
			break;
		if (n == 0)
			break;
		/* Write to bridge socket so libevent can pick it up. */
		if (pty_socket_send_all(pty->bridge_peer, buf, n) != 0)
			break;
	}

	/* Signal EOF by closing the socket. */
	close_socket_once(&pty->bridge_peer);
	return 0;
}

/* Input bridge: reads from socket, writes to ConPTY pipe (server -> child). */
static DWORD WINAPI
pty_input_thread(LPVOID arg)
{
	struct win32_pty *pty = (struct win32_pty *)arg;
	char buf[4096];
	int n;
	int saw_input = 0;

	while (!pty->closing) {
		n = recv(pty->bridge_peer, buf, sizeof buf, 0);
		if (n <= 0)
			break;
		saw_input = 1;
		if (pty_handle_write_all(pty->hPipeIn, buf, (size_t)n) != 0)
			break;
	}
	/*
	 * ConPTY-backed shell helpers can fail during startup if stdin is
	 * closed immediately before the child has finished attaching. Only
	 * delay EOF for jobs that never received any input.
	 */
	if (!pty->closing && !saw_input)
		Sleep(100);
	close_handle_once(&pty->hPipeIn);
	return 0;
}

static DWORD WINAPI
pty_process_thread(LPVOID arg)
{
	struct win32_pty *pty = (struct win32_pty *)arg;
	DWORD		 available = 0;
	int		 tries;

	if (pty->hProcess != NULL)
		WaitForSingleObject(pty->hProcess, INFINITE);
	if (!pty->closing) {
		for (tries = 0; tries < 20; tries++) {
			if (pty->hPipeOut == NULL ||
			    !PeekNamedPipe(pty->hPipeOut, NULL, 0, NULL,
			    &available, NULL) || available == 0)
				break;
			Sleep(10);
		}
		close_pseudoconsole_once(&pty->hPC);
		close_handle_once(&pty->hPipeIn);
		close_socket_once(&pty->bridge_peer);
		if (pty->hPipeOut != NULL)
			CancelIoEx(pty->hPipeOut, NULL);
		if (pty->bridge_thread != NULL)
			CancelSynchronousIo(pty->bridge_thread);
	}
	return 0;
}

struct win32_pty *
win32_pty_spawn(const char *cmd, const char *cwd, char *env,
    int cols, int rows, pid_t *out_pid)
{
	struct win32_pty *pty;
	HANDLE pipeIn_read = NULL, pipeIn_write = NULL;
	HANDLE pipeOut_read = NULL, pipeOut_write = NULL;
	HRESULT hr;
	COORD size;
	STARTUPINFOEXW si;
	PROCESS_INFORMATION pi;
	SIZE_T attrSize = 0;
	int sv[2];
	wchar_t wcmd[32768];
	wchar_t wcwd[MAX_PATH];

	pty = calloc(1, sizeof *pty);
	if (pty == NULL)
		return (NULL);
	pty->sock = INVALID_SOCKET;
	pty->bridge_peer = INVALID_SOCKET;
	pty->hPC = NULL;

	/* Create pipes for ConPTY. */
	if (!CreatePipe(&pipeIn_read, &pipeIn_write, NULL, 0))
		goto fail;
	if (!CreatePipe(&pipeOut_read, &pipeOut_write, NULL, 0))
		goto fail;

	/* Create pseudo console. */
	size.X = (SHORT)cols;
	size.Y = (SHORT)rows;
	hr = CreatePseudoConsole(size, pipeIn_read, pipeOut_write, 0, &pty->hPC);
	if (FAILED(hr))
		goto fail;

	/* Close the sides of the pipes that ConPTY now owns. */
	CloseHandle(pipeIn_read);
	pipeIn_read = NULL;
	CloseHandle(pipeOut_write);
	pipeOut_write = NULL;

	pty->hPipeIn = pipeIn_write;
	pty->hPipeOut = pipeOut_read;

	/* Set up STARTUPINFOEX with the pseudo console attribute. */
	memset(&si, 0, sizeof si);
	si.StartupInfo.cb = sizeof si;

	/*
	 * Force the child to get its standard handles from the pseudo console
	 * rather than inheriting the parent's handles. Without this, cmd.exe
	 * and other shells get non-console STD handles (pipes/files from the
	 * parent's context), causing them to treat stdin as non-interactive
	 * and exit immediately.
	 */
	si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
	si.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
	si.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
	si.StartupInfo.hStdError = INVALID_HANDLE_VALUE;

	InitializeProcThreadAttributeList(NULL, 1, 0, &attrSize);
	si.lpAttributeList = (LPPROC_THREAD_ATTRIBUTE_LIST)malloc(attrSize);
	if (si.lpAttributeList == NULL)
		goto fail;
	if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attrSize))
		goto fail;
	if (!UpdateProcThreadAttribute(si.lpAttributeList, 0,
	    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pty->hPC, sizeof(HPCON),
	    NULL, NULL))
		goto fail;

	/* Convert command and cwd to wide strings. */
	MultiByteToWideChar(CP_UTF8, 0, cmd, -1, wcmd, sizeof wcmd / sizeof wcmd[0]);
	if (cwd != NULL && *cwd != '\0')
		MultiByteToWideChar(CP_UTF8, 0, cwd, -1, wcwd, sizeof wcwd / sizeof wcwd[0]);

	/* Create the child process. */
	memset(&pi, 0, sizeof pi);
	{
		DWORD flags = EXTENDED_STARTUPINFO_PRESENT;
		if (env != NULL)
			flags |= CREATE_UNICODE_ENVIRONMENT;
		if (!CreateProcessW(NULL, wcmd, NULL, NULL, FALSE,
		    flags, env,
		    (cwd != NULL && *cwd != '\0') ? wcwd : NULL,
		    &si.StartupInfo, &pi))
			goto fail;
	}

	pty->hProcess = pi.hProcess;
	pty->hThread = pi.hThread;
	pty->dwProcessId = pi.dwProcessId;

	DeleteProcThreadAttributeList(si.lpAttributeList);
	free(si.lpAttributeList);

	/* Create bridge socketpair. */
	if (win32_socketpair(AF_INET, SOCK_STREAM, 0, sv) != 0)
		goto fail;
	pty->sock = (SOCKET)sv[0];
	pty->bridge_peer = (SOCKET)sv[1];

	/* Start bridge threads (output and input). */
	pty->closing = 0;
	pty->bridge_thread = CreateThread(NULL, 0, pty_bridge_thread, pty, 0, NULL);
	if (pty->bridge_thread == NULL)
		goto fail;
	pty->input_thread = CreateThread(NULL, 0, pty_input_thread, pty, 0, NULL);
	if (pty->input_thread == NULL)
		goto fail;
	pty->process_thread = CreateThread(NULL, 0, pty_process_thread, pty, 0,
	    NULL);
	if (pty->process_thread == NULL)
		goto fail;

	if (out_pid != NULL)
		*out_pid = (pid_t)pi.dwProcessId;

	return (pty);

fail:
	if (pipeIn_read) CloseHandle(pipeIn_read);
	if (pipeIn_write) CloseHandle(pipeIn_write);
	if (pipeOut_read) CloseHandle(pipeOut_read);
	if (pipeOut_write) CloseHandle(pipeOut_write);
	close_pseudoconsole_once(&pty->hPC);
	if (pty->hProcess) CloseHandle(pty->hProcess);
	if (pty->hThread) CloseHandle(pty->hThread);
	if (pty->process_thread) CloseHandle(pty->process_thread);
	if (pty->sock != INVALID_SOCKET) closesocket(pty->sock);
	if (pty->bridge_peer != INVALID_SOCKET) closesocket(pty->bridge_peer);
	free(pty);
	return (NULL);
}

int
win32_pty_resize(struct win32_pty *pty, int cols, int rows)
{
	COORD size;
	HRESULT hr;

	if (pty == NULL || pty->hPC == NULL)
		return (-1);

	size.X = (SHORT)cols;
	size.Y = (SHORT)rows;
	hr = ResizePseudoConsole(pty->hPC, size);
	return SUCCEEDED(hr) ? 0 : -1;
}

void
win32_pty_close(struct win32_pty *pty)
{
	if (pty == NULL)
		return;

	pty->closing = 1;

	close_pseudoconsole_once(&pty->hPC);
	close_handle_once(&pty->hPipeIn);
	close_handle_once(&pty->hPipeOut);

	/* Wait for bridge threads. */
	if (pty->bridge_thread != NULL) {
		WaitForSingleObject(pty->bridge_thread, 2000);
		CloseHandle(pty->bridge_thread);
	}
	if (pty->input_thread != NULL) {
		WaitForSingleObject(pty->input_thread, 2000);
		CloseHandle(pty->input_thread);
	}
	if (pty->process_thread != NULL) {
		WaitForSingleObject(pty->process_thread, 2000);
		CloseHandle(pty->process_thread);
	}

	if (pty->hProcess != NULL) {
		TerminateProcess(pty->hProcess, 1);
		CloseHandle(pty->hProcess);
	}
	if (pty->hThread != NULL)
		CloseHandle(pty->hThread);

	if (pty->sock != INVALID_SOCKET)
		closesocket(pty->sock);
	close_socket_once(&pty->bridge_peer);

	free(pty);
}

int
win32_pty_get_fd(struct win32_pty *pty)
{
	if (pty == NULL)
		return (-1);
	return (int)pty->sock;
}

HANDLE
win32_pty_get_process(struct win32_pty *pty)
{
	if (pty == NULL)
		return NULL;
	return pty->hProcess;
}

/*
 * Write data to the PTY input (from server to child process).
 */
int
win32_pty_write(struct win32_pty *pty, const void *data, size_t len)
{
	if (pty == NULL || pty->hPipeIn == NULL)
		return (-1);
	if (pty_handle_write_all(pty->hPipeIn, data, len) != 0)
		return (-1);
	return ((int)len);
}
