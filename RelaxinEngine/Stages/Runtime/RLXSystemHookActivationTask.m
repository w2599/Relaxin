//
//  RLXSystemHookActivationTask.m
//  RelaxinEngine
//

#import "RLXSystemHookActivationTask.h"

#import "../../Engine/RLXEngine.h"
#import "../../Diagnostic/RLXEngineDiagnostic.h"
#import "../../Engine/RLXEngineError.h"
#import "../../Log/RLXEngineLog.h"
#import "../../Engine/RLXEngineRunContext.h"

#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

#include <libjailbreak/roothider/common.h>
#include <libjailbreak/util.h>

static const char *const RLXSystemHookActivationLogCategory = "SystemHookActivation";

static NSError *rlx_systemhook_activation_error(NSString *phase, int status) {
    NSString *message = [NSString stringWithFormat:@"failed phase=%@ status=%d", phase, status];
    rlx_engine_log(RLX_ENGINE_LOG_ERROR, RLXSystemHookActivationLogCategory, message.UTF8String);
    RLXEngineDiagnostic *diagnostic = [RLXEngineDiagnostic diagnostic];
    [diagnostic appendPhase:phase];
    [diagnostic appendStatus:status];
    return [RLXEngineError errorWithCode:RLXEngineErrorCodeSystemHookActivationFailed
                             description:@"The SystemHook execution environment could not be " "activated."
                           failureReason:[NSString stringWithFormat:@"%@ failed with status %d.", phase, status]
                      recoverySuggestion:@"Reboot the device before retrying the jailbreak."
                              diagnostic:diagnostic];
}

@implementation RLXSystemHookActivationTask

- (instancetype)initWithContext:(RLXEngineRunContext *)context {
    return [super initWithStage:RLXEngineStageSystemHookActivation context:context];
}

- (nullable NSError *)execute {
    const char *systemHookPath = JBROOT_PATH("/basebin/systemhook.dylib");
    rlx_engine_log(RLX_ENGINE_LOG_INFO,
                   RLXSystemHookActivationLogCategory,
                   "activating SystemHook with stock dyld; patched-dyld generation and trust are disabled");

    if (access(systemHookPath, R_OK) != 0) {
        int status = errno ?: ENOENT;
        NSString *message = [NSString
            stringWithFormat:@"SystemHook is unavailable path=%s status=%d", systemHookPath, status];
        rlx_engine_log(RLX_ENGINE_LOG_ERROR, RLXSystemHookActivationLogCategory, message.UTF8String);
        return rlx_systemhook_activation_error(@"locate_systemhook", status);
    }

    NSString *systemHookMessage = [NSString stringWithFormat:@"SystemHook payload ready path=%s", systemHookPath];
    rlx_engine_log(RLX_ENGINE_LOG_INFO, RLXSystemHookActivationLogCategory, systemHookMessage.UTF8String);

    // This flag controls child preparation, not dyld replacement. In the
    // stock-dyld path it suspends children long enough to apply
    // CS_GET_TASK_ALLOW before SystemHook is loaded.
    exec_set_patch(true);
    rlx_engine_log(RLX_ENGINE_LOG_INFO,
                   RLXSystemHookActivationLogCategory,
                   "enabled stock-dyld child preparation via CS_GET_TASK_ALLOW");

    setenv("DYLD_IN_CACHE", "0", 1);
    setenv("DISABLE_TWEAKS", "1", 1);
    setenv("DYLD_INSERT_LIBRARIES", systemHookPath, 1);
    rlx_engine_log(RLX_ENGINE_LOG_INFO,
                   RLXSystemHookActivationLogCategory,
                   "configured stock-dyld SystemHook injection environment; restarting iconservicesagent");

    int status = exec_cmd_trusted(JBROOT_PATH("/usr/bin/killall"), "-9", "iconservicesagent", NULL);
    NSString *restartMessage = [NSString
        stringWithFormat:@"iconservicesagent restart request completed status=%d", status];
    rlx_engine_log(status == 0 ? RLX_ENGINE_LOG_INFO : RLX_ENGINE_LOG_WARNING,
                   RLXSystemHookActivationLogCategory,
                   restartMessage.UTF8String);

    // Create the root hide directory if it doesn't exist
    [self createRootHideDirIfNeeded];
    // Initialize the whitelist system injection
    [self initializeWhitelistSystemInjection];
    // Initialize the wants blacklist
    [self initializeWhitelistWantsBlacklist];
    // Initialize the jetsam addend
    [self initializeJetsamAddend];
    // Set root hide directory ownership
    [self setRootHideDirOwnership];
    // Applying the custom mount
    [self setCustomMount];

    rlx_engine_log(RLX_ENGINE_LOG_INFO,
                   RLXSystemHookActivationLogCategory,
                   "SystemHook activation completed policy=stock-dyld patched_dyld=disabled");
    return nil;
}

- (void)createRootHideDirIfNeeded
{
    NSString *rootHidePath = JBROOT_PATH(@"/var/mobile/Library/RootHide");
    if (![[NSFileManager defaultManager] fileExistsAtPath:rootHidePath]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:rootHidePath withIntermediateDirectories:YES attributes:nil error:nil];
        [self setRootHideDirOwnership];
    }
}

- (void)initializeWhitelistSystemInjection
{
    NSString *systemInjectPath = JBROOT_PATH(@"/var/mobile/Library/RootHide/cn.zqbb.inject.system.plist");

    // Bug fix. To be removed in the next version.
    NSMutableDictionary *defaultWhitelist = [NSMutableDictionary dictionaryWithContentsOfFile:systemInjectPath];
    if (defaultWhitelist) {
        for (NSString *key in defaultWhitelist.allKeys) {
            if ([key hasPrefix:@"/.relaxin"]) {
                [defaultWhitelist removeObjectForKey:key];
                defaultWhitelist[@"/.jbroot"] = @YES;
                [defaultWhitelist writeToFile:systemInjectPath atomically:YES];
            }
            else if ([key hasPrefix:@"/Ralaxin"]) {
                [defaultWhitelist removeObjectForKey:key];
                defaultWhitelist[@"/Relaxin"] = @YES;
                [defaultWhitelist writeToFile:systemInjectPath atomically:YES];
            }
        }
    }


    if (![[NSFileManager defaultManager] fileExistsAtPath:systemInjectPath]) {
        NSMutableDictionary *defaultWhitelist = [NSMutableDictionary dictionary];
        NSArray *defaultItems = @[
            @"/.jbroot", @"/xpcproxy", @"/Relaxin", @"/SpringBoard", @"/Preferences",
            @"/amfid", @"/cfprefsd", @"/lsd", @"/transitd", @"/watchdogd", @"/SafariViewService",
            @"/iconservicesagent", @"/mobileassetd", @"/MobileGestaltHelper", @"/useractivityd"
        ];

        for (NSString *item in defaultItems) {
            if ([item isKindOfClass:[NSString class]] && item.length > 0) {
                defaultWhitelist[item] = @YES;
            }
        }

        [defaultWhitelist writeToFile:systemInjectPath atomically:YES];
    }
}

- (void)initializeWhitelistWantsBlacklist
{
    NSString *wantsblacklistPath = JBROOT_PATH(@"/var/mobile/Library/RootHide/cn.zqbb.inject.wantsblacklist.plist");

    if (![[NSFileManager defaultManager] fileExistsAtPath:wantsblacklistPath]) {
        NSMutableDictionary *defaultWantsblacklist = [NSMutableDictionary dictionary];
        NSArray *defaultItems = @[
            @"QQ",
            @"WeChat",
            @"Runner",
            @"AppStore"
        ];

        for (NSString *item in defaultItems) {
            if ([item isKindOfClass:[NSString class]] && item.length > 0) {
                defaultWantsblacklist[item] = @YES;
            }
        }

        [defaultWantsblacklist writeToFile:wantsblacklistPath atomically:YES];
    }
}

- (void)initializeJetsamAddend
{
    NSString *prefPath = JBROOT_PATH(@"/var/mobile/Library/RootHide/cn.zqbb.jetsam.addend.plist");

    if (![[NSFileManager defaultManager] fileExistsAtPath:prefPath]) {
        NSDictionary *defaultJetsamAddend = @{
            @"/SpringBoard": @(1024),
            @"/xxtouch": @(48),
            @"/thermalmonitord": @(16)
        };

        [defaultJetsamAddend writeToFile:prefPath atomically:YES];
    }
}

- (void)setRootHideDirOwnership
{    
    exec_cmd_trusted(JBROOT_PATH("/usr/sbin/chmod"), "-R", "644", JBROOT_PATH("/var/mobile/Library/RootHide"), NULL);
    exec_cmd_trusted(JBROOT_PATH("/usr/sbin/chown"), "-R", "501:501", JBROOT_PATH("/var/mobile/Library/RootHide"), NULL);
}

- (void)setCustomMount // zqbb_flag
{
    const char *flagPath = JBROOT_PATH("/mnt/.zqbbJailbreak");
    const char *mntDaemonPath = JBROOT_PATH("/usr/bin/HelloMntDaemon");
    if (access(flagPath, F_OK) != 0) {
        exec_cmd_trusted(JBROOT_PATH("/usr/bin/touch"), flagPath, NULL);
    }
    else if (access(mntDaemonPath, F_OK) == 0) {
        exec_cmd_trusted(mntDaemonPath, "remountAll", NULL);
        rlx_engine_log(RLX_ENGINE_LOG_INFO,
                       RLXSystemHookActivationLogCategory,
                       "HelloMntDaemon remountAll request completed");
    }
}
@end
