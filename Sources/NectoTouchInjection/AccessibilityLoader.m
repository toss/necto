//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if __has_include(<UIKit/UIKit.h>)
#import "TouchInjector.h"
#import <dlfcn.h>
#import <objc/message.h>

@implementation NectoAccessibilityLoader
+ (void)prepare {
    NSAssert(NSThread.isMainThread, @"Accessibility loading requires the main thread");
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Enable this process's accessibility data without changing device-wide settings.
        void *library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY | RTLD_LOCAL);
        void (*enable)(BOOL) = library ? dlsym(library, "_AXSApplicationAccessibilitySetEnabled") : NULL;
        if (enable) enable(YES);
        UIApplication *app = UIApplication.sharedApplication;
        SEL initialize = NSSelectorFromString(@"_accessibilityInit");
        if ([app respondsToSelector:initialize]) {
            ((void (*)(id, SEL))objc_msgSend)(app, initialize);
        }
    });
}
@end
#endif
