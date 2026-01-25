#import <Foundation/Foundation.h>
#import <stdbool.h>

typedef void (^ReadyChimeExceptionCatcherBlock)(void);

bool ReadyChimePerformWithExceptionCatcher(
    ReadyChimeExceptionCatcherBlock _Nonnull work,
    NSString * _Nullable * _Nullable exceptionName,
    NSString * _Nullable * _Nullable exceptionReason
);
