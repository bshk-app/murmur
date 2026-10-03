#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Synchronous worker-only API. All model state is released before this call returns.
@interface MROCRBridge : NSObject
+ (nullable NSDictionary<NSString *, id> *)recognizeImageAtPath:(NSString *)imagePath
                                                 detectorPath:(NSString *)detectorPath
                                               recognizerPath:(NSString *)recognizerPath
                                                   dictionary:(NSArray<NSString *> *)dictionary
                                                    cachePath:(NSString *)cachePath
                                                        error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
