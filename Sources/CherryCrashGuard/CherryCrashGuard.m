#import "CherryCrashGuard.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef void (*CherryRemoteViewOrderFunction)(id, SEL, id);

static CherryRemoteViewOrderFunction CherryOriginalRemoteViewOrder;
static SEL CherryRemoteViewOrderSelector;
static BOOL CherryRemoteViewCrashGuardInstalled;
static id CherryBundleLoadObserver;

BOOL CherryShouldSuppressRemoteViewException(NSException *exception) {
    NSString *reason = exception.reason ?: @"";
    NSString *callStack = [exception.callStackSymbols componentsJoinedByString:@"\n"] ?: @"";
    NSString *details = [reason stringByAppendingFormat:@"\n%@", callStack];

    return [exception.name isEqualToString:NSInternalInconsistencyException]
        && [details containsString:@"NSRemoteView"]
        && [details containsString:@"containingWindowWillOrderOnScreen"];
}

static void CherryGuardedRemoteViewOrder(id receiver, SEL selector, id window) {
    @try {
        CherryOriginalRemoteViewOrder(receiver, CherryRemoteViewOrderSelector, window);
    } @catch (NSException *exception) {
        // macOS 27 betas can leave the system text-completion remote view tied to
        // a stale window. Suppress only that known ViewBridge assertion; every
        // unrelated Objective-C exception must retain its normal behavior.
        if (!CherryShouldSuppressRemoteViewException(exception)) {
            @throw exception;
        }

        NSLog(@"Cherry suppressed the macOS 27 NSRemoteView window-ordering assertion: %@",
              exception.reason);
    }
}

static void CherryTryInstallRemoteViewCrashGuard(void) {
    @synchronized ([NSApplication class]) {
        if (CherryRemoteViewCrashGuardInstalled) {
            return;
        }

        Class remoteViewClass = NSClassFromString(@"NSRemoteView");
        if (remoteViewClass == Nil) {
            return;
        }

        SEL selector = NSSelectorFromString(@"containingWindowWillOrderOnScreen:");
        Method method = class_getInstanceMethod(remoteViewClass, selector);
        if (method == NULL) {
            return;
        }

        CherryRemoteViewOrderSelector = selector;
        CherryOriginalRemoteViewOrder = (CherryRemoteViewOrderFunction)method_getImplementation(method);
        method_setImplementation(method, (IMP)CherryGuardedRemoteViewOrder);
        CherryRemoteViewCrashGuardInstalled = YES;

        NSLog(@"Cherry installed the macOS 27 NSRemoteView crash guard");
    }
}

void CherryInstallRemoteViewCrashGuard(void) {
    static dispatch_once_t observerToken;
    dispatch_once(&observerToken, ^{
        CherryBundleLoadObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSBundleDidLoadNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
                        CherryTryInstallRemoteViewCrashGuard();
                    }];
    });

    CherryTryInstallRemoteViewCrashGuard();
}
