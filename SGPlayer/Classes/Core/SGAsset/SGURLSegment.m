//
//  SGURLSegment.m
//  SGPlayer
//
//  Created by Single on 2018/11/14.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGURLSegment.h"
#import "SGSegment+Internal.h"
#import "SGDemuxerFunnel.h"
#import "SGURLDemuxer.h"

@implementation SGURLSegment

- (id)copyWithZone:(NSZone *)zone
{
    SGURLSegment *obj = [super copyWithZone:zone];
    obj->_URL = [self->_URL copy];
    obj->_index = self->_index;
    return obj;
}

- (instancetype)initWithURL:(NSURL *)URL index:(NSInteger)index
{
    return [self initWithURL:URL index:index timeRange:kCMTimeRangeInvalid scale:kCMTimeInvalid];
}

- (instancetype)initWithURL:(NSURL *)URL index:(NSInteger)index timeRange:(CMTimeRange)timeRange scale:(CMTime)scale
{
    if (self = [super initWithTimeRange:timeRange scale:scale]) {
        self->_URL = [URL copy];
        self->_index = index;
    }
    return self;
}

- (id<SGDemuxable>)newDemuxable
{
    SGURLDemuxer *demuxable = [[SGURLDemuxer alloc] initWithURL:self->_URL];
    SGDemuxerFunnel *obj = [[SGDemuxerFunnel alloc] initWithDemuxable:demuxable index:self.index timeRange:self.timeRange];
    return obj;
}

@end
