#include "log.h"

#include <stdarg.h>
#include <syslog.h>

void JBLogDebugFunction(const char *format, ...) __attribute__((format(printf, 1, 2)));
void JBLogErrorFunction(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void systemhook_vlog(int priority, const char *format, va_list arguments)
{
    openlog("systemhook", LOG_PID, LOG_AUTH);
    vsyslog(priority, format, arguments);
    closelog();
}

void SystemHookLogDebugFunction(const char *format, ...)
{
#if DEBUG
    va_list args;
    va_start(args, format);
    systemhook_vlog(LOG_DEBUG, format, args);
    va_end(args);
#else
    (void)format;
#endif
}

void SystemHookLogErrorFunction(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    systemhook_vlog(LOG_ERR, format, args);
    va_end(args);
}

void JBLogDebugFunction(const char *format, ...)
{
#if DEBUG
    va_list args;
    va_start(args, format);
    systemhook_vlog(LOG_DEBUG, format, args);
    va_end(args);
#else
    (void)format;
#endif
}

void JBLogErrorFunction(const char *format, ...)
{
#if DEBUG
    va_list args;
    va_start(args, format);
    systemhook_vlog(LOG_ERR, format, args);
    va_end(args);
#else
    (void)format;
#endif
}
