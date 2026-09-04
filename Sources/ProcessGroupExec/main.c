#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: OpenConnectSandboxExec executable [arguments...]\n");
        return 64;
    }

    /* A fresh session gives the supervisor one process-group ID that includes
       the target and every helper it launches (for example ocproxy or QtWebEngine). */
    if (setsid() == -1 && !(errno == EPERM && getpgrp() == getpid())) {
        fprintf(stderr, "setsid failed: %s\n", strerror(errno));
        return 71;
    }

    execv(argv[1], &argv[1]);
    fprintf(stderr, "execv(%s) failed: %s\n", argv[1], strerror(errno));
    return errno == ENOENT ? 127 : 126;
}
