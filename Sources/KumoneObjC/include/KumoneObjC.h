#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
///
/// Swift cannot catch an NSException. AVFAudio raises them for conditions the
/// caller cannot always check first — `AVAudioPlayerNode.play()` throws
/// "player did not see an IO cycle" in a window no public property reveals —
/// and uncaught, each is a crash of the whole app.
FOUNDATION_EXPORT NSException *_Nullable KumoneCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
