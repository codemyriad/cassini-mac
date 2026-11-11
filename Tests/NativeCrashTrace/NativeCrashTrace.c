#include "NativeCrashTrace.h"
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdio.h>
#include <sys/resource.h>

static void fatal_trace(int number) {
    static const char marker[] = "NATIVE_TEST_FATAL_STACK\n";
    (void)write(STDERR_FILENO, marker, sizeof(marker)-1);
    void *frames[96];
    int count = backtrace(frames, 96);
    backtrace_symbols_fd(frames, count, STDERR_FILENO);
    /* SA_RESETHAND preserves the original fatal outcome after diagnostics. */
    kill(getpid(), number);
}
void install_native_test_crash_trace(void) {
    void *warm[8]; (void)backtrace(warm, 8);
    Dl_info image;
    if (dladdr((void *)install_native_test_crash_trace, &image))
        fprintf(stderr,"TEST_TRACE_IMAGE %p %s\n",image.dli_fbase,image.dli_fname);
    struct rlimit files;
    if (getrlimit(RLIMIT_NOFILE,&files)==0)
        fprintf(stderr,"TEST_TRACE_FD_LIMIT %llu %llu\n",(unsigned long long)files.rlim_cur,(unsigned long long)files.rlim_max);
    struct sigaction action = {0};
    action.sa_handler = fatal_trace;
    action.sa_flags = SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    sigaction(SIGBUS,&action,0);
    sigaction(SIGSEGV,&action,0);
}
