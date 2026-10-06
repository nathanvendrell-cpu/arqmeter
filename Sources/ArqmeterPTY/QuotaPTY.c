#include "ArqmeterPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <errno.h>

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
