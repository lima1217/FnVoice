#import "ObjCTry.h"

BOOL FNTryObjC(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"NSException" code:0 userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                @"name": exception.name,
            }];
        }
        return NO;
    }
}
