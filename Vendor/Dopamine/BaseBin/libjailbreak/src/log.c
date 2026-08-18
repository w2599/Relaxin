#include "log.h"

#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syslimits.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define LOGGING_DIR "/var/log"

static const char *JBLogGetProcessName(void) {
    static char *processName = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t length = 0;
        _NSGetExecutablePath(NULL, &length);
        char *path = malloc(length);
        if (!path || _NSGetExecutablePath(path, &length) != 0) {
            free(path);
            processName = strdup("unknown");
            return;
        }

        const char *lastComponent = strrchr(path, '/');
        processName = strdup(lastComponent ? lastComponent + 1 : path);
        free(path);
    });
    return processName;
}

static void JBLogGetLogFilePath(const char *suffix, char path[PATH_MAX]) {
    struct timeval timestamp = {0};
    gettimeofday(&timestamp, NULL);
    snprintf(path,
             PATH_MAX,
             "%s/%s-%lu.%d-%d%s.log",
             LOGGING_DIR,
             JBLogGetProcessName(),
             timestamp.tv_sec,
             timestamp.tv_usec,
             getpid(),
             suffix);
}

static const char *JBLogGetDebugLogFilePath(void) {
    static char path[PATH_MAX] = {0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        JBLogGetLogFilePath("", path);
    });
    return path;
}

static const char *JBLogGetErrorLogFilePath(void) {
    static char path[PATH_MAX] = {0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        JBLogGetLogFilePath("-error", path);
    });
    return path;
}

static void JBLogV(const char *path, const char *level, const char *format, va_list arguments) {
    FILE *logFile = fopen(path, "a");
    if (!logFile)
        return;

    uint64_t tid = 0;
    pthread_threadid_np(pthread_self(), &tid);
    fprintf(logFile, "[%lu] [%u] [%llu] [%s] ", time(NULL), getpid(), tid, level);
    vfprintf(logFile, format, arguments);
    fputc('\n', logFile);
    fclose(logFile);
}

void JBLogDebugFunction(const char *format, ...) {
#if DEBUG
    va_list arguments;
    va_start(arguments, format);
    JBLogV(JBLogGetDebugLogFilePath(), "DEBUG", format, arguments);
    va_end(arguments);
#else
    (void)format;
#endif
}

void JBLogErrorFunction(const char *format, ...) {
#if DEBUG
    va_list arguments;
    va_start(arguments, format);
    JBLogV(JBLogGetErrorLogFilePath(), "ERROR", format, arguments);
    va_end(arguments);
#else
    (void)format;
#endif
}
