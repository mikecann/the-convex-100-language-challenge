#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CVXErrorDomain;

@interface CVXResult : NSObject {
@private
  id _value;
  NSArray *_logs;
}
@property(nonatomic, retain) id value;
@property(nonatomic, retain) NSArray *logs;
@end

@interface CVXLiveUpdate : NSObject {
@private
  id _value;
  NSArray *_logs;
  NSError *_error;
}
@property(nonatomic, retain, nullable) id value;
@property(nonatomic, retain) NSArray *logs;
@property(nonatomic, retain, nullable) NSError *error;
@end

@class CVXClient;

@interface CVXSubscription : NSObject {
@private
  void *_core;
  CVXClient *_owner;
}
- (nullable CVXLiveUpdate *)nextUpdateWithTimeoutMilliseconds:(NSInteger)timeout
                                                        error:(NSError **)error;
- (BOOL)unsubscribe:(NSError **)error;
@end

@interface CVXClient : NSObject {
@private
  void *_core;
}
- (nullable instancetype)initWithDeploymentURL:(NSURL *)deploymentURL
                                 clientVersion:(NSString *)clientVersion
                                         error:(NSError **)error
    NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)init NS_UNAVAILABLE;
- (BOOL)setAuthToken:(nullable NSString *)token error:(NSError **)error;
- (nullable CVXResult *)query:(NSString *)path
                         args:(NSDictionary *)args
                        error:(NSError **)error;
- (nullable CVXResult *)mutation:(NSString *)path
                            args:(NSDictionary *)args
                           error:(NSError **)error;
- (nullable CVXResult *)action:(NSString *)path
                          args:(NSDictionary *)args
                         error:(NSError **)error;
- (nullable CVXSubscription *)subscribe:(NSString *)path
                                   args:(NSDictionary *)args
                                  error:(NSError **)error;
- (BOOL)closeWithTimeoutMilliseconds:(NSInteger)timeout error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
