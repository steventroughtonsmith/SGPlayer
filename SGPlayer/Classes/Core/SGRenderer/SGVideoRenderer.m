//
//  SGVideoRenderer.m
//  SGPlayer
//
//  Created by Single on 2018/1/22.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGVideoRenderer.h"
#import "SGRenderer+Internal.h"
#import "SGVRMatrixMaker.h"
#import "SGOptions.h"
#import "SGMapping.h"
#import "SGOpenGL.h"
#import "SGMetal.h"
#import "SGMacro.h"
#import "SGLock.h"

@interface SGVideoRenderer () <MTKViewDelegate>

{
    struct {
        SGRenderableState state;
        BOOL hasNewFrame;
        NSUInteger framesFetched;
        NSUInteger framesDisplayed;
        NSTimeInterval currentFrameEndTime;
    } _flags;
    SGCapacity _capacity;
}

@property (nonatomic, strong, readonly) NSLock *lock;
@property (nonatomic, strong, readonly) SGClock *clock;
@property (nonatomic, strong, readonly) SGGLTimer *fetchTimer;
@property (nonatomic, strong, readonly) SGVideoFrame *currentFrame;

@property (nonatomic, strong, readonly) MTKView *metalView;
@property (nonatomic, strong, readonly) SGMetalModel *planeModel;
@property (nonatomic, strong, readonly) SGMetalModel *sphereModel;
@property (nonatomic, strong, readonly) SGMetalRenderer *renderer;
@property (nonatomic, strong, readonly) SGMetalProjection *projection;
@property (nonatomic, strong, readonly) SGMetalRenderPipeline *pipeline;
@property (nonatomic, strong, readonly) SGMetalTextureLoader *textureLoader;
@property (nonatomic, strong, readonly) SGMetalRenderPipelinePool *pipelinePool;

@end

@implementation SGVideoRenderer

@synthesize rate = _rate;
@synthesize options = _options;
@synthesize delegate = _delegate;

- (instancetype)init
{
    NSAssert(NO, @"Invalid Function.");
    return nil;
}

- (instancetype)initWithClock:(SGClock *)clock
{
    if (self = [super init]) {
        self->_clock = clock;
        self->_rate = 1.0;
        self->_lock = [[NSLock alloc] init];
        self->_capacity = SGCapacityCreate();
        self->_preferredFramesPerSecond = 30;
        self->_displayMode = SGDisplayModePlane;
        self->_scalingMode = SGScalingModeResizeAspect;
        self->_options = [SGOptions sharedOptions].renderer.copy;
    }
    return self;
}

- (void)dealloc
{
    [self performSelectorOnMainThread:@selector(destoryMetal)
                           withObject:nil
                        waitUntilDone:YES];
    [self->_fetchTimer invalidate];
    self->_fetchTimer = nil;
    [self->_currentFrame unlock];
    self->_currentFrame = nil;
}

#pragma mark - Setter & Getter

- (SGBlock)setState:(SGRenderableState)state
{
    if (self->_flags.state == state) {
        return ^{};
    }
    self->_flags.state = state;
    return ^{
        [self->_delegate renderable:self didChangeState:state];
    };
}

- (SGRenderableState)state
{
    __block SGRenderableState ret = SGRenderableStateNone;
    SGLockEXE00(self->_lock, ^{
        ret = self->_flags.state;
    });
    return ret;
}

- (SGCapacity)capacity
{
    __block SGCapacity ret;
    SGLockEXE00(self->_lock, ^{
        ret = self->_capacity;
    });
    return ret;
}

- (void)setRate:(Float64)rate
{
    SGLockEXE00(self->_lock, ^{
        self->_rate = rate;
    });
}

- (Float64)rate
{
    __block Float64 ret = 1.0;
    SGLockEXE00(self->_lock, ^{
        ret = self->_rate;
    });
    return ret;
}

- (SGVRViewport *)viewport
{
    return nil;
//    return self->_matrixMaker.viewport;
}

- (SGPLFImage *)originalImage
{
    __block SGPLFImage *ret = nil;
    SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_currentFrame != nil;
    }, ^SGBlock {
        SGVideoFrame *frame = self->_currentFrame;
        [frame lock];
        return ^{
            ret = [frame image];
            [frame unlock];
        };
    }, ^BOOL(SGBlock block) {
        block();
        return YES;
    });
    return ret;
}

- (SGPLFImage *)snapshot
{
    return nil;
//    return SGPLFViewGetCurrentSnapshot(self->_glView);
}

#pragma mark - Interface

- (BOOL)open
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return self->_flags.state == SGRenderableStateNone;
    }, ^SGBlock {
        return [self setState:SGRenderableStatePaused];
    }, ^BOOL(SGBlock block) {
        block();
        [self performSelectorOnMainThread:@selector(setupMetal)
                               withObject:nil
                            waitUntilDone:YES];
        SGWeakify(self)
        NSTimeInterval interval = 0.5 / self->_preferredFramesPerSecond;
        self->_fetchTimer = [[SGGLTimer alloc] initWithTimeInterval:interval handler:^{
            SGStrongify(self)
            [self fetchTimerHandler];
        }];
        self->_fetchTimer.paused = NO;
        return YES;
    });
}

- (BOOL)close
{
    return SGLockEXE11(self->_lock, ^SGBlock {
        SGBlock b1 = [self setState:SGRenderableStateNone];
        [self->_currentFrame unlock];
        self->_currentFrame = nil;
        self->_flags.framesFetched = 0;
        self->_flags.framesDisplayed = 0;
        self->_flags.hasNewFrame = NO;
        self->_capacity = SGCapacityCreate();
        return ^{b1();};
    }, ^BOOL(SGBlock block) {
        [self performSelectorOnMainThread:@selector(destoryMetal)
                               withObject:nil
                            waitUntilDone:YES];
        [self->_fetchTimer invalidate];
        self->_fetchTimer = nil;
        block();
        return YES;
    });
}

- (BOOL)pause
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return
        self->_flags.state == SGRenderableStateRendering ||
        self->_flags.state == SGRenderableStateFinished;
    }, ^SGBlock {
        return [self setState:SGRenderableStatePaused];
    }, ^BOOL(SGBlock block) {
        self->_metalView.paused = NO;
        self->_fetchTimer.paused = NO;
        return YES;
    });
}

- (BOOL)resume
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return
        self->_flags.state == SGRenderableStatePaused ||
        self->_flags.state == SGRenderableStateFinished;
    }, ^SGBlock {
        return [self setState:SGRenderableStateRendering];
    }, ^BOOL(SGBlock block) {
        self->_metalView.paused = NO;
        self->_fetchTimer.paused = NO;
        return YES;
    });
}

- (BOOL)flush
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return
        self->_flags.state == SGRenderableStatePaused ||
        self->_flags.state == SGRenderableStateRendering ||
        self->_flags.state == SGRenderableStateFinished;
    }, ^SGBlock {
        [self->_currentFrame unlock];
        self->_currentFrame = nil;
        self->_flags.framesFetched = 0;
        self->_flags.framesDisplayed = 0;
        self->_flags.hasNewFrame = NO;
        return nil;
    }, ^BOOL(SGBlock block) {
        self->_metalView.paused = NO;
        self->_fetchTimer.paused = NO;
        return YES;
    });
}

- (BOOL)finish
{
    return SGLockCondEXE11(self->_lock, ^BOOL {
        return
        self->_flags.state == SGRenderableStateRendering ||
        self->_flags.state == SGRenderableStatePaused;
    }, ^SGBlock {
        return [self setState:SGRenderableStateFinished];
    }, ^BOOL(SGBlock block) {
        self->_metalView.paused = NO;
        self->_fetchTimer.paused = NO;
        return YES;
    });
}

#pragma mark - Fecth

- (void)fetchTimerHandler
{
    BOOL shouldFetch = NO;
    BOOL shouldPause = NO;
    [self->_lock lock];
    if (self->_flags.state == SGRenderableStateRendering ||
        (self->_flags.state == SGRenderableStatePaused &&
         self->_flags.framesFetched == 0)) {
        shouldFetch = YES;
    } else if (self->_flags.state != SGRenderableStateRendering) {
        shouldPause = YES;
    }
    [self->_lock unlock];
    if (shouldPause) {
        self->_fetchTimer.paused = YES;
    }
    if (!shouldFetch) {
        return;
    }
    __block NSUInteger framesFetched = 0;
    __block NSTimeInterval currentMediaTime = CACurrentMediaTime();
    SGWeakify(self)
    SGVideoFrame *newFrame = [self->_delegate renderable:self fetchFrame:^BOOL(CMTime *desire, BOOL *drop) {
        SGStrongify(self)
        return SGLockCondEXE10(self->_lock, ^BOOL {
            framesFetched = self->_flags.framesFetched;
            return self->_currentFrame && framesFetched != 0;
        }, ^SGBlock {
            return ^{
                currentMediaTime = CACurrentMediaTime();
                *desire = self->_clock.currentTime;
                *drop = YES;
            };
        });
    }];
    SGLockCondEXE10(self->_lock, ^BOOL {
        return !newFrame || framesFetched == self->_flags.framesFetched;
    }, ^SGBlock {
        SGBlock b1 = ^{}, b2 = ^{}, b3 = ^{};
        SGCapacity capacity = SGCapacityCreate();
        if (newFrame) {
            [newFrame lock];
            CMTime time = newFrame.timeStamp;
            CMTime duration = CMTimeMultiplyByFloat64(newFrame.duration, self->_rate);
            capacity.duration = duration;
            [self->_currentFrame unlock];
            self->_currentFrame = newFrame;
            self->_flags.framesFetched += 1;
            self->_flags.hasNewFrame = YES;
            self->_flags.currentFrameEndTime = currentMediaTime + CMTimeGetSeconds(duration);
            if (self->_frameOutput) {
                [newFrame lock];
                b1 = ^{
                    self->_frameOutput(newFrame);
                    [newFrame unlock];
                };
            }
            b2 = ^{
                [self->_clock setVideoTime:time];
            };
        } else if (currentMediaTime < self->_flags.currentFrameEndTime) {
            capacity.duration = SGCMTimeMakeWithSeconds(self->_flags.currentFrameEndTime - currentMediaTime);
        }
        if (!SGCapacityIsEqual(self->_capacity, capacity)) {
            self->_capacity = capacity;
            b3 = ^{
                [self->_delegate renderable:self didChangeCapacity:capacity];
            };
        }
        return ^{b1(); b2(); b3();};
    });
    [newFrame unlock];
}

#pragma mark - MTKViewDelegate

- (void)drawInMTKView:(MTKView *)view
{
    [self->_lock lock];
    SGVideoFrame *frame = self->_currentFrame;
    SGVideoDescription *description = frame.videoDescription;
    if (!frame || description.width == 0 || description.height == 0) {
        [self->_lock unlock];
        return;
    }
    BOOL shouldDraw = NO;
    if (self->_flags.hasNewFrame ||
        self->_flags.framesDisplayed == 0 ||
        (self->_displayMode == SGDisplayModeVR ||
         self->_displayMode == SGDisplayModeVRBox)) {
            shouldDraw = YES;
    }
    if (!shouldDraw) {
        BOOL shouldPause = self->_flags.state != SGRenderableStateRendering;
        [self->_lock unlock];
        if (shouldPause) {
            self->_metalView.paused = YES;
        }
        return;
    }
    NSUInteger framesFetched = self->_flags.framesFetched;
    [frame lock];
    [self->_lock unlock];
    SGDisplayMode displayMode = self->_displayMode;
    SGMetalModel *model = displayMode == SGDisplayModePlane ? self->_planeModel : self->_sphereModel;
    SGMetalRenderPipeline *pipeline = [self->_pipelinePool pipelineWithCVPixelFormat:frame.videoDescription.cv_format];
    if (!model || !pipeline) {
        [frame unlock];
        return;
    }
    NSArray<id<MTLTexture>> *textures = nil;
    if (frame.pixelBuffer) {
        textures = [self->_textureLoader texturesWithCVPixelBuffer:frame.pixelBuffer];
    } else {
        textures = [self->_textureLoader texturesWithCVPixelFormat:frame.videoDescription.cv_format
                                                             width:frame.videoDescription.width
                                                            height:frame.videoDescription.height
                                                             bytes:(void **)frame.data
                                                       bytesPerRow:frame.linesize];
    }
    if (!textures.count) {
        [frame unlock];
        return;
    }
    id<CAMetalDrawable> drawable = [(CAMetalLayer *)self->_metalView.layer nextDrawable];
    self.projection.inputSize = MTLSizeMake(description.width, description.height, 0);
    self.projection.outputSize = MTLSizeMake(drawable.texture.width, drawable.texture.height, 0);
    id<MTLCommandBuffer> commandBuffer = [self.renderer drawModel:model
                                                         pipeline:pipeline
                                                       projection:self.projection
                                                    inputTextures:textures
                                                    outputTexture:drawable.texture];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    [frame unlock];
    [self->_lock lock];
    if (self->_flags.framesFetched == framesFetched) {
        self->_flags.framesDisplayed += 1;
        self->_flags.hasNewFrame = NO;
    }
    [self->_lock unlock];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
    SGLockCondEXE10(self->_lock, ^BOOL{
        return
        self->_flags.state == SGRenderableStateRendering ||
        self->_flags.state == SGRenderableStatePaused ||
        self->_flags.state == SGRenderableStateFinished;
    }, ^SGBlock{
        self->_flags.framesDisplayed = 0;
        return ^{
            self->_metalView.paused = NO;
            self->_fetchTimer.paused = NO;
        };
    });
}

#pragma mark - Metal

- (void)setupMetal
{
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self->_projection = [[SGMetalProjection alloc] init];
    self->_renderer = [[SGMetalRenderer alloc] initWithDevice:device];
    self->_planeModel = [[SGMetalPlaneModel alloc] initWithDevice:device];
    self->_sphereModel = [[SGMetalSphereModel alloc] initWithDevice:device];
    self->_textureLoader = [[SGMetalTextureLoader alloc] initWithDevice:device];
    self->_pipelinePool = [[SGMetalRenderPipelinePool alloc] initWithDevice:device];
    self->_metalView = [[MTKView alloc] initWithFrame:CGRectZero device:device];
    self->_metalView.preferredFramesPerSecond = self->_preferredFramesPerSecond;
    self->_metalView.translatesAutoresizingMaskIntoConstraints = NO;
    self->_metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self->_metalView.delegate = self;
    [self layoutMetalViewIfNeeded];
}

- (void)destoryMetal
{
    [self->_metalView removeFromSuperview];
    self->_metalView = nil;
    self->_projection = nil;
    self->_renderer = nil;
    self->_planeModel = nil;
    self->_sphereModel = nil;
    self->_textureLoader = nil;
    self->_pipelinePool = nil;
}

- (void)setView:(SGPLFView *)view
{
    if (self->_view != view) {
        self->_view = view;
        [self layoutMetalViewIfNeeded];
    }
}

- (void)setPreferredFramesPerSecond:(NSInteger)preferredFramesPerSecond
{
    if (self->_preferredFramesPerSecond != preferredFramesPerSecond) {
        self->_preferredFramesPerSecond = preferredFramesPerSecond;
        self->_metalView.preferredFramesPerSecond = self->_preferredFramesPerSecond;
    }
}

- (void)layoutMetalViewIfNeeded
{
    if (self->_view &&
        self->_metalView &&
        self->_metalView.superview != self->_view) {
        SGPLFViewInsertSubview(self->_view, self->_metalView, 0);
        NSLayoutConstraint *c1 = [NSLayoutConstraint constraintWithItem:self->_metalView
                                                              attribute:NSLayoutAttributeTop
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:self->_view
                                                              attribute:NSLayoutAttributeTop
                                                             multiplier:1.0
                                                               constant:0.0];
        NSLayoutConstraint *c2 = [NSLayoutConstraint constraintWithItem:self->_metalView
                                                              attribute:NSLayoutAttributeLeft
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:self->_view
                                                              attribute:NSLayoutAttributeLeft
                                                             multiplier:1.0
                                                               constant:0.0];
        NSLayoutConstraint *c3 = [NSLayoutConstraint constraintWithItem:self->_metalView
                                                              attribute:NSLayoutAttributeBottom
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:self->_view
                                                              attribute:NSLayoutAttributeBottom
                                                             multiplier:1.0
                                                               constant:0.0];
        NSLayoutConstraint *c4 = [NSLayoutConstraint constraintWithItem:self->_metalView
                                                              attribute:NSLayoutAttributeRight
                                                              relatedBy:NSLayoutRelationEqual
                                                                 toItem:self->_view
                                                              attribute:NSLayoutAttributeRight
                                                             multiplier:1.0
                                                               constant:0.0];
        [self->_view addConstraints:@[c1, c2, c3, c4]];
    } else {
        [self->_metalView removeFromSuperview];
    }
}

@end
