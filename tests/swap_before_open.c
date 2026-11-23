/*
 * Test helper for the bed2bw symlink regression tests.
 *
 * Built as a shared object, this interposes open/openat. The first time the
 * watched path is opened, the helper replaces that path with a symlink to
 * SWAP_TARGET and only then performs the real open. A check that looked the
 * path up earlier still saw the previous regular file. An open that passes
 * O_NOFOLLOW observes the symlink and does not write the target.
 *
 * Built with -DSWAP_DRIVER, this is a small open() driver used to check the
 * helper itself.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SWAP_DRIVER

static int watched(const char *path) {
    const char *want = getenv("SWAP_PATH");
    return want != NULL && path != NULL && strcmp(path, want) == 0;
}

static void plant_symlink(const char *path) {
    const char *target = getenv("SWAP_TARGET");
    char current[4096];
    ssize_t n;

    if (target == NULL) {
        return;
    }
    n = readlink(path, current, sizeof current - 1);
    if (n >= 0) {
        current[n] = '\0';
        if (strcmp(current, target) == 0) {
            return;
        }
    }
    unlink(path);
    if (symlink(target, path) != 0) {
        return;
    }
}

static int sys_openat(int dirfd, const char *path, int flags, mode_t mode) {
    return syscall(SYS_openat, dirfd, path, flags, mode);
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (watched(path)) {
        plant_symlink(path);
    }
    return sys_openat(AT_FDCWD, path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;

    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (watched(path)) {
        plant_symlink(path);
    }
    return sys_openat(dirfd, path, flags, mode);
}

#else

int main(int argc, char **argv) {
    int flags = O_WRONLY | O_CREAT | O_TRUNC;
    int fd;
    ssize_t wrote;
    const char payload[] = "DRIVER\n";

    if (argc < 2) {
        return 2;
    }
    if (argc > 2 && strcmp(argv[2], "nofollow") == 0) {
        flags |= O_NOFOLLOW;
    }
    fd = open(argv[1], flags, 0644);
    if (fd < 0) {
        return 1;
    }
    wrote = write(fd, payload, sizeof payload - 1);
    close(fd);
    return wrote == (ssize_t)(sizeof payload - 1) ? 0 : 1;
}

#endif
