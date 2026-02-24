#import <Foundation/Foundation.h>

#include <signal.h>
#include <setjmp.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <execinfo.h>
#include <pthread.h>
#ifdef __cplusplus
#include <exception>
#endif

// ─────────────────────────────────────────────
// MARK: - Logging
// ─────────────────────────────────────────────

static void ue4_log(const char *message) {
    NSLog(@"[UE4CrashSuppressor] %s", message);
}

static void ue4_print_backtrace(void) {
    void *callstack[64];
    int frames = backtrace(callstack, 64);
    char **symbols = backtrace_symbols(callstack, frames);
    ue4_log("──── Backtrace ────");
    for (int i = 0; i < frames; i++) {
        NSLog(@"  %s", symbols[i]);
    }
    free(symbols);
}

// ─────────────────────────────────────────────
// MARK: - Signal jump buffer
// ─────────────────────────────────────────────

static sigjmp_buf gRecoveryPoint;
static volatile sig_atomic_t gRecoveryPointSet = 0;

// ─────────────────────────────────────────────
// MARK: - Universal signal handler
// ─────────────────────────────────────────────

static void universal_signal_handler(int sig, siginfo_t *info, void *context) {
    const char *sigName = "UNKNOWN";
    switch (sig) {
        case SIGABRT: sigName = "SIGABRT"; break;
        case SIGSEGV: sigName = "SIGSEGV"; break;
        case SIGBUS:  sigName = "SIGBUS";  break;
        case SIGILL:  sigName = "SIGILL";  break;
        case SIGFPE:  sigName = "SIGFPE";  break;
        case SIGPIPE: sigName = "SIGPIPE"; break;
        case SIGTRAP: sigName = "SIGTRAP"; break;
    }

    char msg[256];
    snprintf(msg, sizeof(msg),
             "Caught signal %d (%s) — suppressing crash.", sig, sigName);
    ue4_log(msg);
    ue4_print_backtrace();

    // Re-register handler (some systems reset to SIG_DFL after delivery)
    struct sigaction sa;
    sa.sa_sigaction = universal_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigaction(sig, &sa, NULL);

    // Unblock the signal so we can receive it again later
    sigset_t unblock;
    sigemptyset(&unblock);
    sigaddset(&unblock, sig);
    pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);

    // Jump back to the recovery point if one was set
    if (gRecoveryPointSet) {
        siglongjmp(gRecoveryPoint, sig);
    }

    // Otherwise just return — for SIGABRT this swallows the abort()
}

// ─────────────────────────────────────────────
// MARK: - abort() override via DYLD interpose
//         (works on Simulator; use fishhook for real device)
// ─────────────────────────────────────────────

__attribute__((visibility("default")))
void abort(void) {
    ue4_log("abort() called — suppressing.");
    ue4_print_backtrace();
    // Raise SIGABRT so our handler fires, then return instead of dying
    raise(SIGABRT);
}

__attribute__((used))
static const struct {
    const void *replacement;
    const void *replacee;
} interpose_abort
__attribute__((section("__DATA,__interpose"))) = {
    (const void *)(uintptr_t)abort,
    (const void *)(uintptr_t)abort
};

// ─────────────────────────────────────────────
// MARK: - ObjC uncaught exception handler
// ─────────────────────────────────────────────

static void ue4_objc_exception_handler(NSException *exception) {
    NSLog(@"[UE4CrashSuppressor] Uncaught ObjC exception: %@\n%@",
          exception.reason,
          exception.callStackSymbols);
    // Swallow — do NOT re-throw
}

// ─────────────────────────────────────────────
// MARK: - C++ terminate handler
// ─────────────────────────────────────────────

#ifdef __cplusplus
static void ue4_cpp_terminate_handler(void) {
    ue4_log("std::terminate() called — attempting to suppress.");
    ue4_print_backtrace();
    try {
        throw;
    } catch (const std::exception &e) {
        NSLog(@"[UE4CrashSuppressor] C++ exception: %s", e.what());
    } catch (...) {
        ue4_log("C++ exception of unknown type.");
    }
    // Return instead of calling abort() — keeps the process alive (UB but functional)
}
#endif

// ─────────────────────────────────────────────
// MARK: - Install function (call this FIRST, before UE4 init)
// ─────────────────────────────────────────────

static void UE4CrashSuppressor_Install(void) {
    ue4_log("Installing crash suppressor...");

    struct sigaction sa;
    sa.sa_sigaction = universal_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_RESTART;

    int signals[] = {
        SIGABRT,
        SIGSEGV,
        SIGBUS,
        SIGILL,
        SIGFPE,
        SIGPIPE,
        SIGTRAP,
        -1  // sentinel
    };

    for (int i = 0; signals[i] != -1; i++) {
        if (sigaction(signals[i], &sa, NULL) != 0) {
            char msg[64];
            snprintf(msg, sizeof(msg),
                     "Failed to install handler for signal %d", signals[i]);
            ue4_log(msg);
        }
    }

    // ObjC uncaught exception handler
    NSSetUncaughtExceptionHandler(&ue4_objc_exception_handler);

    // C++ terminate handler
#ifdef __cplusplus
    std::set_terminate(ue4_cpp_terminate_handler);
#endif

    ue4_log("Crash suppressor installed successfully.");
}

// ─────────────────────────────────────────────
// MARK: - Recovery point setter
//         Call at the top of your main game loop tick.
//         On a fatal signal, execution resumes here
//         instead of crashing the process.
// ─────────────────────────────────────────────

static void UE4CrashSuppressor_SetRecoveryPoint(void) {
    gRecoveryPointSet = 0;
    int sig = sigsetjmp(gRecoveryPoint, 1);
    if (sig != 0) {
        char msg[128];
        snprintf(msg, sizeof(msg),
                 "Recovered from signal %d — resuming game loop.", sig);
        ue4_log(msg);
    }
    gRecoveryPointSet = 1;
}

// ─────────────────────────────────────────────
// MARK: - Objective-C wrapper class
// ─────────────────────────────────────────────

@interface UE4CrashSuppressor : NSObject
+ (void)install;
+ (void)setRecoveryPoint;
@end

@implementation UE4CrashSuppressor

+ (void)install {
    UE4CrashSuppressor_Install();
}

+ (void)setRecoveryPoint {
    UE4CrashSuppressor_SetRecoveryPoint();
}

@end

// ─────────────────────────────────────────────
// MARK: - Auto-install on load via +load
//         Runs before main() and before UE4 init,
//         so the suppressor is active as early as possible.
// ─────────────────────────────────────────────

@interface UE4CrashSuppressorAutoInstaller : NSObject
@end

@implementation UE4CrashSuppressorAutoInstaller

+ (void)load {
    UE4CrashSuppressor_Install();
}

@end
