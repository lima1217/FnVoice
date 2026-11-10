#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises. Swift cannot catch these, and one
/// that unwinds through Swift async frames leaves the concurrency runtime's executor state pointing
/// at freed memory: the process crashes later in an unrelated place (seen in `WaveformView.tick`).
/// Returns NO and sets `error` (domain `NSException`, userInfo carries the name) when one was raised.
BOOL FNTryObjC(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
