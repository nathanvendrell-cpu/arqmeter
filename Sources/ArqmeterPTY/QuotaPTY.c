#include "ArqmeterPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <errno.h>

pid_t arq_quota_spawn_control(const char *path, char *const argv[], char *const env[],
                             const char *directory, int *input, int *output) {
    int to_child[2], from_child[2];
    *input = -1; *output = -1;
    if (pipe(to_child) != 0) return -1;
    if (pipe(from_child) != 0) { close(to_child[0]); close(to_child[1]); return -1; }
    int limit = getdtablesize();
    pid_t pid = fork();
    if (pid == 0) {
        // Async-signal-safe only. No inherited DB descriptors or shell.
        if (setsid() < 0 || chdir(directory) != 0) _exit(126);
        if (dup2(to_child[0], STDIN_FILENO) < 0 || dup2(from_child[1], STDOUT_FILENO) < 0) _exit(126);
        int quiet = open("/dev/null", O_WRONLY);
        if (quiet < 0 || dup2(quiet, STDERR_FILENO) < 0) _exit(126);
        for (int fd = 3; fd < limit; ++fd) close(fd);
        execve(path, argv, env);
        _exit(127);
    }
    close(to_child[0]); close(from_child[1]);
    if (pid < 0) { close(to_child[1]); close(from_child[0]); return -1; }
    *input = to_child[1]; *output = from_child[0];
    fcntl(*input, F_SETFD, FD_CLOEXEC); fcntl(*output, F_SETFD, FD_CLOEXEC);
    fcntl(*input, F_SETFL, O_NONBLOCK); fcntl(*output, F_SETFL, O_NONBLOCK);
    fcntl(*input, F_SETNOSIGPIPE, 1);
    return pid;
}

pid_t arq_quota_spawn(const char *path, char *const argv[], char *const env[],
                     const char *directory, int *master) {
    struct winsize size = {.ws_row = 50, .ws_col = 160};
    int limit = getdtablesize();
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        // Only async-signal-safe calls between fork and exec. Do not inherit app DB descriptors.
        for (int fd = 3; fd < limit; ++fd) close(fd);
        if (chdir(directory) != 0) _exit(126);
        execve(path, argv, env);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}
int arq_quota_reap(pid_t pid, int *status) {
    if (pid <= 0) { errno = EINVAL; return -1; }
    int result;
    do { result = (int)waitpid(pid, status, WNOHANG); } while (result < 0 && errno == EINTR);
    return result;
}
int arq_quota_group_exists(pid_t pid) {
    if (pid <= 0) return 0;
    return kill(-pid, 0) == 0 || errno == EPERM;
}
int arq_quota_signal(pid_t pid, int signal_number) {
    if (pid <= 0) { errno = EINVAL; return -1; }
    return kill(-pid, signal_number); // forkpty creates the dedicated session/group.
}
