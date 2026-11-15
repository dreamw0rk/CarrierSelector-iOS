#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read-only runtime adapter. Returns only allowlisted scalars and sanitized error metadata.
@interface CSTelephonyProbe : NSObject
+ (void)collectWhile:(BOOL (^)(void))shouldContinue
              update:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))update;
@end
NS_ASSUME_NONNULL_END
