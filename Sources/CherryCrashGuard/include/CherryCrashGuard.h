#ifndef CHERRY_CRASH_GUARD_H
#define CHERRY_CRASH_GUARD_H

#import <Foundation/Foundation.h>

/// Installs Cherry's macOS 27 NSRemoteView compatibility guard when ViewBridge loads.
void CherryInstallRemoteViewCrashGuard(void);

/// Returns whether an exception is the specific macOS 27 ViewBridge assertion Cherry can suppress.
BOOL CherryShouldSuppressRemoteViewException(NSException *exception);

#endif
