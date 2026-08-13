#import "CherryCrashGuard.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef void (*CherryRemoteViewOrderFunction)(id, SEL, NSWindow *);

static CherryRemoteViewOrderFunction CherryOriginalRemoteViewOrder;
static SEL CherryRemoteViewOrderSelector;

static BOOL CherryIsAffectedRemoteViewAssertion(NSException *exception) {
    NSString *reason = exception.reason;
    return [exception.name isEqualToString:NSInternalInconsistencyException]
        && [reason containsString:@"NSRemoteView"]
        && [reason containsString:@"containingWindowWillOrderOnScreen"];
}

static void CherryGuardedRemoteViewOrder(id receiver, SEL selector, NSWindow *window) {
    @try {
        CherryOriginalRemoteViewOrder(receiver, CherryRemoteViewOrderSelector, window);
    } @catch (NSException *exception) {
        // macOS 27 betas can leave the system text-completion remote view tied to
        // a stale window. Suppress only that known ViewBridge assertion; every
        // unrelated Objective-C exception must retain its normal behavior.
        if (!CherryIsAffectedRemoteViewAssertion(exception)) {
            @throw exception;
        }

        NSLog(@"Cherry suppressed the macOS 27 NSRemoteView window-ordering assertion: %@",
              exception.reason);
    }
}

void CherryInstallRemoteViewCrashGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class remoteViewClass = NSClassFromString(@"NSRemoteView");
        SEL selector = NSSelectorFromString(@"containingWindowWillOrderOnScreen:");
        Method method = class_getInstanceMethod(remoteViewClass, selector);
        if (method == NULL) {
            return;
        }

        CherryRemoteViewOrderSelector = selector;
        CherryOriginalRemoteViewOrder = (CherryRemoteViewOrderFunction)method_getImplementation(method);
        method_setImplementation(method, (IMP)CherryGuardedRemoteViewOrder);
    });
}
