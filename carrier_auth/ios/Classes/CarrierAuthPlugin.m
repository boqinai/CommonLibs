#import "CarrierAuthPlugin.h"
#import <UIKit/UIKit.h>

// Public standalone API documented by Aliyun. The pinned vendor framework
// includes TXCommonHandler/TXCustomModel but exports only fusion headers.
// Resolve the documented classes at runtime; do not invoke the scene engine.
@protocol CarrierSDK <NSObject>
+ (instancetype)sharedInstance;
- (void)setAuthSDKInfo:(NSString *)info complete:(void (^)(NSDictionary *))complete;
- (void)getLoginTokenWithTimeout:(NSTimeInterval)timeout controller:(UIViewController *)controller
                          model:(id)model complete:(void (^)(NSDictionary *))complete;
- (void)cancelLoginVCAnimated:(BOOL)animated complete:(void (^)(void))complete;
@end

@interface CarrierAuthPlugin ()
@property(nonatomic, copy) FlutterResult pending;
@property(nonatomic, strong) id<CarrierSDK> sdk;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) BOOL closing;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, weak) id<FlutterPluginRegistrar> registrar;
@end

@implementation CarrierAuthPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  CarrierAuthPlugin *instance = [CarrierAuthPlugin new];
  instance.registrar = registrar;
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"boqinai/carrier_auth"
      binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"cancel"]) {
    [self finish:@"cancelled" token:nil]; result(nil); return;
  }
  if (![call.method isEqualToString:@"start"]) { result(FlutterMethodNotImplemented); return; }
  if (self.pending || self.closing) { result([FlutterError errorWithCode:@"busy" message:@"Authorization is active" details:nil]); return; }
  NSString *key = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments[@"sdkKey"] : nil;
  Class sdkClass = NSClassFromString(@"TXCommonHandler");
  Class modelClass = NSClassFromString(@"TXCustomModel");
  if (!key.length || !sdkClass || !modelClass) { result(@{@"code":@"unavailable"}); return; }
  NSDictionary *appearance = call.arguments[@"appearance"] ?: @{};
  UIColor *(^color)(NSString *) = ^UIColor *(NSString *role) {
    uint32_t argb = [appearance[role] unsignedIntValue];
    return [UIColor colorWithRed:((argb >> 16) & 255)/255.0 green:((argb >> 8) & 255)/255.0 blue:(argb & 255)/255.0 alpha:1];
  };
  NSArray *agreements = call.arguments[@"agreements"];
  NSNumber *sdkTimeoutMs = call.arguments[@"sdkTimeoutMs"] ?: @10000;
  NSNumber *authorizationTimeoutMs = call.arguments[@"authorizationTimeoutMs"] ?: @180000;
  if (![agreements isKindOfClass:NSArray.class] || agreements.count < 1 || agreements.count > 3 ||
      sdkTimeoutMs.doubleValue <= 0 || sdkTimeoutMs.doubleValue > 60000 ||
      authorizationTimeoutMs.doubleValue <= 0 || authorizationTimeoutMs.doubleValue > 1800000) {
    result(@{@"code":@"bad_args"}); return;
  }
  for (NSDictionary *agreement in agreements) {
    if (![agreement isKindOfClass:NSDictionary.class] || ![agreement[@"title"] isKindOfClass:NSString.class] || ![agreement[@"url"] isKindOfClass:NSString.class]) { result(@{@"code":@"bad_args"}); return; }
    NSURL *url = [NSURL URLWithString:agreement[@"url"]];
    if (![url.scheme isEqualToString:@"https"] || !url.host.length || ![agreement[@"title"] length]) { result(@{@"code":@"bad_args"}); return; }
  }
  self.pending = result;
  NSUInteger request = ++self.generation;
  __weak typeof(self) weakSelf = self;
  @try {
    self.sdk = [(id<CarrierSDK>)sdkClass sharedInstance];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:authorizationTimeoutMs.doubleValue/1000.0 repeats:NO block:^(NSTimer *timer) {
      if (request == weakSelf.generation) [weakSelf finish:@"600015" token:nil];
    }];
    [self.sdk setAuthSDKInfo:key complete:^(NSDictionary *response) {
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || request != self.generation || !self.pending) return;
        NSString *code = [NSString stringWithFormat:@"%@", response[@"resultCode"] ?: @""];
        if (![code isEqualToString:@"600000"]) { [self finish:code token:nil]; return; }
        @try {
          id model = [modelClass new];
          [model setValue:color(@"surfaceColor") forKey:@"backgroundColor"];
          [model setValue:color(@"surfaceColor") forKey:@"navColor"];
          [model setValue:[[NSAttributedString alloc] initWithString:call.arguments[@"title"] attributes:@{NSForegroundColorAttributeName:color(@"textColor")}] forKey:@"navTitle"];
          [model setValue:color(@"textColor") forKey:@"numberColor"];
          [model setValue:[UIFont systemFontOfSize:[appearance[@"numberTextSize"] doubleValue] weight:UIFontWeightSemibold] forKey:@"numberFont"];
          [model setValue:@[color(@"secondaryTextColor"),color(@"linkColor")] forKey:@"privacyColors"];
          CGFloat radius = [appearance[@"cornerRadius"] doubleValue];
          CGFloat imageSize = radius * 2 + 4;
          NSMutableArray *images = [NSMutableArray array];
          for (NSString *role in @[@"primaryColor",@"primaryColor",@"pressedColor"]) {
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(imageSize,imageSize)];
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
              [color(role) setFill];
              [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,imageSize,imageSize) cornerRadius:radius] fill];
            }];
            [images addObject:[image resizableImageWithCapInsets:UIEdgeInsetsMake(radius+1,radius+1,radius+1,radius+1)]];
          }
          [model setValue:images forKey:@"loginBtnBgImgs"];
          // Keep the vendor's masked number, carrier agreement and unchecked consent.
          NSArray *slots = @[@"privacyOne", @"privacyTwo", @"privacyThree"];
          for (NSUInteger index = 0; index < agreements.count; index++) {
            NSDictionary *agreement = agreements[index];
            [model setValue:@[agreement[@"title"], agreement[@"url"]] forKey:slots[index]];
          }
          [model setValue:@NO forKey:@"checkBoxIsChecked"];
          [model setValue:@NO forKey:@"checkBoxIsHidden"];
          [model setValue:[[NSAttributedString alloc] initWithString:call.arguments[@"loginButtonText"]
              attributes:@{NSForegroundColorAttributeName:color(@"onPrimaryColor"),
                NSFontAttributeName:[UIFont systemFontOfSize:[appearance[@"buttonTextSize"] doubleValue] weight:UIFontWeightSemibold]}] forKey:@"loginBtnText"];
          [model setValue:[[NSAttributedString alloc] initWithString:call.arguments[@"smsButtonText"]
              attributes:@{NSForegroundColorAttributeName:color(@"linkColor"),
                NSFontAttributeName:[UIFont systemFontOfSize:[appearance[@"buttonTextSize"] doubleValue]]}] forKey:@"changeBtnTitle"];
          UIViewController *controller = self.registrar.viewController;
          while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
          }
          if (!controller) { [self finish:@"unavailable" token:nil]; return; }
          [self.sdk getLoginTokenWithTimeout:sdkTimeoutMs.doubleValue/1000.0 controller:controller model:model complete:^(NSDictionary *r) {
            dispatch_async(dispatch_get_main_queue(), ^{
              typeof(self) self = weakSelf;
              if (!self || request != self.generation || !self.pending) return;
              NSString *c = [NSString stringWithFormat:@"%@", r[@"resultCode"] ?: @""];
              if ([c isEqualToString:@"600001"] || [@[@"700002", @"700003", @"700004"] containsObject:c]) return;
              if ([c isEqualToString:@"600000"]) {
                NSString *token = [r[@"token"] isKindOfClass:NSString.class] ? r[@"token"] : nil;
                [self finish:token.length ? c : @"invalid_result" token:token];
              } else if ([c isEqualToString:@"700000"]) [self finish:@"cancelled" token:nil];
              else if ([c isEqualToString:@"700001"]) [self finish:@"switch_sms" token:nil];
              else [self finish:c token:nil];
            });
          }];
        } @catch (NSException *exception) { [self finish:@"start_failed" token:nil]; }
      });
    }];
  } @catch (NSException *exception) { [self finish:@"start_failed" token:nil]; }
}

- (void)finish:(NSString *)code token:(NSString *)token {
  if (!self.pending) return;
  FlutterResult reply = self.pending;
  self.pending = nil;
  self.closing = YES;
  self.generation++;
  [self.timer invalidate]; self.timer = nil;
  __weak typeof(self) weakSelf = self;
  __block BOOL delivered = NO;
  void (^complete)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      if (delivered) return;
      delivered = YES;
      weakSelf.closing = NO;
      reply(token.length ? @{@"code":code, @"token":token} : @{@"code":code});
    });
  };
  @try {
    if (self.sdk) [self.sdk cancelLoginVCAnimated:NO complete:complete];
    else complete();
  } @catch (NSException *exception) { complete(); }
  // A vendor close callback must not leave Flutter's login button busy forever.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC), dispatch_get_main_queue(), complete);
}
@end
