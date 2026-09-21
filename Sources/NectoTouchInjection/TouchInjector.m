//
//  Copyright (c) 2026 Viva Republica, Inc.
//

#if __has_include(<UIKit/UIKit.h>)
#import "TouchInjector.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Private UIKit entry points are confined to the Control plugin implementation.
@interface UITouch (NectoPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setGestureView:(UIView *)view;
- (void)setTapCount:(NSUInteger)count;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)_setLocationInWindow:(CGPoint)point resetPrevious:(BOOL)reset;
- (void)_setIsFirstTouchForView:(BOOL)first;
- (void)_setIsTapToClick:(BOOL)value;
- (void)_setHidEvent:(CFTypeRef)event;
- (void)_setEdgeType:(NSInteger)type;
@end
@interface UIApplication (NectoPrivate)
- (UIEvent *)_touchesEvent;
@end
@interface UIEvent (NectoPrivate)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_setHIDEvent:(CFTypeRef)event;
@end

typedef CFTypeRef (*HandEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                              uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef void (*AppendEvent)(CFTypeRef, CFTypeRef, uint32_t);

typedef CFTypeRef (*FingerEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                double, double, double, double, double, Boolean, Boolean, uint32_t);

@interface NectoTouchInjector ()
@property(nonatomic) NSArray<UITouch *> *touches;
@property(nonatomic) NSArray<NSValue *> *points;
@property(nonatomic) NSUInteger tapCount;
@property(nonatomic) NSUInteger tapIndex;
@property(nonatomic) UIWindow *window;
@property(nonatomic) CGPoint start;
@property(nonatomic) CGPoint end;
@property(nonatomic) NSTimeInterval duration;
@property(nonatomic) NSUInteger step;
@property(nonatomic) NSUInteger steps;
@property(nonatomic, copy) void (^completion)(NSString *);
@end

@implementation NectoTouchInjector
static BOOL busy;

+ (void)sendInWindow:(UIWindow *)window from:(CGPoint)start to:(CGPoint)end
           duration:(NSTimeInterval)duration edge:(BOOL)edge completion:(void (^)(NSString *))completion {
    [self beginInWindow:window points:@[[NSValue valueWithCGPoint:start]] end:end
              duration:duration tapCount:1 edge:edge completion:completion];
}

+ (void)tapInWindow:(UIWindow *)window points:(NSArray<NSValue *> *)points
          tapCount:(NSUInteger)tapCount completion:(void (^)(NSString *))completion {
    if (points.count < 1 || points.count > 5 || tapCount < 1 || tapCount > 3) {
        completion(@"Use 1–5 fingers and 1–3 taps"); return;
    }
    [self beginInWindow:window points:points end:points.firstObject.CGPointValue
              duration:0.08 tapCount:tapCount edge:NO completion:completion];
}

+ (void)beginInWindow:(UIWindow *)window points:(NSArray<NSValue *> *)points end:(CGPoint)end
            duration:(NSTimeInterval)duration tapCount:(NSUInteger)tapCount edge:(BOOL)edge
          completion:(void (^)(NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Touch injection requires the main thread");
    if (busy) { completion(@"Another gesture is in progress"); return; }
    NectoTouchInjector *sender = [self new];
    sender.window = window;
    sender.points = points;
    sender.start = points.firstObject.CGPointValue;
    sender.end = end;
    sender.duration = duration;
    sender.tapCount = tapCount;
    sender.tapIndex = 1;
    sender.steps = CGPointEqualToPoint(sender.start, end) ? 1 : MAX(2, (NSUInteger)ceil(duration * 60));
    sender.completion = completion;
    busy = YES;
    @try {
        NSMutableArray<UITouch *> *touches = [NSMutableArray new];
        for (NSValue *value in points) {
            CGPoint start = value.CGPointValue;
            UIView *hit = [window hitTest:start withEvent:nil];
            if (!hit) { [sender finish:@"No view receives the gesture"]; return; }
            UITouch *touch = [UITouch new];
            [touches addObject:touch];
            sender.touches = touches;
            NSArray<NSString *> *required = @[@"setWindow:", @"setView:", @"setTapCount:", @"setTimestamp:",
                @"setPhase:", @"_setLocationInWindow:resetPrevious:", @"_setHidEvent:"];
            for (NSString *name in required) {
                if (![touch respondsToSelector:NSSelectorFromString(name)]) {
                    [sender finish:[@"Unsupported touch API: " stringByAppendingString:name]]; return;
                }
            }
            [touch setWindow:window];
            [touch setView:hit];
            [touch setTapCount:CGPointEqualToPoint(start, end) ? 1 : 0];
            [touch _setLocationInWindow:start resetPrevious:YES];
            if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
                [touch _setIsFirstTouchForView:YES];
            } else {
                Ivar flags = class_getInstanceVariable(UITouch.class, "_touchFlags");
                if (!flags || ![touch respondsToSelector:@selector(_setIsTapToClick:)]) {
                    [sender finish:@"Unsupported touch initialization"]; return;
                }
                [touch _setIsTapToClick:YES];
                uint8_t *storage = (uint8_t *)(__bridge void *)touch + ivar_getOffset(flags);
                *storage |= 1;
            }
            if ([touch respondsToSelector:@selector(setGestureView:)]) [touch setGestureView:hit];
            // SwiftUI can route gestures to a responder that is not the hit UIView.
            Class contextClass = NSClassFromString(@"_UIHitTestContext");
            SEL makeContext = NSSelectorFromString(@"contextWithPoint:radius:");
            SEL resolve = NSSelectorFromString(@"_hitTestWithContext:");
            SEL setResponder = NSSelectorFromString(@"_setResponder:");
            id gestureResponder = nil;
            if ([contextClass respondsToSelector:makeContext] && [touch respondsToSelector:setResponder]) {
                id context = ((id (*)(id, SEL, CGPoint, CGFloat))objc_msgSend)(contextClass, makeContext, start, 0);
                for (UIView *candidate = hit; context && candidate && !gestureResponder; candidate = candidate.superview) {
                    if ([candidate respondsToSelector:resolve]) {
                        gestureResponder = ((id (*)(id, SEL, id))objc_msgSend)(candidate, resolve, context);
                    }
                }
                if (gestureResponder) {
                    ((void (*)(id, SEL, id))objc_msgSend)(touch, setResponder, gestureResponder);
                }
            }
            if (edge) {
                if (![touch respondsToSelector:@selector(_setEdgeType:)]) {
                    [sender finish:@"Edge gestures are unavailable"]; return;
                }
                [touch _setEdgeType:4];
            }
        }
        [sender tick];
    } @catch (NSException *exception) { [sender finish:exception.reason ?: exception.name]; }
}

- (void)tick {
    @try {
        static FingerEvent finger;
        static HandEvent hand;
        static AppendEvent append;
        if (!finger) {
            void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
            finger = (FingerEvent)dlsym(library ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
            hand = (HandEvent)dlsym(library ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
            append = (AppendEvent)dlsym(library ?: RTLD_DEFAULT, "IOHIDEventAppendEvent");
        }
        if (!finger || !hand || !append) { [self finish:@"Digitizer API unavailable"]; return; }
        BOOL finished = self.step == self.steps;
        UITouchPhase phase = self.step == 0 ? UITouchPhaseBegan : (finished ? UITouchPhaseEnded : UITouchPhaseMoved);
        uint32_t mask = phase == UITouchPhaseMoved ? 4 : 3;
        uint64_t timestamp = mach_absolute_time();
        CFTypeRef group = hand(kCFAllocatorDefault, timestamp, 3, 1, 2, mask,
                               0, 0, 0, 0, 0, 0, !finished, !finished, 0);
        if (!group) { [self finish:@"Could not create digitizer event"]; return; }
        UIEvent *event = [UIApplication.sharedApplication _touchesEvent];
        @try {
            [event _clearTouches];
            CGFloat progress = (CGFloat)self.step / self.steps;
            for (NSUInteger index = 0; index < self.touches.count; index++) {
                UITouch *touch = self.touches[index];
                CGPoint point = self.points[index].CGPointValue;
                point.x += (self.end.x - self.start.x) * progress;
                point.y += (self.end.y - self.start.y) * progress;
                [touch _setLocationInWindow:point resetPrevious:self.step == 0];
                [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
                [touch setPhase:phase];
                [touch setTapCount:CGPointEqualToPoint(self.start, self.end) ? self.tapIndex : 0];
                CFTypeRef hid = finger(kCFAllocatorDefault, timestamp, (uint32_t)index + 1,
                                      (uint32_t)index + 2, mask, point.x, point.y, 0, 0, 0,
                                      !finished, !finished, 0);
                if (!hid) { [self finish:@"Could not create finger event"]; return; }
                append(group, hid, 0);
                [touch _setHidEvent:hid];
                CFRelease(hid);
                [event _addTouch:touch forDelayedDelivery:NO];
            }
            // All fingers share one event so recognizers observe a simultaneous gesture.
            [event _setHIDEvent:group];
            [UIApplication.sharedApplication sendEvent:event];
        } @finally {
            [event _setHIDEvent:NULL];
            CFRelease(group);
        }
        NSTimeInterval delay = self.duration / self.steps;
        if (finished) {
            if (self.tapIndex == self.tapCount) { [self finish:nil]; return; }
            self.tapIndex += 1;
            self.step = 0;
            delay = 0.1;
        } else {
            self.step += 1;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self tick]; });
    } @catch (NSException *exception) { [self finish:exception.reason ?: exception.name]; }
}

- (void)finish:(NSString *)error {
    void (^completion)(NSString *) = self.completion;
    if (!completion) return;
    self.completion = nil;
    if (error && self.touches.count && self.step > 0) {
        @try {
            UIEvent *event = [UIApplication.sharedApplication _touchesEvent];
            [event _clearTouches];
            for (UITouch *touch in self.touches) {
                if (touch.phase == UITouchPhaseEnded) continue;
                [touch setPhase:UITouchPhaseCancelled];
                [event _addTouch:touch forDelayedDelivery:NO];
            }
            [UIApplication.sharedApplication sendEvent:event];
        } @catch (NSException *exception) {
            // Preserve the original error if this OS also refuses cancellation.
        }
    }
    self.touches = nil;
    busy = NO;
    completion(error);
}
@end
#endif
