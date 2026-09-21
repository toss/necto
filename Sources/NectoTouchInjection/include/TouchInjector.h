//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface NectoAccessibilityLoader : NSObject
+ (void)prepare;
@end
@interface NectoTouchInjector : NSObject
+ (void)sendInWindow:(UIWindow *)window
               from:(CGPoint)start
                 to:(CGPoint)end
           duration:(NSTimeInterval)duration
               edge:(BOOL)edge
         completion:(void (^)(NSString * _Nullable))completion
NS_SWIFT_NAME(send(in:from:to:duration:edge:completion:));
+ (void)tapInWindow:(UIWindow *)window
             points:(NSArray<NSValue *> *)points
           tapCount:(NSUInteger)tapCount
         completion:(void (^)(NSString * _Nullable))completion
NS_SWIFT_NAME(tap(in:points:tapCount:completion:));
@end
NS_ASSUME_NONNULL_END
#endif
