//
//  SGURLAsset.h
//  SGPlayer iOS
//
//  Created by Single on 2018/9/19.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGAsset.h"

@interface SGURLAsset : SGAsset

/**
 *
 */
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/**
 *
 */
- (instancetype)initWithURL:(NSURL *)URL;

/**
 *
 */
@property (nonatomic, copy, readonly) NSURL *URL;

@end
