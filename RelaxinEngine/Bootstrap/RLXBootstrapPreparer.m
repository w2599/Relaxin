//
//  RLXBootstrapPreparer.m
//  RelaxinEngine
//

#import "RLXBootstrapPreparer.h"

#import "RLXBaseBinInstaller.h"
#import "RLXBootstrapArchive.h"
#import "RLXBootstrapPreparationError.h"
#import "RLXBootstrapRootPublisher.h"
#import "RLXBootstrapRootScanner.h"

#import <CoreFoundation/CoreFoundation.h>

#import "../Engine/RLXEngine.h"
#import "../Diagnostic/RLXEngineDiagnostic.h"
#import "../Engine/RLXEngineError.h"
#import "../Log/RLXEngineLog.h"
#import "../KernelAccess/PostExploitation/RLXKernelAccess+DeveloperMode.h"

#include <TargetConditionals.h>
#include <errno.h>
#include <libjailbreak/info.h>
#include <libjailbreak/util.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zstd.h>

#define kCFPreferencesNoContainer CFSTR("kCFPreferencesNoContainer")

void _CFPreferencesSetValueWithContainer(CFStringRef key,
                                         CFPropertyListRef value,
                                         CFStringRef applicationID,
                                         CFStringRef userName,
                                         CFStringRef hostName,
                                         CFStringRef containerPath);
Boolean _CFPreferencesSynchronizeWithContainer(CFStringRef applicationID,
                                               CFStringRef userName,
                                               CFStringRef hostName,
                                               CFStringRef containerPath);

static NSString *const RLXPrimaryRootDirectory = @"/var/containers/Bundle/Application";
static NSString *const RLXSecondaryRootDirectory = @"/var/mobile/Containers/Shared/AppGroup";
static NSString *const RLXInstalledMarker = @".installed_relaxin";
static NSString *const RLXBootstrapArchiveName = @"bootstrap_1900.tar.zst";
static NSString *const RLXBaseBinArchiveName = @"basebin.tar";

typedef struct {
    const char *relativePath;
    mode_t fileType;
    mode_t permissions;
    uid_t owner;
    gid_t group;
} rlx_bootstrap_metadata_expectation;

static const rlx_bootstrap_metadata_expectation RLXExtractedBootstrapMetadata[] = {
    {"usr/bin/chpass", S_IFREG, 04755, 0, 0},
    {"usr/bin/su", S_IFREG, 04755, 0, 0},
    {"usr/bin/quota", S_IFREG, 04755, 0, 0},
    {"usr/bin/sudo", S_IFREG, 04755, 0, 0},
    {"usr/bin/login", S_IFREG, 04755, 0, 0},
    {"usr/bin/passwd", S_IFREG, 04755, 0, 0},
    {"usr/sbin/shshd", S_IFREG, 04755, 0, 0},
    {"tmp", S_IFDIR, 01777, 0, 0},
    {"var/lib/ex", S_IFDIR, 01777, 0, 0},
    {"var/mobile", S_IFDIR, 0755, 501, 501},
};

static const rlx_bootstrap_metadata_expectation RLXPreparedJbctlMetadata = {
    "basebin/jbctl",
    S_IFREG,
    04755,
    0,
    0,
};

static int rlx_validate_directory_at_path(NSString *path, NSString *_Nullable *_Nullable detail) {
    struct stat metadata = {0};
    if (lstat(path.fileSystemRepresentation, &metadata) != 0) {
        int status = errno ?: EIO;
        if (detail) {
            *detail = [NSString stringWithFormat:@"path=%@\nlstat_status=%d", path, status];
        }
        return status;
    }

    mode_t observedType = metadata.st_mode & S_IFMT;
    if (observedType != S_IFDIR) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"path=%@\n" "expected_type=0%o\n" "observed_type=0%o",
                                                 path,
                                                 (unsigned int)S_IFDIR,
                                                 (unsigned int)observedType];
        }
        return ENOTDIR;
    }
    return 0;
}

@interface RLXBootstrapPreparer ()

- (nullable NSString *)installBootstrapWithBrand:(uint64_t *)brand error:(NSError *_Nullable *_Nullable)error;
- (nullable NSString *)rerandomizeRoot:(NSString *)root
                                 brand:(uint64_t *)brand
                                 error:(NSError *_Nullable *_Nullable)error;
- (int)configureBootstrapAtRoot:(NSString *)root
                          brand:(uint64_t)brand
                         detail:(NSString *_Nullable *_Nullable)detail
                     underlying:(NSError *_Nullable *_Nullable)underlying;
- (int)writePackageSourcesAtRoot:(NSString *)root
                          detail:(NSString *_Nullable *_Nullable)detail
                      underlying:(NSError *_Nullable *_Nullable)underlying;
- (int)validateMetadataAtRoot:(NSString *)root
                 expectations:(const rlx_bootstrap_metadata_expectation *)expectations
                        count:(size_t)count
                       detail:(NSString *_Nullable *_Nullable)detail;
- (int)removeIncompatibleFilesystemResidue:(NSString *_Nullable *_Nullable)detail
                                underlying:(NSError *_Nullable *_Nullable)underlying;
- (void)showNonDefaultSystemApps;

@end

@implementation RLXBootstrapPreparer {
    RLXKernelAccess *_Nullable _kernelAccess;
    BOOL _tweakInjectionEnabled;
    RLXBootstrapRootScanner *_rootScanner;
    RLXBootstrapArchive *_archive;
    RLXBaseBinInstaller *_baseBinInstaller;
    RLXBootstrapRootPublisher *_rootPublisher;
}

- (instancetype)initWithKernelAccess:(nullable RLXKernelAccess *)kernelAccess
               tweakInjectionEnabled:(BOOL)tweakInjectionEnabled
                      resourceBundle:(NSBundle *)resourceBundle
               temporaryDirectoryURL:(NSURL *)temporaryDirectoryURL {
    self = [super init];
    if (self) {
        _kernelAccess = kernelAccess;
        _tweakInjectionEnabled = tweakInjectionEnabled;
        _rootScanner = [[RLXBootstrapRootScanner alloc] init];
        _archive = [[RLXBootstrapArchive alloc] initWithResourceBundle:resourceBundle
                                                 temporaryDirectoryURL:temporaryDirectoryURL];
        _baseBinInstaller = [[RLXBaseBinInstaller alloc] initWithResourceBundle:resourceBundle];
        _rootPublisher = [[RLXBootstrapRootPublisher alloc] init];
    }
    return self;
}

- (nullable NSError *)prepare {
#if TARGET_OS_SIMULATOR
    return rlx_bootstrap_preparation_error(@"validate_runtime", ENOTSUP, @"simulator=true", nil);
#else
    RLXKernelAccess *kernelAccess = _kernelAccess;
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE,
                   "RLXBootstrapPreparation",
                   _tweakInjectionEnabled ? "begin tweak_injection=enabled" : "begin tweak_injection=disabled");

    setenv("HOME", "/var/root", 1);
    setenv("CFFIXED_USER_HOME", "/var/root", 1);
    setenv("TMPDIR", "/var/tmp", 1);
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "bootstrap environment variables configured");

    // Dopamine performs this check immediately after platformization.
    if (otherJailbreakActived(true)) {
        return rlx_bootstrap_preparation_error(@"detect_active_jailbreak", EBUSY, @"other_jailbreak_active=true", nil);
    }
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "active jailbreak check passed");

    [self showNonDefaultSystemApps];
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "non-default system apps exposed");

    int status = [kernelAccess enableDeveloperMode];
    if (status != 0) {
        return rlx_bootstrap_preparation_error(@"enable_developer_mode", status, @"developer_mode_enabled=false", nil);
    }
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "developer mode enabled");

    NSString *detail = nil;
    NSError *underlying = nil;
    status = [self removeIncompatibleFilesystemResidue:&detail underlying:&underlying];
    if (status != 0) {
        return rlx_bootstrap_preparation_error(@"remove_incompatible_residue", status, detail, underlying);
    }
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "incompatible filesystem residue removed");

    NSString *installedRoot = nil;
    NSError *error = nil;
    if (![_rootScanner scanJailbreakRootsWithInstalledRoot:&installedRoot error:&error]) {
        return error;
    }

    if (installedRoot) {
        NSString *message = [NSString stringWithFormat:@"installed bootstrap found root=%@", installedRoot];
        rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", message.UTF8String);
        rlx_engine_log(RLX_ENGINE_LOG_INFO, "RLXBootstrapPreparation", "Randomizing Bootstrap");
    } else {
        rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "no installed bootstrap found");
        rlx_engine_log(RLX_ENGINE_LOG_INFO, "RLXBootstrapPreparation", "Extracting Bootstrap");
    }

    uint64_t brand = 0;
    NSString *root = installedRoot ? [self rerandomizeRoot:installedRoot brand:&brand error:&error]
                                   : [self installBootstrapWithBrand:&brand error:&error];
    if (!root) {
        return error;
    }

    detail = nil;
    status = [_rootPublisher publishJailbreakRoot:root brand:brand detail:&detail];
    if (status != 0) {
        return rlx_bootstrap_preparation_error(@"publish_jbroot", status, detail, nil);
    }
    NSString *publishedMessage = [NSString
        stringWithFormat:@"jailbreak root published root=%@ brand=%016llX", root, (unsigned long long)brand];
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", publishedMessage.UTF8String);

    rlx_engine_log(RLX_ENGINE_LOG_INFO, "RLXBootstrapPreparation", "Updating BaseBin");
    detail = nil;
    underlying = nil;
    status = [_baseBinInstaller installBaseBinAtRoot:root detail:&detail underlying:&underlying];
    if (status != 0) {
        return rlx_bootstrap_preparation_error(@"install_basebin", status, detail, underlying);
    }
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "BaseBin updated");

    JBFixMobilePermissions();
    NSString *jbctl = [root stringByAppendingPathComponent:@"basebin/jbctl"];
    if (chmod(jbctl.fileSystemRepresentation, S_ISUID | 0755) != 0) {
        int chmodStatus = errno ?: EIO;
        return rlx_bootstrap_preparation_error(@"set_jbctl_permissions",
                                               chmodStatus,
                                               [NSString stringWithFormat:@"path=%@", jbctl],
                                               nil);
    }

    detail = nil;
    status = [self validateMetadataAtRoot:root expectations:&RLXPreparedJbctlMetadata count:1 detail:&detail];
    if (status != 0) {
        return rlx_bootstrap_preparation_error(@"validate_prepared_basebin", status, detail, nil);
    }
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "jbctl metadata verified");

    setenv("PATH", "/sbin:/bin:/usr/sbin:/usr/bin:/rootfs/sbin:/rootfs/bin:" "/rootfs/usr/sbin:/rootfs/usr/bin", 1);
    setenv("TERM", "xterm-256color", 1);
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", "bootstrap command environment configured");

    if (!_tweakInjectionEnabled) {
        rlx_engine_log(RLX_ENGINE_LOG_VERBOSE,
                       "RLXBootstrapPreparation",
                       "Creating safe mode marker file since tweaks were " "disabled in settings");
        NSString *safeModeMarker = [root stringByAppendingPathComponent:@"basebin/.safe_mode"];
        [[NSData data] writeToFile:safeModeMarker atomically:YES];
    }

    NSString *message = [NSString stringWithFormat:@"bootstrap prepared root=%@ brand=%016llX " "tweak_injection=%@",
                                                   root,
                                                   (unsigned long long)brand,
                                                   _tweakInjectionEnabled ? @"enabled" : @"disabled"];
    rlx_engine_log(RLX_ENGINE_LOG_INFO, "RLXBootstrapPreparation", message.UTF8String);
    return nil;
#endif
}

- (nullable NSString *)installBootstrapWithBrand:(uint64_t *)brand error:(NSError *_Nullable *_Nullable)error {
    uint64_t newBrand = [_rootScanner generateBrand];

    NSString *root = [_rootScanner primaryRootForBrand:newBrand];
    if (mkdir(root.fileSystemRepresentation, 0755) != 0 || chown(root.fileSystemRepresentation, 0, 0) != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"create_primary_jbroot",
                                                     (errno ?: EIO),
                                                     [NSString stringWithFormat:@"root=%@", root],
                                                     nil);
        }
        return nil;
    }

    NSString *detail = nil;
    int status = [_archive extractBootstrapArchiveAtRoot:root detail:&detail];
    if (status != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"extract_bootstrap", status, detail, nil);
        }
        return nil;
    }

    detail = nil;
    status = [self
        validateMetadataAtRoot:root
                  expectations:RLXExtractedBootstrapMetadata
                         count:sizeof(RLXExtractedBootstrapMetadata) / sizeof(RLXExtractedBootstrapMetadata[0])
                        detail:&detail];
    if (status != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"validate_extracted_bootstrap_permissions", status, detail, nil);
        }
        return nil;
    }

    NSError *underlying = nil;
    status = [self configureBootstrapAtRoot:root brand:newBrand detail:&detail underlying:&underlying];
    if (status != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"configure_jbroot", status, detail, underlying);
        }
        return nil;
    }

    underlying = nil;
    status = [self writePackageSourcesAtRoot:root detail:&detail underlying:&underlying];
    if (status != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"write_package_sources", status, detail, underlying);
        }
        return nil;
    }

    *brand = newBrand;
    NSString *message = [NSString
        stringWithFormat:@"installed bootstrap root=%@ brand=%016llX", root, (unsigned long long)newBrand];
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", message.UTF8String);
    return root;
}

- (nullable NSString *)rerandomizeRoot:(NSString *)root
                                 brand:(uint64_t *)brand
                                 error:(NSError *_Nullable *_Nullable)error {
    uint64_t previousBrand = 0;
    if (![_rootScanner rootName:root.lastPathComponent containsBrand:&previousBrand]) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"resolve_existing_jbrand",
                                                     EINVAL,
                                                     [NSString stringWithFormat:@"root=%@", root],
                                                     nil);
        }
        return nil;
    }

    NSString *previousSecondary = [_rootScanner secondaryRootForBrand:previousBrand];
    NSString *topologyDetail = nil;
    int topologyStatus = rlx_validate_directory_at_path(root, &topologyDetail);
    if (topologyStatus == 0) {
        topologyStatus = rlx_validate_directory_at_path(previousSecondary, &topologyDetail);
    }
    if (topologyStatus != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"validate_existing_jbroot_topology",
                                                     topologyStatus,
                                                     topologyDetail,
                                                     nil);
        }
        return nil;
    }

    uint64_t newBrand = [_rootScanner generateBrand];
    NSString *newRoot = [_rootScanner primaryRootForBrand:newBrand];
    NSString *newSecondary = [_rootScanner secondaryRootForBrand:newBrand];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *moveError = nil;
    if (![fileManager moveItemAtPath:root toPath:newRoot error:&moveError]) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"rerandomize_primary_jbroot",
                                                     rlx_status_for_error(moveError),
                                                     [NSString stringWithFormat:@"old=%@\nnew=%@", root, newRoot],
                                                     moveError);
        }
        return nil;
    }

    moveError = nil;
    if (![fileManager moveItemAtPath:previousSecondary toPath:newSecondary error:&moveError]) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"rerandomize_secondary_jbroot",
                                                     rlx_status_for_error(moveError),
                                                     [NSString stringWithFormat:@"old=%@\nnew=%@",
                                                                                previousSecondary,
                                                                                newSecondary],
                                                     moveError);
        }
        return nil;
    }

    NSError *linkError = nil;
    int status = [_rootPublisher replaceExistingSymlinkAtPath:[newRoot stringByAppendingPathComponent:@"private/var"]
                                                       target:[newSecondary stringByAppendingPathComponent:@"var"]
                                                   underlying:&linkError];
    if (status == 0) {
        status = [_rootPublisher replaceExistingSymlinkAtPath:[newSecondary stringByAppendingPathComponent:@".jbroot"]
                                                       target:newRoot
                                                   underlying:&linkError];
    }
    if (status != 0) {
        if (error) {
            *error = rlx_bootstrap_preparation_error(@"update_rerandomized_links",
                                                     status,
                                                     [NSString stringWithFormat:@"root=%@\n" "secondary_root=%@",
                                                                                newRoot,
                                                                                newSecondary],
                                                     linkError);
        }
        return nil;
    }

    *brand = newBrand;
    NSString *message = [NSString stringWithFormat:@"rerandomized jbroot old=%016llX new=%016llX root=%@",
                                                   (unsigned long long)previousBrand,
                                                   (unsigned long long)newBrand,
                                                   newRoot];
    rlx_engine_log(RLX_ENGINE_LOG_VERBOSE, "RLXBootstrapPreparation", message.UTF8String);
    return newRoot;
}

- (int)configureBootstrapAtRoot:(NSString *)root
                          brand:(uint64_t)brand
                         detail:(NSString *_Nullable *_Nullable)detail
                     underlying:(NSError *_Nullable *_Nullable)underlying {
    NSString *secondaryRoot = [_rootScanner secondaryRootForBrand:brand];
    if (mkdir(secondaryRoot.fileSystemRepresentation, 0755) != 0
        || chown(secondaryRoot.fileSystemRepresentation, 0, 0) != 0) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"secondary_root=%@", secondaryRoot];
        }
        return errno ?: EIO;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *error = nil;
    NSString *secondaryVar = [secondaryRoot stringByAppendingPathComponent:@"var"];
    if (![fileManager moveItemAtPath:[root stringByAppendingPathComponent:@"var"] toPath:secondaryVar error:&error]) {
        if (detail) {
            *detail = @"move_var=false";
        }
        if (underlying) {
            *underlying = error;
        }
        return rlx_status_for_error(error);
    }

    int status = [_rootPublisher createSymlinkAtPath:[root stringByAppendingPathComponent:@"var"]
                                              target:@"private/var"];
    if (status == 0) {
        status = [_rootPublisher replaceExistingSymlinkAtPath:[root stringByAppendingPathComponent:@"private/var"]
                                                       target:[secondaryRoot stringByAppendingPathComponent:@"var"]
                                                   underlying:&error];
    }

    NSString *secondaryTemporary = [secondaryVar stringByAppendingPathComponent:@"tmp"];
    if (status == 0) {
        if (![fileManager removeItemAtPath:secondaryTemporary error:&error]) {
            status = rlx_status_for_error(error);
        }
    }
    if (status == 0
        && ![fileManager moveItemAtPath:[root stringByAppendingPathComponent:@"tmp"] toPath:secondaryTemporary
                                  error:&error]) {
        status = rlx_status_for_error(error);
    }
    if (status == 0) {
        status = [_rootPublisher createSymlinkAtPath:[root stringByAppendingPathComponent:@"tmp"] target:@"var/tmp"];
    }
    if (status == 0) {
        status = [_rootPublisher createSymlinkAtPath:[secondaryRoot stringByAppendingPathComponent:@".jbroot"]
                                              target:root];
    }
    if (status != 0) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"root=%@\nsecondary_root=%@", root, secondaryRoot];
        }
        if (underlying) {
            *underlying = error;
        }
        return status;
    }

    NSString *mobilePreferences = [secondaryVar stringByAppendingPathComponent:@"mobile/Library/Preferences"];
    NSDictionary<NSFileAttributeKey, id> *attributes = @{
        NSFilePosixPermissions : @0755,
        NSFileOwnerAccountID : @501,
        NSFileGroupOwnerAccountID : @501,
    };
    if (![fileManager fileExistsAtPath:mobilePreferences]
        && ![fileManager createDirectoryAtPath:mobilePreferences withIntermediateDirectories:YES attributes:attributes
                                         error:&error]) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"mobile_preferences=%@", mobilePreferences];
        }
        if (underlying) {
            *underlying = error;
        }
        return rlx_status_for_error(error);
    }

    return 0;
}

- (int)writePackageSourcesAtRoot:(NSString *)root
                          detail:(NSString *_Nullable *_Nullable)detail
                      underlying:(NSError *_Nullable *_Nullable)underlying {
    // clang-format off
    NSString *defaultSources = @"Types: deb\n"
         "URIs: https://apt.002599.xyz/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: https://apt.owngoal.dev/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: https://yourepo.com/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: https://repo.chariz.com/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: https://havoc.app/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: http://apt.thebigboss.org/repofiles/cydia/\n"
         "Suites: stable\n"
         "Components: main\n\n"
         "Types: deb\n"
         "URIs: https://roothide.github.io/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: https://roothide.github.io/procursus\n"
         "Suites: iphoneos-arm64e/1900\n"
         "Components: main\n";
    // Sileo treats only sileo.sources as user-removable on this bootstrap.
    NSString *sileoSources = @"Types: deb\n"
         "URIs: https://apt.82flex.com/\n"
         "Suites: ./\n"
         "Components:\n\n"
         "Types: deb\n"
         "URIs: "
         "https://github.com/roothide/roothide.github.io/releases/download/"
         "1900/\n"
         "Suites: ./\n"
         "Components:\n";
    NSString *zebraSources = @"# Zebra Sources List\n"
         "deb https://apt.82flex.com/ ./\n"
         "deb https://getzbra.com/repo/ ./\n"
         "deb https://repo.chariz.com/ ./\n"
         "deb https://yourepo.com/ ./\n"
         "deb https://havoc.app/ ./\n"
         "deb https://roothide.github.io/ ./\n"
         "deb https://roothide.github.io/procursus "
         "iphoneos-arm64e/1900 main\n"
         "deb "
         "https://github.com/roothide/roothide.github.io/releases/download/"
         "1900/ ./\n\n";
    // clang-format on

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *error = nil;
    NSString *aptDirectory = [root stringByAppendingPathComponent:@"etc/apt/sources.list.d"];
    NSString *aptSources = [aptDirectory stringByAppendingPathComponent:@"default.sources"];
    if (![defaultSources writeToFile:aptSources atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"apt_sources=%@", aptSources];
        }
        if (underlying) {
            *underlying = error;
        }
        return rlx_status_for_error(error);
    }

    NSString *sileoPath = [aptDirectory stringByAppendingPathComponent:@"sileo.sources"];
    if (![sileoSources writeToFile:sileoPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"sileo_sources=%@", sileoPath];
        }
        if (underlying) {
            *underlying = error;
        }
        return rlx_status_for_error(error);
    }

    NSString *zebraDirectory = [root
        stringByAppendingPathComponent:@"var/mobile/Library/Application Support/xyz.willy.Zebra"];
    NSDictionary<NSFileAttributeKey, id> *attributes = @{
        NSFilePosixPermissions : @0755,
        NSFileOwnerAccountID : @501,
        NSFileGroupOwnerAccountID : @501,
    };
    if (![fileManager fileExistsAtPath:zebraDirectory]
        && ![fileManager createDirectoryAtPath:zebraDirectory withIntermediateDirectories:YES attributes:attributes
                                         error:&error]) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"zebra_directory=%@", zebraDirectory];
        }
        if (underlying) {
            *underlying = error;
        }
        return rlx_status_for_error(error);
    }
    NSString *zebraPath = [zebraDirectory stringByAppendingPathComponent:@"sources.list"];
    if (![zebraSources writeToFile:zebraPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        if (detail) {
            *detail = [NSString stringWithFormat:@"zebra_sources=%@", zebraPath];
        }
        if (underlying) {
            *underlying = error;
        }
        return rlx_status_for_error(error);
    }
    return 0;
}

- (int)validateMetadataAtRoot:(NSString *)root
                 expectations:(const rlx_bootstrap_metadata_expectation *)expectations
                        count:(size_t)count
                       detail:(NSString *_Nullable *_Nullable)detail {
    for (size_t index = 0; index < count; index++) {
        const rlx_bootstrap_metadata_expectation *expectation = &expectations[index];
        NSString *relativePath = [NSString stringWithUTF8String:expectation->relativePath];
        NSString *path = [root stringByAppendingPathComponent:relativePath];
        struct stat metadata = {0};
        if (lstat(path.fileSystemRepresentation, &metadata) != 0) {
            int status = errno ?: EIO;
            if (detail) {
                *detail = [NSString
                    stringWithFormat:
                        @"path=%@\n" "expected_type=0%o\n" "expected_mode=0%o\n" "expected_uid=%u\n" "expected_gid=%u\n" "lstat_status=%d",
                        path,
                        (unsigned int)expectation->fileType,
                        (unsigned int)expectation->permissions,
                        expectation->owner,
                        expectation->group,
                        status];
            }
            return status;
        }

        mode_t observedType = metadata.st_mode & S_IFMT;
        mode_t observedPermissions = metadata.st_mode & 07777;
        if (observedType != expectation->fileType || observedPermissions != expectation->permissions
            || metadata.st_uid != expectation->owner || metadata.st_gid != expectation->group) {
            if (detail) {
                *detail = [NSString
                    stringWithFormat:
                        @"path=%@\n" "expected_type=0%o\n" "observed_type=0%o\n" "expected_mode=0%o\n" "observed_mode=0%o\n" "expected_uid=%u\n" "observed_uid=%u\n" "expected_gid=%u\n" "observed_gid=%u",
                        path,
                        (unsigned int)expectation->fileType,
                        (unsigned int)observedType,
                        (unsigned int)expectation->permissions,
                        (unsigned int)observedPermissions,
                        expectation->owner,
                        metadata.st_uid,
                        expectation->group,
                        metadata.st_gid];
            }
            return EPERM;
        }
    }
    return 0;
}

- (int)removeIncompatibleFilesystemResidue:(NSString *_Nullable *_Nullable)detail
                                underlying:(NSError *_Nullable *_Nullable)underlying {
    NSError *error = nil;
    if (![_rootPublisher deleteSymlinkAtPath:@"/var/jb" error:&error]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"]) {
            if (![NSFileManager.defaultManager removeItemAtPath:@"/var/jb" error:&error]) {
                if (detail) {
                    *detail = @"/var/jb_removed=false";
                }
                if (underlying) {
                    *underlying = error;
                }
                return rlx_status_for_error(error);
            }
        } else {
            if (detail) {
                *detail = @"/var/jb_symlink_removed=false";
            }
            if (underlying) {
                *underlying = error;
            }
            return rlx_status_for_error(error);
        }
    }

    NSArray<NSString *> *legacySymlinks = @[
        @"/var/alternatives", @"/var/ap",      @"/var/apt",     @"/var/bin",      @"/var/bzip2",
        @"/var/cache",        @"/var/dpkg",    @"/var/etc",     @"/var/gzip",     @"/var/lib",
        @"/var/Lib",          @"/var/libexec", @"/var/Library", @"/var/LIY",      @"/var/Liy",
        @"/var/local",        @"/var/newuser", @"/var/profile", @"/var/sbin",     @"/var/suid_profile",
        @"/var/sh",           @"/var/sy",      @"/var/share",   @"/var/ssh",      @"/var/sudo_logsrvd.conf",
        @"/var/suid_profile", @"/var/sy",      @"/var/usr",     @"/var/zlogin",   @"/var/zlogout",
        @"/var/zprofile",     @"/var/zshenv",  @"/var/zshrc",   @"/var/log/dpkg", @"/var/log/apt",
    ];
    for (NSString *path in legacySymlinks) {
        [_rootPublisher deleteSymlinkAtPath:path error:nil];
    }

    for (NSString *path in @[
             @"/var/lib",
             @"/var/master.passwd",
             @"/var/.keep_symlinks",
         ]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
    }
    return 0;
}

- (void)showNonDefaultSystemApps {
    _CFPreferencesSetValueWithContainer(CFSTR("SBShowNonDefaultSystemApps"),
                                        kCFBooleanTrue,
                                        CFSTR("com.apple.springboard"),
                                        CFSTR("mobile"),
                                        kCFPreferencesAnyHost,
                                        kCFPreferencesNoContainer);
    _CFPreferencesSynchronizeWithContainer(CFSTR("com.apple.springboard"),
                                           CFSTR("mobile"),
                                           kCFPreferencesAnyHost,
                                           kCFPreferencesNoContainer);
}

@end
