/* $OpenBSD$ */

/*
 * Copyright (c) 2007 Nicholas Marriott <nicholas.marriott@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>
#include <sys/stat.h>
#ifndef _WIN32
#include <sys/utsname.h>
#endif

#ifdef _WIN32
#include <crtdbg.h>
#endif
#include <errno.h>
#include <fcntl.h>
#ifndef _WIN32
#include <langinfo.h>
#endif
#include <locale.h>
#ifndef _WIN32
#include <pwd.h>
#include <signal.h>
#endif
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#include "tmux.h"

struct options	*global_options;	/* server options */
struct options	*global_s_options;	/* session options */
struct options	*global_w_options;	/* window options */
struct environ	*global_environ;

struct timeval	 start_time;
const char	*socket_path;
int		 ptm_fd = -1;
const char	*shell_command;

static __dead void	 usage(int);
static char		*make_label(const char *, char **);

static int		 areshell(const char *);
static const char	*getshell(void);
#ifdef _WIN32
static const char	*shell_basename(const char *);
static int		 shell_family_from_name(const char *,
			    enum shell_family *);
static char		*win32_quote_argument(const char *);
static const char	*win32_shell_command_flag(enum shell_family);
#endif

static __dead void
usage(int status)
{
	fprintf(status ? stderr : stdout,
	    "usage: %s [-2CDhlNuVv] [-c shell-command] [-f file] [-L socket-name]\n"
	    "            [-S socket-path] [-T features] [command [flags]]\n",
	    getprogname());
	exit(status);
}

char *
resolveshell(const char *shell, enum shell_family *family)
{
	char	*resolved;
#ifdef _WIN32
	size_t	 i;
	enum shell_family	 resolved_family;
#endif

	if (shell == NULL || *shell == '\0')
		return (NULL);
#ifdef _WIN32
	resolved_family = SHELL_FAMILY_CMD;
	if (shell[0] == '/' && shell[1] != '/') {
		log_debug("ignoring Unix shell path \"%s\" on Windows", shell);
		return (NULL);
	}
	resolved = xstrdup(shell);

	/* Strip MSYS2 backslash-escape: C\:/foo -> C:/foo. */
	if (strlen(resolved) > 2 && resolved[1] == '\\' && resolved[2] == ':')
		memmove(resolved + 1, resolved + 2, strlen(resolved + 2) + 1);

	for (i = 0; resolved[i] != '\0'; i++) {
		if (resolved[i] == '/')
			resolved[i] = '\\';
	}
	if (!shell_family_from_name(shell_basename(resolved), &resolved_family)) {
		free(resolved);
		return (NULL);
	}
#else
	if (*shell != '/')
		return (NULL);
	resolved = xstrdup(shell);
#endif
	if (areshell(resolved)) {
		free(resolved);
		return (NULL);
	}
	if (access(resolved, X_OK) != 0) {
		free(resolved);
		return (NULL);
	}
#ifdef _WIN32
	if (family != NULL)
		*family = resolved_family;
#else
	(void)family;
#endif
	return (resolved);
}

#ifdef _WIN32
char *
environ_to_win32_block(struct environ *env)
{
	struct environ_entry	*ee;
	size_t			 total = 0;
	wchar_t			*block, *p;
	int			 nlen, vlen;

	for (ee = environ_first(env); ee != NULL; ee = environ_next(ee)) {
		if (ee->value == NULL || *ee->name == '\0')
			continue;
		nlen = MultiByteToWideChar(CP_UTF8, 0, ee->name, -1, NULL, 0);
		vlen = MultiByteToWideChar(CP_UTF8, 0, ee->value, -1, NULL, 0);
		total += (nlen - 1) + 1 + vlen;
	}
	total += 1;

	block = xcalloc(total, sizeof *block);
	p = block;
	for (ee = environ_first(env); ee != NULL; ee = environ_next(ee)) {
		if (ee->value == NULL || *ee->name == '\0')
			continue;
		nlen = MultiByteToWideChar(CP_UTF8, 0, ee->name, -1, p,
		    (int)(total - (p - block)));
		p += nlen - 1;
		*p++ = L'=';
		vlen = MultiByteToWideChar(CP_UTF8, 0, ee->value, -1, p,
		    (int)(total - (p - block)));
		p += vlen;
	}
	*p = L'\0';

	return ((char *)block);
}

char *
win32_build_command_line(int argc, char **argv)
{
	char	**quoted, *cmdline, *arg;
	size_t	  len;
	int	  i;

	if (argc == 0)
		return (xstrdup(""));

	quoted = xcalloc(argc, sizeof *quoted);
	len = 1;
	for (i = 0; i < argc; i++) {
		arg = argv[i];
		if (arg == NULL)
			arg = "";
		quoted[i] = win32_quote_argument(arg);
		len += strlen(quoted[i]) + 1;
	}

	cmdline = xmalloc(len);
	*cmdline = '\0';
	for (i = 0; i < argc; i++) {
		if (i != 0)
			strlcat(cmdline, " ", len);
		strlcat(cmdline, quoted[i], len);
		free(quoted[i]);
	}
	free(quoted);

	return (cmdline);
}

char *
win32_build_shell_command(const char *shell, enum shell_family family,
    const char *command)
{
	const char	*flag = win32_shell_command_flag(family);
	char		*quoted_shell, *quoted_command, *cmdline;

	quoted_shell = win32_quote_argument(shell);
	quoted_command = win32_quote_argument(command);
	xasprintf(&cmdline, "%s %s %s", quoted_shell, flag, quoted_command);
	free(quoted_shell);
	free(quoted_command);
	return (cmdline);
}

char *
win32_strip_control_sequences(const char *input)
{
	size_t		 len, i, outlen = 0;
	char		*output;

	if (input == NULL)
		return (xstrdup(""));

	len = strlen(input);
	output = xmalloc(len + 1);
	for (i = 0; i < len; i++) {
		if ((unsigned char)input[i] != '\033') {
			output[outlen++] = input[i];
			continue;
		}
		i++;
		if (i >= len)
			break;
		if (input[i] == '[') {
			i++;
			while (i < len &&
			    ((unsigned char)input[i] < 0x40 ||
			    (unsigned char)input[i] > 0x7e))
				i++;
		} else if (input[i] == ']') {
			i++;
			while (i < len) {
				if (input[i] == '\a')
					break;
				if (input[i] == '\033' && i + 1 < len &&
				    input[i + 1] == '\\') {
					i++;
					break;
				}
				i++;
			}
		}
	}
	output[outlen] = '\0';
	return (output);
}

static const char *
shell_basename(const char *shell)
{
	const char	*slash, *name;

	slash = strrchr(shell, '/');
	name = strrchr(shell, '\\');
	if (name != NULL && (slash == NULL || name > slash))
		slash = name;
	if (slash != NULL && slash[1] != '\0')
		return (slash + 1);
	return (shell);
}

static int
shell_family_from_name(const char *name, enum shell_family *family)
{
	if (strcasecmp(name, "cmd") == 0 ||
	    strcasecmp(name, "cmd.exe") == 0 ||
	    strcasecmp(name, "command.com") == 0) {
		*family = SHELL_FAMILY_CMD;
		return (1);
	}
	if (strcasecmp(name, "powershell") == 0 ||
	    strcasecmp(name, "powershell.exe") == 0 ||
	    strcasecmp(name, "pwsh") == 0 ||
	    strcasecmp(name, "pwsh.exe") == 0) {
		*family = SHELL_FAMILY_POWERSHELL;
		return (1);
	}
	if (strcasecmp(name, "sh") == 0 ||
	    strcasecmp(name, "sh.exe") == 0 ||
	    strcasecmp(name, "ash") == 0 ||
	    strcasecmp(name, "ash.exe") == 0 ||
	    strcasecmp(name, "bash") == 0 ||
	    strcasecmp(name, "bash.exe") == 0 ||
	    strcasecmp(name, "dash") == 0 ||
	    strcasecmp(name, "dash.exe") == 0 ||
	    strcasecmp(name, "ksh") == 0 ||
	    strcasecmp(name, "ksh.exe") == 0 ||
	    strcasecmp(name, "mksh") == 0 ||
	    strcasecmp(name, "mksh.exe") == 0 ||
	    strcasecmp(name, "pdksh") == 0 ||
	    strcasecmp(name, "pdksh.exe") == 0 ||
	    strcasecmp(name, "zsh") == 0 ||
	    strcasecmp(name, "zsh.exe") == 0) {
		*family = SHELL_FAMILY_POSIX;
		return (1);
	}
	return (0);
}

static char *
win32_quote_argument(const char *arg)
{
	size_t		 backslashes, len;
	const char	*s;
	char		*quoted, *out;
	int		 need_quotes;

	need_quotes = (*arg == '\0');
	for (s = arg; *s != '\0'; s++) {
		if (*s == ' ' || *s == '\t' || *s == '"') {
			need_quotes = 1;
			break;
		}
	}
	if (!need_quotes)
		return (xstrdup(arg));

	len = strlen(arg) * 2 + 3;
	quoted = xmalloc(len);
	out = quoted;
	*out++ = '"';

	backslashes = 0;
	for (s = arg; *s != '\0'; s++) {
		if (*s == '\\') {
			backslashes++;
			continue;
		}
		if (*s == '"') {
			while (backslashes != 0) {
				*out++ = '\\';
				*out++ = '\\';
				backslashes--;
			}
			*out++ = '\\';
			*out++ = '"';
			backslashes = 0;
			continue;
		}
		while (backslashes != 0) {
			*out++ = '\\';
			backslashes--;
		}
		backslashes = 0;
		*out++ = *s;
	}
	while (backslashes != 0) {
		*out++ = '\\';
		*out++ = '\\';
		backslashes--;
	}
	*out++ = '"';
	*out = '\0';

	return (quoted);
}

static const char *
win32_shell_command_flag(enum shell_family family)
{
	switch (family) {
	case SHELL_FAMILY_POWERSHELL:
		return ("-Command");
	case SHELL_FAMILY_POSIX:
		return ("-c");
	case SHELL_FAMILY_CMD:
	default:
		return ("/c");
	}
}
#endif

static const char *
getshell(void)
{
#ifdef _WIN32
	const char	*shell;
	char		*resolved;

	shell = getenv("SHELL");
	if ((resolved = resolveshell(shell, NULL)) != NULL) {
		free(resolved);
		return (shell);
	}
	shell = getenv("COMSPEC");
	if ((resolved = resolveshell(shell, NULL)) != NULL) {
		free(resolved);
		return (shell);
	}
	return (_PATH_BSHELL);
#else
	struct passwd	*pw;
	const char	*shell;

	shell = getenv("SHELL");
	if (checkshell(shell))
		return (shell);

	pw = getpwuid(getuid());
	if (pw != NULL && checkshell(pw->pw_shell))
		return (pw->pw_shell);

	return (_PATH_BSHELL);
#endif
}

int
checkshell(const char *shell)
{
	char	*resolved;

	resolved = resolveshell(shell, NULL);
	if (resolved == NULL)
		return (0);
	free(resolved);
	return (1);
}

static int
areshell(const char *shell)
{
	const char	*progname, *ptr;

	if ((ptr = strrchr(shell, '/')) != NULL)
		ptr++;
#ifdef _WIN32
	else if ((ptr = strrchr(shell, '\\')) != NULL)
		ptr++;
#endif
	else
		ptr = shell;
	progname = getprogname();
	if (*progname == '-')
		progname++;
	if (strcmp(ptr, progname) == 0)
		return (1);
	return (0);
}

static char *
expand_path(const char *path, const char *home)
{
	char			*expanded, *name;
	const char		*end;
	struct environ_entry	*value;

	if (strncmp(path, "~/", 2) == 0) {
		if (home == NULL)
			return (NULL);
		xasprintf(&expanded, "%s%s", home, path + 1);
		return (expanded);
	}

	if (*path == '$') {
		end = strchr(path, '/');
		if (end == NULL)
			name = xstrdup(path + 1);
		else
			name = xstrndup(path + 1, end - path - 1);
		value = environ_find(global_environ, name);
		free(name);
		if (value == NULL)
			return (NULL);
		if (end == NULL)
			end = "";
		xasprintf(&expanded, "%s%s", value->value, end);
		return (expanded);
	}

	return (xstrdup(path));
}

static void
expand_paths(const char *s, char ***paths, u_int *n, int no_realpath)
{
	const char	*home = find_home();
	char		*copy, *next, *tmp, resolved[PATH_MAX], *expanded;
	char		*path;
	u_int		 i;

	*paths = NULL;
	*n = 0;

	copy = tmp = xstrdup(s);
	while ((next = strsep(&tmp, ":")) != NULL) {
		expanded = expand_path(next, home);
		if (expanded == NULL) {
			log_debug("%s: invalid path: %s", __func__, next);
			continue;
		}
		if (no_realpath)
			path = expanded;
		else {
			if (realpath(expanded, resolved) == NULL) {
				log_debug("%s: realpath(\"%s\") failed: %s", __func__,
			  expanded, strerror(errno));
				free(expanded);
				continue;
			}
			path = xstrdup(resolved);
			free(expanded);
		}
		for (i = 0; i < *n; i++) {
			if (strcmp(path, (*paths)[i]) == 0)
				break;
		}
		if (i != *n) {
			log_debug("%s: duplicate path: %s", __func__, path);
			free(path);
			continue;
		}
		*paths = xreallocarray(*paths, (*n) + 1, sizeof *paths);
		(*paths)[(*n)++] = path;
	}
	free(copy);
}

static char *
make_label(const char *label, char **cause)
{
#ifdef _WIN32
	char		*path, *appdata;
	char		 dir[MAX_PATH];

	*cause = NULL;
	if (label == NULL)
		label = "default";

	/* Reject labels with characters unsafe for pipe names / command lines. */
	{
		const char *p;
		for (p = label; *p != '\0'; p++) {
			if (!(*p >= 'A' && *p <= 'Z') &&
			    !(*p >= 'a' && *p <= 'z') &&
			    !(*p >= '0' && *p <= '9') &&
			    *p != '.' && *p != '_' && *p != '-') {
				xasprintf(cause, "bad label character '%c'"
				    " (allowed: A-Z a-z 0-9 . _ -)", *p);
				return (NULL);
			}
		}
	}

	appdata = getenv("LOCALAPPDATA");
	if (appdata == NULL)
		appdata = getenv("APPDATA");
	if (appdata == NULL) {
		xasprintf(cause, "no suitable socket path");
		return (NULL);
	}

	snprintf(dir, sizeof dir, "%s\\tmux", appdata);
	_mkdir(dir);

	/* Return "tmux-<username>-<label>" as the label identifier. */
	{
		char username[256];
		DWORD size = sizeof username;
		if (!GetUserNameA(username, &size))
			strncpy(username, "user", sizeof username);
		xasprintf(&path, "tmux-%s-%s", username, label);
	}
	return (path);
#else
	char		**paths, *path, *base;
	u_int		  i, n;
	struct stat	  sb;
	uid_t		  uid;

	*cause = NULL;
	if (label == NULL)
		label = "default";
	uid = getuid();

	expand_paths(TMUX_SOCK, &paths, &n, 0);
	if (n == 0) {
		xasprintf(cause, "no suitable socket path");
		return (NULL);
	}
	path = paths[0]; /* can only have one socket! */
	for (i = 1; i < n; i++)
		free(paths[i]);
	free(paths);

	xasprintf(&base, "%s/tmux-%ld", path, (long)uid);
	free(path);
	if (mkdir(base, S_IRWXU) != 0 && errno != EEXIST) {
		xasprintf(cause, "couldn't create directory %s (%s)", base,
		    strerror(errno));
		goto fail;
	}
	if (lstat(base, &sb) != 0) {
		xasprintf(cause, "couldn't read directory %s (%s)", base,
		    strerror(errno));
		goto fail;
	}
	if (!S_ISDIR(sb.st_mode)) {
		xasprintf(cause, "%s is not a directory", base);
		goto fail;
	}
	if (sb.st_uid != uid || (sb.st_mode & TMUX_SOCK_PERM) != 0) {
		xasprintf(cause, "directory %s has unsafe permissions", base);
		goto fail;
	}
	xasprintf(&path, "%s/%s", base, label);
	free(base);
	return (path);

fail:
	free(base);
	return (NULL);
#endif
}

char *
shell_argv0(const char *shell, int is_login)
{
	const char	*slash, *name;
	char		*argv0;

	slash = strrchr(shell, '/');
#ifdef _WIN32
	{
		const char *bslash = strrchr(shell, '\\');
		if (bslash != NULL && (slash == NULL || bslash > slash))
			slash = bslash;
	}
#endif
	if (slash != NULL && slash[1] != '\0')
		name = slash + 1;
	else
		name = shell;
	if (is_login)
		xasprintf(&argv0, "-%s", name);
	else
		xasprintf(&argv0, "%s", name);
	return (argv0);
}

void
setblocking(int fd, int state)
{
#ifdef _WIN32
	u_long mode = state ? 0 : 1;
	ioctlsocket((SOCKET)fd, FIONBIO, &mode);
#else
	int mode;

	if ((mode = fcntl(fd, F_GETFL)) != -1) {
		if (!state)
			mode |= O_NONBLOCK;
		else
			mode &= ~O_NONBLOCK;
		fcntl(fd, F_SETFL, mode);
	}
#endif
}

uint64_t
get_timer(void)
{
	struct timespec	ts;

	/*
	 * We want a timestamp in milliseconds suitable for time measurement,
	 * so prefer the monotonic clock.
	 */
	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		clock_gettime(CLOCK_REALTIME, &ts);
	return ((ts.tv_sec * 1000ULL) + (ts.tv_nsec / 1000000ULL));
}

const char *
sig2name(int signo)
{
     static char	s[11];

#ifdef HAVE_SYS_SIGNAME
     if (signo > 0 && signo < NSIG)
	     return (sys_signame[signo]);
#endif
     xsnprintf(s, sizeof s, "%d", signo);
     return (s);
}

const char *
find_cwd(void)
{
	char		 resolved1[PATH_MAX], resolved2[PATH_MAX];
	static char	 cwd[PATH_MAX];
	const char	*pwd;

	if (getcwd(cwd, sizeof cwd) == NULL)
		return (NULL);
	if ((pwd = getenv("PWD")) == NULL || *pwd == '\0')
		return (cwd);

	/*
	 * We want to use PWD so that symbolic links are maintained,
	 * but only if it matches the actual working directory.
	 */
	if (realpath(pwd, resolved1) == NULL)
		return (cwd);
	if (realpath(cwd, resolved2) == NULL)
		return (cwd);
	if (strcmp(resolved1, resolved2) != 0)
		return (cwd);
	return (pwd);
}

const char *
find_home(void)
{
	static const char	*home;
#ifndef _WIN32
	struct passwd		*pw;
#endif

	if (home != NULL)
		return (home);

#ifdef _WIN32
	home = getenv("USERPROFILE");
	if (home == NULL || *home == '\0')
		home = getenv("HOME");
	if (home == NULL || *home == '\0')
		home = "C:\\";
#else
	home = getenv("HOME");
	if (home == NULL || *home == '\0') {
		pw = getpwuid(getuid());
		if (pw != NULL)
			home = pw->pw_dir;
		else
			home = NULL;
	}
#endif

	return (home);
}

const char *
getversion(void)
{
	return (TMUX_VERSION);
}

int
main(int argc, char **argv)
{
	char					*path = NULL, *label = NULL;
	char					*cause, **var;
	const char				*s, *cwd;
	int					 opt, keys, feat = 0, fflag = 0;
	uint64_t				 flags = 0;
	const struct options_table_entry	*oe;
	u_int					 i;

#ifdef _WIN32
	/* Redirect CRT assertion dialogs to stderr. */
	_CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
	_CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
	_CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_FILE);
	_CrtSetReportFile(_CRT_ERROR, _CRTDBG_FILE_STDERR);
	win32_init_environ();
	win32_wsa_init();
	win32_process_init();
	win32_tty_init_utf8();
	setlocale(LC_ALL, "");
	tzset();
	flags |= CLIENT_UTF8;
#else
	if (setlocale(LC_CTYPE, "en_US.UTF-8") == NULL &&
	    setlocale(LC_CTYPE, "C.UTF-8") == NULL) {
		if (setlocale(LC_CTYPE, "") == NULL)
			errx(1, "invalid LC_ALL, LC_CTYPE or LANG");
		s = nl_langinfo(CODESET);
		if (strcasecmp(s, "UTF-8") != 0 && strcasecmp(s, "UTF8") != 0)
			errx(1, "need UTF-8 locale (LC_CTYPE) but have %s", s);
	}

	setlocale(LC_TIME, "");
	tzset();
#endif

	if (**argv == '-')
		flags = CLIENT_LOGIN;

	global_environ = environ_create();
	for (var = environ; *var != NULL; var++)
		environ_put(global_environ, *var, 0);
	if ((cwd = find_cwd()) != NULL)
		environ_set(global_environ, "PWD", 0, "%s", cwd);
	expand_paths(TMUX_CONF, &cfg_files, &cfg_nfiles, 1);

	while ((opt = getopt(argc, argv, "2c:CDdf:hlL:NqS:T:uUvV")) != -1) {
		switch (opt) {
		case '2':
			tty_add_features(&feat, "256", ":,");
			break;
		case 'c':
			shell_command = optarg;
			break;
		case 'D':
			flags |= CLIENT_NOFORK;
			break;
		case 'C':
			if (flags & CLIENT_CONTROL)
				flags |= CLIENT_CONTROLCONTROL;
			else
				flags |= CLIENT_CONTROL;
			break;
		case 'f':
			if (!fflag) {
				fflag = 1;
				for (i = 0; i < cfg_nfiles; i++)
					free(cfg_files[i]);
				cfg_nfiles = 0;
			}
			cfg_files = xreallocarray(cfg_files, cfg_nfiles + 1,
			    sizeof *cfg_files);

#ifdef _WIN32
			if (strcmp(optarg, "/dev/null") == 0)
				cfg_files[cfg_nfiles++] = xstrdup("NUL");
			else
#endif
			cfg_files[cfg_nfiles++] = xstrdup(optarg);
			cfg_quiet = 0;
			break;
		case 'h':
			usage(0);
		case 'V':
			printf("tmux %s\n", getversion());
			exit(0);
		case 'l':
			flags |= CLIENT_LOGIN;
			break;
		case 'L':
			free(label);
			label = xstrdup(optarg);
			break;
		case 'N':
			flags |= CLIENT_NOSTARTSERVER;
			break;
		case 'q':
			break;
		case 'S':
			free(path);
#ifdef _WIN32
			/*
			 * On Windows, -S is an IPC label, not a file path.
			 * Strip any directory prefix (Unix paths are
			 * meaningless here) so -S /tmp/foo becomes "foo".
			 */
			if (strchr(optarg, '/') != NULL) {
				const char *base;
				fprintf(stderr, "warning: -S \"%s\" is a "
				    "Unix-style path; on Windows the "
				    "basename is used as an IPC label\n",
				    optarg);
				base = strrchr(optarg, '/') + 1;
				if (*base == '\0')
					base = "default";
				path = xstrdup(base);
			} else
#endif
			path = xstrdup(optarg);
			break;
		case 'T':
			tty_add_features(&feat, optarg, ":,");
			break;
		case 'u':
			flags |= CLIENT_UTF8;
			break;
		case 'v':
			log_add_level();
			break;
		default:
			usage(1);
		}
	}
	argc -= optind;
	argv += optind;

	if (shell_command != NULL && argc != 0)
		usage(1);
	if ((flags & CLIENT_NOFORK) && argc != 0)
		usage(1);

#ifndef _WIN32
	if ((ptm_fd = getptmfd()) == -1)
		err(1, "getptmfd");
#endif
	if (pledge("stdio rpath wpath cpath flock fattr unix getpw sendfd "
	    "recvfd proc exec tty ps", NULL) != 0)
		err(1, "pledge");

	/*
	 * tmux is a UTF-8 terminal, so if TMUX is set, assume UTF-8.
	 * Otherwise, if the user has set LC_ALL, LC_CTYPE or LANG to contain
	 * UTF-8, it is a safe assumption that either they are using a UTF-8
	 * terminal, or if not they know that output from UTF-8-capable
	 * programs may be wrong.
	 */
	if (getenv("TMUX") != NULL)
		flags |= CLIENT_UTF8;
	else {
		s = getenv("LC_ALL");
		if (s == NULL || *s == '\0')
			s = getenv("LC_CTYPE");
		if (s == NULL || *s == '\0')
			s = getenv("LANG");
		if (s == NULL || *s == '\0')
			s = "";
		if (strcasestr(s, "UTF-8") != NULL ||
		    strcasestr(s, "UTF8") != NULL)
			flags |= CLIENT_UTF8;
	}

	global_options = options_create(NULL);
	global_s_options = options_create(NULL);
	global_w_options = options_create(NULL);
	for (oe = options_table; oe->name != NULL; oe++) {
		if (oe->scope & OPTIONS_TABLE_SERVER)
			options_default(global_options, oe);
		if (oe->scope & OPTIONS_TABLE_SESSION)
			options_default(global_s_options, oe);
		if (oe->scope & OPTIONS_TABLE_WINDOW)
			options_default(global_w_options, oe);
	}

	/*
	 * The default shell comes from SHELL or from the user's passwd entry
	 * if available.
	 */
	options_set_string(global_s_options, "default-shell", 0, "%s",
	    getshell());

	/* Override keys to vi if VISUAL or EDITOR are set. */
	if ((s = getenv("VISUAL")) != NULL || (s = getenv("EDITOR")) != NULL) {
		options_set_string(global_options, "editor", 0, "%s", s);
		if (strrchr(s, '/') != NULL)
			s = strrchr(s, '/') + 1;
		if (strstr(s, "vi") != NULL)
			keys = MODEKEY_VI;
		else
			keys = MODEKEY_EMACS;
		options_set_number(global_s_options, "status-keys", keys);
		options_set_number(global_w_options, "mode-keys", keys);
	}

	/*
	 * If socket is specified on the command-line with -S or -L, it is
	 * used. Otherwise, $TMUX is checked and if that fails "default" is
	 * used.
	 */
	if (path == NULL && label == NULL) {
		s = getenv("TMUX");
		if (s != NULL && *s != '\0' && *s != ',') {
			path = xstrdup(s);
			path[strcspn(path, ",")] = '\0';
		}
	}
	if (path == NULL) {
		if ((path = make_label(label, &cause)) == NULL) {
			if (cause != NULL) {
				fprintf(stderr, "%s\n", cause);
				free(cause);
			}
			exit(1);
		}
		flags |= CLIENT_DEFAULTSOCKET;
	}
	socket_path = path;
	free(label);

	/* Pass control to the client. */
	exit(client_main(osdep_event_init(), argc, argv, flags, feat));
}
