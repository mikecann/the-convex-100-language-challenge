/*
 * A deliberately tiny timeout command for the final Bash runtime.
 *
 * BusyBox's timeout applet only accepts whole seconds. The Live adapter polls
 * its socket every 100 ms, so rounding that to one second makes every shared
 * subscription test miss its deadline. This executable supplies precisely the
 * `timeout SECONDS COMMAND...` surface the client needs without bringing the
 * rest of GNU coreutils into the minimal image.
 */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t timed_out;

static void on_alarm(int ignored) {
	(void)ignored;
	timed_out = 1;
}

int main(int argc, char **argv) {
	char *end;
	double seconds;
	long long micros;
	pid_t child;
	int status;
	struct sigaction action = {.sa_handler = on_alarm};
	struct itimerval timer = {0};

	if (argc < 3) {
		fputs("usage: timeout SECONDS COMMAND [ARG...]\n", stderr);
		return 125;
	}
	errno = 0;
	seconds = strtod(argv[1], &end);
	if (errno || *end || seconds <= 0 || seconds > 2147483.0) {
		fprintf(stderr, "timeout: invalid number '%s'\n", argv[1]);
		return 125;
	}
	micros = (long long)(seconds * 1000000.0);
	if (micros < 1) micros = 1;
	/* waitpid must return EINTR so the parent can terminate the child group. */
	action.sa_flags = 0;
	sigemptyset(&action.sa_mask);
	if (sigaction(SIGALRM, &action, NULL) != 0) return 125;
	child = fork();
	if (child < 0) return 125;
	if (child == 0) {
		setpgid(0, 0);
		execvp(argv[2], argv + 2);
		perror(argv[2]);
		return 127;
	}
	/* Close the fork/setpgid race before a short deadline can fire. */
	setpgid(child, child);
	timer.it_value.tv_sec = micros / 1000000;
	timer.it_value.tv_usec = micros % 1000000;
	if (setitimer(ITIMER_REAL, &timer, NULL) != 0) return 125;
	while (waitpid(child, &status, 0) < 0) {
		if (errno != EINTR) return 125;
		if (timed_out) {
			struct timespec grace = {.tv_sec = 0, .tv_nsec = 1000000};
			int attempt;
			/*
			 * A one-byte dd may have completed its read and be about to write
			 * when the alarm arrives. Give such a finite child a small chance
			 * to flush and exit before terminating a genuinely blocked read.
			 */
			for (attempt = 0; attempt < 25; attempt++) {
				pid_t result = waitpid(child, &status, WNOHANG);
				if (result == child) return 124;
				if (result < 0 && errno != EINTR) return 125;
				nanosleep(&grace, NULL);
			}
			kill(-child, SIGTERM);
			while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
			return 124;
		}
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
