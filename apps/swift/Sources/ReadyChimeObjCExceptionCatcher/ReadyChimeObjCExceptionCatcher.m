#import "ReadyChimeObjCExceptionCatcher.h"

bool ReadyChimePerformWithExceptionCatcher(
    ReadyChimeExceptionCatcherBlock _Nonnull work,
    NSString * _Nullable * _Nullable exceptionName,
    NSString * _Nullable * _Nullable exceptionReason
) {
    @try {
        work();
        return true;
    }
    @catch (NSException *exception) {
        if (exceptionName != NULL) {
            *exceptionName = exception.name;
        }
        if (exceptionReason != NULL) {
            *exceptionReason = exception.reason;
        }
        return false;
    }
}
