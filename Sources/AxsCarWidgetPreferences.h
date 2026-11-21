#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

// Airaw keeps module preferences in /Library/Airaw/Preferences next to its own plists.
// The panel and the widget both write that file (inter-process serialised, see below).
static NSString * const AxsCarWidgetPreferencesDomain = @"com.axs.carwidget";
static NSString * const AxsCarWidgetPreferencesChanged = @"com.axs.carwidget.preferences-changed";
static NSString * const AxsCarWidgetPreferencesLogicalPath =
    @"/Library/Airaw/Preferences/com.axs.carwidget.plist";
// Cross-process read-modify-write lock (flock), so panel edits and weather fetches cannot
// overwrite each other's keys.
static NSString * const AxsCarWidgetPreferencesLockPath =
    @"/tmp/com.axs.carwidget.write.lock";

#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
static inline NSString *AxsCarWidgetRootPath(NSString *path) { return jbroot(path); }
#else
#import <rootless.h>
static inline NSString *AxsCarWidgetRootPath(NSString *path) { return ROOT_PATH_NS_VAR(path); }
#endif

// Widget install layout: /Library/Airaw/Widgets/Controls/<bundle>/<executable>
static inline NSString *axs_carwidget_preferencesPath(void) {
    return AxsCarWidgetRootPath(AxsCarWidgetPreferencesLogicalPath);
}

static inline NSDictionary *axs_carwidget_readPreferences(void) {
    NSString *path = axs_carwidget_preferencesPath();
    NSDictionary *values = path.length > 0 ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if ([values isKindOfClass:[NSDictionary class]]) {
        return values;
    }
    // Compatibility fallback, not a second writable file location.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsCarWidgetPreferencesDomain];
    [defaults synchronize];
    return [defaults persistentDomainForName:AxsCarWidgetPreferencesDomain] ?: @{};
}

#pragma mark - Writer

// Returns a file descriptor holding the lock, or -1 when locking is unavailable.
static inline int axs_carwidget_lockPreferences(void) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    NSString *path = jbroot(AxsCarWidgetPreferencesLockPath);
#else
    NSString *path = AxsCarWidgetPreferencesLockPath;
#endif
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return -1;
    for (int attempt = 0; attempt < 50; attempt++) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
        usleep(20 * 1000);
    }
    close(fd);
    return -1;
}

static inline void axs_carwidget_unlockPreferences(int fd) {
    if (fd < 0) return;
    flock(fd, LOCK_UN);
    close(fd);
}

// Merges `changes` into the canonical file. A nil value removes the key.
// The panel and the weather fetcher both go through this function.
static inline BOOL axs_carwidget_updatePreferences(NSDictionary *changes, NSError **error) {
    NSString *path = axs_carwidget_preferencesPath();
    if (path.length == 0 || changes.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsCarWidgetPreferencesDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference path"}];
        }
        return NO;
    }

    int lock = axs_carwidget_lockPreferences();
    BOOL success = NO;
    NSMutableDictionary *values = nil;
    NSData *existing = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (existing) {
        id decoded = [NSPropertyListSerialization propertyListWithData:existing
                         options:NSPropertyListMutableContainers format:NULL error:error];
        if (![decoded isKindOfClass:[NSDictionary class]]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:AxsCarWidgetPreferencesDomain code:2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Preferences are not a dictionary"}];
            }
            axs_carwidget_unlockPreferences(lock);
            return NO;
        }
        values = [decoded mutableCopy];
    } else {
        values = [axs_carwidget_readPreferences() mutableCopy];
    }
    if (![values isKindOfClass:[NSMutableDictionary class]]) values = [NSMutableDictionary dictionary];

    for (NSString *key in changes) {
        id value = changes[key];
        if (value == nil || value == [NSNull null]) [values removeObjectForKey:key];
        else values[key] = value;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = [path stringByDeletingLastPathComponent];
    NSData *data = nil;
    if ([manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                            attributes:nil error:error]) {
        data = [NSPropertyListSerialization dataWithPropertyList:values
                       format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        success = data && [data writeToFile:path options:NSDataWritingAtomic error:error];
    }
    axs_carwidget_unlockPreferences(lock);

    if (success) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsCarWidgetPreferencesDomain];
        // Mirror the whole snapshot so cfprefsd cannot flush stale unrelated keys.
        [defaults setPersistentDomain:values forName:AxsCarWidgetPreferencesDomain];
        [defaults synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)AxsCarWidgetPreferencesChanged, NULL, NULL, true);
    }
    return success;
}

static inline BOOL axs_carwidget_writePreference(NSString *key, id value, NSError **error) {
    if (key.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsCarWidgetPreferencesDomain code:1
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid preference key"}];
        }
        return NO;
    }
    return axs_carwidget_updatePreferences(@{ key : value ?: [NSNull null] }, error);
}
