#ifndef ARQMETER_PTY_H
#define ARQMETER_PTY_H
#include <sys/types.h>
// New process/session owned solely by the quota reader; no shell and no forked Swift code.
pid_t arq_quota_spawn(const char *path, char *const argv[], char *const env[],
                     const char *directory, int *master);
int arq_quota_reap(pid_t pid, int *status);
int arq_quota_group_exists(pid_t pid);
int arq_quota_signal(pid_t pid, int signal_number);
#endif
