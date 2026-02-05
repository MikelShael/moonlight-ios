//
//  RelativeTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//
//  Modified: Added macOS-style touch gestures:
//  - 1-finger hold + 2nd finger drag = left click drag
//  - 3-finger tap = middle click
//  - 2-finger hold + 3rd finger drag = middle click drag
//

#import "RelativeTouchHandler.h"

#include <Limelight.h>

static const int REFERENCE_WIDTH = 1280;
static const int REFERENCE_HEIGHT = 720;

@implementation RelativeTouchHandler {
    CGPoint touchLocation, originalLocation;
    BOOL touchMoved;
    BOOL isDragging;
    NSTimer* dragTimer;
    NSUInteger peakTouchCount;

    // Two-finger drag: hold first finger + drag with second = left click drag
    BOOL isTwoFingerDrag;
    UITouch* stationaryFinger;
    CGPoint secondFingerLocation;

    // Three-finger middle click drag: hold two fingers + drag with third
    BOOL isMiddleDragging;
    CGPoint thirdFingerLocation;

#if TARGET_OS_TV
    UIGestureRecognizer* remotePressRecognizer;
    UIGestureRecognizer* remoteLongPressRecognizer;
#endif

    UIView* view;
}

- (id)initWithView:(StreamView*)view {
    self = [self init];
    self->view = view;

#if TARGET_OS_TV
    remotePressRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonPressed:)];
    remotePressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];

    remoteLongPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonLongPressed:)];
    remoteLongPressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];

    [self->view addGestureRecognizer:remotePressRecognizer];
    [self->view addGestureRecognizer:remoteLongPressRecognizer];
#endif

    return self;
}

- (BOOL)isConfirmedMove:(CGPoint)currentPoint from:(CGPoint)originalPoint {
    // Movements of greater than 5 pixels are considered confirmed
    return hypotf(originalPoint.x - currentPoint.x, originalPoint.y - currentPoint.y) >= 5;
}

- (void)onDragStart:(NSTimer*)timer {
    if (!touchMoved && !isDragging){
        isDragging = true;
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    NSUInteger totalTouches = [[event allTouches] count];
    touchMoved = false;
    peakTouchCount = totalTouches;

    if (totalTouches == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        originalLocation = touchLocation = [touch locationInView:view];
        stationaryFinger = touch;
        if (!isDragging) {
            dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.650
                                                     target:self
                                                   selector:@selector(onDragStart:)
                                                   userInfo:nil
                                                    repeats:NO];
        }
    }
    else if (totalTouches == 2) {
        // Cancel single-finger long-press timer
        [dragTimer invalidate];
        dragTimer = nil;

        if (!touchMoved && !isDragging) {
            // First finger was stationary, second finger just arrived
            // -> Enter left-click drag mode (macOS-style: hold + drag)
            isTwoFingerDrag = true;
            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);

            // Find the second finger for tracking movement
            for (UITouch* touch in [event allTouches]) {
                if (touch != stationaryFinger) {
                    secondFingerLocation = [touch locationInView:view];
                    break;
                }
            }
        } else {
            // First finger was already moving -> normal 2-finger scroll
            CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
            CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
            originalLocation = touchLocation = CGPointMake(
                (firstLocation.x + secondLocation.x) / 2,
                (firstLocation.y + secondLocation.y) / 2
            );
        }
    }
    else if (totalTouches == 3) {
        // Cancel any active timers
        [dragTimer invalidate];
        dragTimer = nil;

        // If we were in two-finger left-drag, release it and switch to middle-drag
        if (isTwoFingerDrag) {
            isTwoFingerDrag = false;
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            stationaryFinger = nil;
        }

        // Enter middle-click drag mode immediately:
        // Two fingers are held, third finger arrived for dragging
        isMiddleDragging = true;
        touchMoved = true; // Prevent tap on release
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_MIDDLE);

        // Find the third finger (most recently added) for tracking
        NSArray* allTouches = [[event allTouches] allObjects];
        // Use the newest touch (from the 'touches' set that just began)
        UITouch* newestTouch = [touches anyObject];
        thirdFingerLocation = [newestTouch locationInView:view];
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    NSUInteger totalTouches = [[event allTouches] count];

    if (totalTouches == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        CGPoint currentLocation = [touch locationInView:view];

        if (touchLocation.x != currentLocation.x ||
            touchLocation.y != currentLocation.y)
        {
            int deltaX = (currentLocation.x - touchLocation.x) * (REFERENCE_WIDTH / view.bounds.size.width);
            int deltaY = (currentLocation.y - touchLocation.y) * (REFERENCE_HEIGHT / view.bounds.size.height);

            if (deltaX != 0 || deltaY != 0) {
                LiSendMouseMoveEvent(deltaX, deltaY);
                touchLocation = currentLocation;

                if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                    touchMoved = true;
                }
            }
        }
    } else if (totalTouches == 2) {
        if (isTwoFingerDrag) {
            // Two-finger drag mode: track second finger as cursor movement
            for (UITouch* touch in touches) {
                if (touch != stationaryFinger) {
                    CGPoint currentLocation = [touch locationInView:view];
                    int deltaX = (currentLocation.x - secondFingerLocation.x) * (REFERENCE_WIDTH / view.bounds.size.width);
                    int deltaY = (currentLocation.y - secondFingerLocation.y) * (REFERENCE_HEIGHT / view.bounds.size.height);
                    if (deltaX != 0 || deltaY != 0) {
                        LiSendMouseMoveEvent(deltaX, deltaY);
                    }
                    secondFingerLocation = currentLocation;
                    touchMoved = true;
                    break;
                }
            }
        } else {
            // Normal 2-finger scroll
            CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
            CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];

            CGPoint avgLocation = CGPointMake(
                (firstLocation.x + secondLocation.x) / 2,
                (firstLocation.y + secondLocation.y) / 2
            );
            if (touchLocation.y != avgLocation.y) {
                LiSendHighResScrollEvent((avgLocation.y - touchLocation.y) * 10);
            }

            if ([self isConfirmedMove:firstLocation from:originalLocation]) {
                touchMoved = true;
            }

            touchLocation = avgLocation;
        }
    } else if (totalTouches == 3 && isMiddleDragging) {
        // Middle-click drag: track third finger movement as cursor delta
        // Find the moving touch and use it for delta calculation
        for (UITouch* touch in touches) {
            CGPoint currentLocation = [touch locationInView:view];
            // Use the touch that moved the most (likely the dragging finger)
            float dist = hypotf(currentLocation.x - thirdFingerLocation.x,
                               currentLocation.y - thirdFingerLocation.y);
            if (dist > 1.0) {
                int deltaX = (currentLocation.x - thirdFingerLocation.x) * (REFERENCE_WIDTH / view.bounds.size.width);
                int deltaY = (currentLocation.y - thirdFingerLocation.y) * (REFERENCE_HEIGHT / view.bounds.size.height);
                if (deltaX != 0 || deltaY != 0) {
                    LiSendMouseMoveEvent(deltaX, deltaY);
                }
                thirdFingerLocation = currentLocation;
                break;
            }
        }
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;

    // Release middle-button drag
    if (isMiddleDragging) {
        isMiddleDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
        if ([[event allTouches] count] - [touches count] >= 1) {
            NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
            [activeSet unionSet:[event allTouches]];
            [activeSet minusSet:touches];
            touchLocation = [[activeSet anyObject] locationInView:view];
            touchMoved = true;
        }
        return;
    }

    // Release two-finger drag
    if (isTwoFingerDrag) {
        isTwoFingerDrag = false;
        stationaryFinger = nil;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
        if ([[event allTouches] count] - [touches count] >= 1) {
            NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
            [activeSet unionSet:[event allTouches]];
            [activeSet minusSet:touches];
            touchLocation = [[activeSet anyObject] locationInView:view];
            touchMoved = true;
        }
        return;
    }

    // Release single-finger long-press drag
    if (isDragging) {
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    } else if (!touchMoved) {
        // Tap detection (no movement occurred)
        if (peakTouchCount == 3) {
            // THREE-FINGER TAP: Middle click
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                Log(LOG_D, @"Sending middle mouse button press");

                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_MIDDLE);
                usleep(100 * 1000);
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
            });
        } else if (peakTouchCount == 2) {
            // TWO-FINGER TAP: Right click
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                Log(LOG_D, @"Sending right mouse button press");

                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
                usleep(100 * 1000);
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
            });
        } else if (peakTouchCount == 1) {
            // ONE-FINGER TAP: Left click
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                if (!self->isDragging){
                    Log(LOG_D, @"Sending left mouse button press");

                    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
                    usleep(100 * 1000);
                }
                self->isDragging = false;
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            });
        }
    }

    // Synchronize remaining finger position when going from 2+ to 1 finger
    if ([[event allTouches] count] - [touches count] == 1) {
        NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
        [activeSet unionSet:[event allTouches]];
        [activeSet minusSet:touches];
        touchLocation = [[activeSet anyObject] locationInView:view];
        touchMoved = true;
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;
    if (isMiddleDragging) {
        isMiddleDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    }
    if (isTwoFingerDrag) {
        isTwoFingerDrag = false;
        stationaryFinger = nil;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    if (isDragging) {
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    peakTouchCount = 0;
}

#if TARGET_OS_TV
- (void)remoteButtonPressed:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        Log(LOG_D, @"Sending left mouse button press");

        self->touchMoved = true;

        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        usleep(100 * 1000);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    });
}
- (void)remoteButtonLongPressed:(id)sender {
    Log(LOG_D, @"Holding left mouse button");

    isDragging = true;
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
}
#endif

@end
