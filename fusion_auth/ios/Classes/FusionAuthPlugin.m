#import "FusionAuthPlugin.h"
#import "FusionStartGate.h"
#import <AlicomFusionAuth/AlicomFusionAuth.h>

// start -> token auth -> (onSDKTokenAuthSuccess) startScene ->
// onVerifySuccess/onHalfwayVerifySuccess resolves the pending `start` with the
// verify token -> Dart verifies on the host's server -> finish(success) closes the
// scene or lets the template fall back. Any other end resolves without a token.
@interface FusionAuthPlugin () <AlicomFusionAuthDelegate>
@property(nonatomic, strong) AlicomFusionAuthHandler *handler;
@property(nonatomic, copy) FlutterResult pending;
@property(nonatomic, copy) void (^halfway)(BOOL);
@property(nonatomic, copy) NSString *templateId;
@property(nonatomic, copy) NSString *authToken;
@property(nonatomic, assign) BOOL sceneStarted;
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, assign) FusionStartGate *gate;
- (void)deliverPendingWithToken:(NSString *)token
                           code:(NSString *)code
                        message:(NSString *)message;
@end

@implementation FusionAuthPlugin

- (instancetype)init {
  self = [super init];
  if (self) {
    _gate = FusionStartGateCreate();
  }
  return self;
}

- (void)dealloc {
  FusionStartGateDestroy(_gate);
  _gate = NULL;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"boqinai/fusion_auth"
                                  binaryMessenger:[registrar messenger]];
  FusionAuthPlugin *instance = [[FusionAuthPlugin alloc] init];
  instance.channel = channel;
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"start"]) {
    [self start:call result:result];
  } else if ([call.method isEqualToString:@"finish"]) {
    NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
    [self finish:[args[@"success"] isEqual:@YES]];
    result(nil);
  } else if ([call.method isEqualToString:@"cancel"]) {
    [self releaseSceneWithCode:@"cancelled" message:@""];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

static NSString *PFString(id v) { return [v isKindOfClass:[NSString class]] ? v : @""; }

- (void)start:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};
  NSString *token = PFString(args[@"token"]);
  NSString *scheme = PFString(args[@"schemeCode"]);
  NSString *template = PFString(args[@"templateId"]);
  if (token.length == 0 || scheme.length == 0 || template.length == 0) {
    result([FlutterError errorWithCode:@"bad_args"
                               message:@"token, schemeCode and templateId are required"
                               details:nil]);
    return;
  }
  if (self.pending != nil || self.handler != nil) {
    result([FlutterError errorWithCode:@"busy" message:@"A fusion scene is already running" details:nil]);
    return;
  }
  if ([self topViewController] == nil) {
    result([FlutterError errorWithCode:@"no_activity" message:@"No foreground view controller" details:nil]);
    return;
  }
  [self destroyHandler];
  FusionStartGateReset(self.gate);
  if (!FusionStartGateArm(self.gate)) {
    result([FlutterError errorWithCode:@"busy" message:@"A fusion scene is already running" details:nil]);
    return;
  }
  self.pending = result;
  self.templateId = template;
  self.authToken = token;
  self.sceneStarted = NO;
  @try {
    // Umeng is not bundled; the SDK looks it up at runtime and skips it.
    [AlicomFusionAuthHandler useSDKSupplyUMSDK:NO];
    AlicomFusionAuthToken *t = [[AlicomFusionAuthToken alloc] initWithTokenStr:token];
    AlicomFusionAuthHandler *h = [[AlicomFusionAuthHandler alloc] initWithToken:t schemeCode:scheme];
    self.handler = h;
    [h setFusionAuthDelegate:self];
    // startScene waits for onSDKTokenAuthSuccess, as in the SDK demo.
  } @catch (NSException *e) {
    // One terminal status. resolve(start_failed) used to be posted, then
    // releaseScene completed the same request synchronously as cancelled.
    [self releaseSceneWithCode:@"start_failed" message:e.reason ?: e.name ?: @"start_failed"];
  }
}

- (void)finish:(BOOL)success {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.handler == nil) return;
    void (^hw)(BOOL) = self.halfway;
    self.halfway = nil;
    if (hw != nil) {
      hw(success);
    } else {
      [self.handler continueSceneWithTemplateId:self.templateId isSuccess:success];
    }
  });
}

- (void)resolve:(NSString *)token code:(NSString *)code message:(NSString *)message {
  [self completeWithToken:token code:code message:message];
}

- (void)completeWithToken:(NSString *)token code:(NSString *)code message:(NSString *)message {
  const char *codeUtf8 = code.length > 0 ? code.UTF8String : "";
  const char *messageUtf8 = message.length > 0 ? message.UTF8String : "";
  if (!FusionStartGateComplete(self.gate, codeUtf8, messageUtf8)) {
    return;
  }
  [self deliverPendingWithToken:token code:code message:message];
}

- (void)deliverPendingWithToken:(NSString *)token
                           code:(NSString *)code
                        message:(NSString *)message {
  FlutterResult r = self.pending;
  self.pending = nil;
  if (r == nil) return;
  NSDictionary *payload = @{
    @"verifyToken" : token ?: [NSNull null],
    @"code" : code ?: @"",
    @"message" : message ?: @"",
  };
  if ([NSThread isMainThread]) {
    r(payload);
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      r(payload);
    });
  }
}

- (void)releaseSceneWithCode:(NSString *)code message:(NSString *)message {
  const char *codeUtf8 = code.length > 0 ? code.UTF8String : "";
  const char *messageUtf8 = message.length > 0 ? message.UTF8String : "";
  BOOL won = FusionStartGateComplete(self.gate, codeUtf8, messageUtf8);
  [self destroyHandler];
  if (won) {
    [self deliverPendingWithToken:nil code:code message:message ?: @""];
  }
}

- (void)destroyHandler {
  AlicomFusionAuthHandler *h = self.handler;
  self.handler = nil;
  self.halfway = nil;
  if (h != nil) {
    @try {
      if (self.sceneStarted && self.templateId.length > 0) [h stopSceneWithTemplateId:self.templateId];
      [h destroy];
    } @catch (NSException *e) {
    }
  }
  self.sceneStarted = NO;
}

- (UIViewController *)topViewController {
  UIWindow *window = nil;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      if (w.isKeyWindow) { window = w; break; }
    }
    if (window) break;
  }
  UIViewController *vc = window.rootViewController;
  while (vc.presentedViewController) vc = vc.presentedViewController;
  return vc;
}

static NSString *PFCode(AlicomFusionEvent *e) { return e.resultCode ?: @""; }
static NSString *PFMsg(AlicomFusionEvent *e) { return e.resultMsg ?: @""; }

#pragma mark - AlicomFusionAuthDelegate

- (AlicomFusionAuthToken *)onSDKTokenUpdate:(AlicomFusionAuthHandler *)handler {
  // Ask Dart for a refreshed token. Auth tokens typically last ~3600s; if the
  // host does not answer (or we are on the main thread and cannot block),
  // reuse the token from `start`.
  if (handler != self.handler || self.channel == nil || [NSThread isMainThread]) {
    return [[AlicomFusionAuthToken alloc] initWithTokenStr:self.authToken ?: @""];
  }
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSString *refreshed = self.authToken ?: @"";
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.channel invokeMethod:@"onTokenUpdate"
                     arguments:nil
                        result:^(id _Nullable result) {
                          if (handler == self.handler &&
                              [result isKindOfClass:[NSString class]] &&
                              [(NSString *)result length] > 0) {
                            refreshed = (NSString *)result;
                            self.authToken = refreshed;
                          }
                          dispatch_semaphore_signal(sem);
                        }];
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
  return [[AlicomFusionAuthToken alloc] initWithTokenStr:refreshed ?: @""];
}

- (void)onSDKTokenAuthSuccess:(AlicomFusionAuthHandler *)handler {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (handler != self.handler || self.sceneStarted) return;
    UIViewController *vc = [self topViewController];
    if (vc == nil) {
      [self resolve:nil code:@"no_activity" message:@"No foreground view controller"];
      [self releaseSceneWithCode:@"cancelled" message:@""];
      return;
    }
    self.sceneStarted = YES;
    [handler startSceneWithTemplateId:self.templateId viewController:vc];
  });
}

- (void)onSDKTokenAuthFailure:(AlicomFusionAuthHandler *)handler
                    failToken:(AlicomFusionAuthToken *)failToken
                        error:(AlicomFusionEvent *)error {
  if (handler != self.handler) return;
  [self resolve:nil code:PFCode(error) message:PFMsg(error)];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self releaseSceneWithCode:@"cancelled" message:@""];
  });
}

- (void)onVerifySuccess:(AlicomFusionAuthHandler *)handler
               nodeName:(NSString *)nodeName
              maskToken:(NSString *)maskToken
                  event:(AlicomFusionEvent *)event {
  if (handler != self.handler) return;
  [self resolve:maskToken code:PFCode(event) message:PFMsg(event)];
}

- (void)onHalfwayVerifySuccess:(AlicomFusionAuthHandler *)handler
                      nodeName:(NSString *)nodeName
                     maskToken:(NSString *)maskToken
                         event:(AlicomFusionEvent *)event
                   resultBlock:(void (^)(BOOL))resultBlock {
  if (handler != self.handler) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (handler == self.handler) self.halfway = resultBlock;
  });
  [self resolve:maskToken code:PFCode(event) message:PFMsg(event)];
}

- (void)onVerifyFailed:(AlicomFusionAuthHandler *)handler
              nodeName:(NSString *)nodeName
                 error:(AlicomFusionEvent *)error {
  if (handler != self.handler) return;
  // Let the template move to its fallback node (as the demo does).
  dispatch_async(dispatch_get_main_queue(), ^{
    if (handler == self.handler) {
      [self.handler continueSceneWithTemplateId:self.templateId isSuccess:NO];
    }
  });
}

- (void)onTemplateFinish:(AlicomFusionAuthHandler *)handler event:(AlicomFusionEvent *)event {
  if (handler != self.handler) return;
  [self resolve:nil code:PFCode(event) message:PFMsg(event)];
  dispatch_async(dispatch_get_main_queue(), ^{
    [self releaseSceneWithCode:@"cancelled" message:@""];
  });
}

// Progress notices (900003/900004 start/end loading etc.); the template keeps
// running and still ends through onTemplateFinish.
- (void)onVerifyInterrupt:(AlicomFusionAuthHandler *)handler event:(AlicomFusionEvent *)event {
}

- (NSString *)onGetPhoneNumberForVerification:(AlicomFusionAuthHandler *)handler
                                        event:(AlicomFusionEvent *)event {
  return @"";
}

- (void)onProtocolClick:(AlicomFusionAuthHandler *)handler
           protocolName:(NSString *)protocolName
            protocolUrl:(NSString *)protocolUrl
                  event:(AlicomFusionEvent *)event {
  NSURL *url = [NSURL URLWithString:protocolUrl ?: @""];
  if (url == nil || !([url.scheme isEqualToString:@"https"] || [url.scheme isEqualToString:@"http"])) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
  });
}

@end
