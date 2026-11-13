#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <math.h>

// The target IPA is version 3.3.3, bundle com.nari.digitalAttendance.
// Settings are edited in the injected overlay and take effect immediately.
static NSDictionary *gPrefs;
static UIWindow *gOverlayWindow;
static __weak UIWindow *gPreviousKeyWindow;
static NSString *gRawDeviceID;
static NSString *gReturnedDeviceID;
static NSString *gRawIDFV;
static NSString *gReturnedIDFV;

static NSString *EDTPrefsPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
        path = [[library stringByAppendingPathComponent:@"Application Support/EDTProbe"]
                stringByAppendingPathComponent:@"settings.plist"];
    });
    return path;
}

static id EDTGetPref(NSString *key) {
    @synchronized ([NSUserDefaults class]) {
        return gPrefs[key];
    }
}

static BOOL EDTSetPref(NSString *key, id value) {
    @synchronized ([NSUserDefaults class]) {
        NSMutableDictionary *updated = [gPrefs mutableCopy] ?: [NSMutableDictionary dictionary];
        if (value) updated[key] = value;
        else [updated removeObjectForKey:key];
        NSString *directory = [EDTPrefsPath() stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                        withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
        if (![updated writeToFile:EDTPrefsPath() atomically:YES]) return NO;
        gPrefs = [updated copy];
        return YES;
    }
}

static BOOL EDTEnabled(NSString *key) {
    return [EDTGetPref(key) boolValue];
}

static NSString *EDTOldDeviceID(void) {
    id value = EDTGetPref(@"authorized_device_id");
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : nil;
}

static BOOL EDTParseCoordinate(NSString *text, double minimum, double maximum, double *result) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) ||
        value < minimum || value > maximum) return NO;
    *result = value;
    return YES;
}

static BOOL EDTTestCoordinate(CLLocationCoordinate2D *result) {
    double latitude, longitude;
    if (!EDTEnabled(@"location_override") || !EDTEnabled(@"custom_location_enabled") ||
        !EDTParseCoordinate(EDTGetPref(@"test_latitude"), -90, 90, &latitude) ||
        !EDTParseCoordinate(EDTGetPref(@"test_longitude"), -180, 180, &longitude)) return NO;
    *result = CLLocationCoordinate2DMake(latitude, longitude);
    return YES;
}

static CLLocation *EDTTestLocation(void) {
    CLLocationCoordinate2D coordinate;
    if (!EDTTestCoordinate(&coordinate)) return nil;
    return [[CLLocation alloc] initWithCoordinate:coordinate altitude:0
                               horizontalAccuracy:5 verticalAccuracy:5 timestamp:[NSDate date]];
}

static NSString *EDTDisplayValue(id value) {
    if (!value || value == [NSNull null]) return @"（空）";
    if ([value isKindOfClass:[NSData class]]) {
        NSString *decoded = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
        return decoded.length ? decoded : [NSString stringWithFormat:@"（二进制数据，%lu 字节）", (unsigned long)[value length]];
    }
    NSString *result = [value description];
    return result.length ? result : @"（空）";
}

static BOOL EDTIsDeviceIDKey(NSString *key) {
    return [key isKindOfClass:[NSString class]] && [key hasPrefix:@"E_DIAN_TONG_DEVICE_ID"];
}

static NSString *EDTCurrentDeviceIDKey(NSUserDefaults *defaults) {
    NSDictionary *stored = [defaults dictionaryRepresentation];
    if (stored[@"E_DIAN_TONG_DEVICE_ID"]) return @"E_DIAN_TONG_DEVICE_ID";
    for (NSString *key in [[stored allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (EDTIsDeviceIDKey(key)) return key;
    }
    return @"E_DIAN_TONG_DEVICE_ID";
}

static void EDTRecordDeviceID(id original, id returned) {
    @synchronized ([NSUserDefaults class]) {
        gRawDeviceID = EDTDisplayValue(original);
        gReturnedDeviceID = EDTDisplayValue(returned);
    }
}

static void EDTRecordIDFV(NSUUID *original, NSUUID *returned) {
    @synchronized ([NSUserDefaults class]) {
        gRawIDFV = EDTDisplayValue(original.UUIDString);
        gReturnedIDFV = EDTDisplayValue(returned.UUIDString);
    }
}

@interface EDTOverlayWindow : UIWindow
@end

@implementation EDTOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface EDTPanelController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIButton *bubble;
@property (nonatomic, strong) UIScrollView *panel;
@property (nonatomic, strong) UISwitch *vpnSwitch;
@property (nonatomic, strong) UISwitch *locationSwitch;
@property (nonatomic, strong) UISwitch *customLocationSwitch;
@property (nonatomic, strong) UISwitch *directLocationSwitch;
@property (nonatomic, strong) UISwitch *deviceSwitch;
@property (nonatomic, strong) UISwitch *idfvSwitch;
@property (nonatomic, strong) UISegmentedControl *vpnMode;
@property (nonatomic, strong) UITextField *deviceField;
@property (nonatomic, strong) UITextField *idfvField;
@property (nonatomic, strong) UITextField *latitudeField;
@property (nonatomic, strong) UITextField *longitudeField;
@property (nonatomic, strong) UIView *mapContainer;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *mapPin;
@property (nonatomic, strong) UILabel *deviceRawLabel;
@property (nonatomic, strong) UILabel *deviceReturnedLabel;
@property (nonatomic, strong) UILabel *idfvRawLabel;
@property (nonatomic, strong) UILabel *idfvReturnedLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, assign) BOOL expanded;
@end

@implementation EDTPanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.bubble = [UIButton buttonWithType:UIButtonTypeSystem];
    self.bubble.frame = CGRectMake(0, 0, 52, 52);
    self.bubble.backgroundColor = [UIColor colorWithRed:0.10 green:0.39 blue:0.86 alpha:0.96];
    self.bubble.layer.cornerRadius = 26;
    self.bubble.layer.shadowColor = UIColor.blackColor.CGColor;
    self.bubble.layer.shadowOpacity = 0.24;
    self.bubble.layer.shadowRadius = 5;
    [self.bubble setTitle:@"测试" forState:UIControlStateNormal];
    [self.bubble setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.bubble.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.bubble addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBubble:)];
    [self.bubble addGestureRecognizer:drag];
    [self.view addSubview:self.bubble];

    self.panel = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.98 alpha:0.98];
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithWhite:0.78 alpha:1].CGColor;
    self.panel.layer.shadowColor = UIColor.blackColor.CGColor;
    self.panel.layer.shadowOpacity = 0.22;
    self.panel.layer.shadowRadius = 8;
    self.panel.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.panel.hidden = YES;
    [self.view addSubview:self.panel];

    UIButton *header = [UIButton buttonWithType:UIButtonTypeSystem];
    header.frame = CGRectMake(12, 8, 296, 38);
    [header setTitle:@"安全测试设置  ▴" forState:UIControlStateNormal];
    header.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [header addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:header];

    self.vpnSwitch = [self addSwitch:@"VPN 状态改写" key:@"vpn_override" y:55];
    self.vpnMode = [[UISegmentedControl alloc] initWithItems:@[@"在线", @"离线"]];
    self.vpnMode.frame = CGRectMake(14, 96, 292, 32);
    self.vpnMode.selectedSegmentIndex = [EDTGetPref(@"vpn_mode") isEqualToString:@"offline"] ? 1 : 0;
    [self.vpnMode addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.vpnMode];

    self.locationSwitch = [self addSwitch:@"虚拟定位检测改写" key:@"location_override" y:140];
    self.customLocationSwitch = [self addSwitch:@"使用指定经纬度" key:@"custom_location_enabled" y:185];
    self.latitudeField = [self addField:@"纬度（-90 到 90）" key:@"test_latitude" y:225];
    self.longitudeField = [self addField:@"经度（-180 到 180）" key:@"test_longitude" y:268];
    self.latitudeField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    self.longitudeField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    UIButton *pickOnMap = [UIButton buttonWithType:UIButtonTypeSystem];
    pickOnMap.frame = CGRectMake(14, 310, 292, 34);
    [pickOnMap setTitle:@"地图选点" forState:UIControlStateNormal];
    [pickOnMap addTarget:self action:@selector(showMapPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:pickOnMap];
    self.directLocationSwitch = [self addSwitch:@"直接返回测试位置" key:@"direct_location_delivery" y:350];

    self.deviceSwitch = [self addSwitch:@"旧设备 ID 替换" key:@"device_id_override" y:405];
    self.deviceField = [self addField:@"填写已授权旧设备 ID" key:@"authorized_device_id" y:447];
    self.deviceRawLabel = [self addValueLabelAtY:489];
    self.deviceReturnedLabel = [self addValueLabelAtY:512];
    self.idfvSwitch = [self addSwitch:@"IDFV 替换" key:@"idfv_override" y:544];
    self.idfvField = [self addField:@"填写已授权 IDFV UUID" key:@"authorized_idfv" y:586];
    self.idfvRawLabel = [self addValueLabelAtY:628];
    self.idfvReturnedLabel = [self addValueLabelAtY:651];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    refresh.frame = CGRectMake(14, 683, 292, 35);
    [refresh setTitle:@"刷新当前读取值" forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(refreshIdentifiers) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:refresh];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 722, 292, 42)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = UIColor.darkGrayColor;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"保存后重新发起登录或定位测试。";
    [self.panel addSubview:self.statusLabel];
    self.panel.contentSize = CGSizeMake(320, 774);
    [self refreshIdentifiers];
}

- (UISwitch *)addSwitch:(NSString *)title key:(NSString *)key y:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 225, 36)];
    label.text = title;
    label.font = [UIFont systemFontOfSize:15];
    [self.panel addSubview:label];
    UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectMake(250, y + 2, 51, 31)];
    toggle.on = EDTEnabled(key);
    toggle.accessibilityIdentifier = key;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:toggle];
    return toggle;
}

- (UITextField *)addField:(NSString *)placeholder key:(NSString *)key y:(CGFloat)y {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(14, y, 292, 37)];
    field.placeholder = placeholder;
    field.text = EDTGetPref(key) ?: @"";
    field.accessibilityIdentifier = key;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    [self.panel addSubview:field];
    return field;
}

- (UILabel *)addValueLabelAtY:(CGFloat)y {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 292, 22)];
    label.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    label.textColor = UIColor.darkGrayColor;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.panel addSubview:label];
    return label;
}

- (void)refreshIdentifiers {
    // Reading through the public APIs exercises the same hook path as the app.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    (void)[defaults objectForKey:EDTCurrentDeviceIDKey(defaults)];
    (void)[[UIDevice currentDevice] identifierForVendor];
    @synchronized ([NSUserDefaults class]) {
        self.deviceRawLabel.text = [@"原始：" stringByAppendingString:gRawDeviceID ?: @"（未读取）"];
        self.deviceReturnedLabel.text = [@"返回：" stringByAppendingString:gReturnedDeviceID ?: @"（未读取）"];
        self.idfvRawLabel.text = [@"原始：" stringByAppendingString:gRawIDFV ?: @"（未读取）"];
        self.idfvReturnedLabel.text = [@"返回：" stringByAppendingString:gReturnedIDFV ?: @"（未读取）"];
    }
}

- (void)showMapPicker {
    [self.view endEditing:YES];
    if (!self.mapContainer) {
        self.mapContainer = [[UIView alloc] initWithFrame:CGRectZero];
        self.mapContainer.backgroundColor = UIColor.whiteColor;
        self.mapContainer.layer.cornerRadius = 14;
        self.mapContainer.layer.masksToBounds = YES;
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, 290, 35)];
        title.text = @"轻点地图选择测试坐标";
        title.font = [UIFont boldSystemFontOfSize:16];
        title.tag = 101;
        [self.mapContainer addSubview:title];
        self.mapView = [[MKMapView alloc] initWithFrame:CGRectZero];
        self.mapView.showsUserLocation = NO;
        self.mapView.tag = 102;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mapTapped:)];
        tap.cancelsTouchesInView = NO;
        [self.mapView addGestureRecognizer:tap];
        [self.mapContainer addSubview:self.mapView];
        UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
        [cancel setTitle:@"取消" forState:UIControlStateNormal];
        [cancel addTarget:self action:@selector(hideMapPicker) forControlEvents:UIControlEventTouchUpInside];
        cancel.tag = 103;
        [self.mapContainer addSubview:cancel];
        UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem];
        [confirm setTitle:@"使用此位置" forState:UIControlStateNormal];
        [confirm addTarget:self action:@selector(confirmMapPicker) forControlEvents:UIControlEventTouchUpInside];
        confirm.tag = 104;
        [self.mapContainer addSubview:confirm];
        [self.view addSubview:self.mapContainer];
    }
    [self positionMapPicker];
    double latitude = 39.9042, longitude = 116.4074;
    EDTParseCoordinate(self.latitudeField.text, -90, 90, &latitude);
    EDTParseCoordinate(self.longitudeField.text, -180, 180, &longitude);
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude, longitude);
    [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 2500, 2500) animated:NO];
    if (!self.mapPin) {
        self.mapPin = [MKPointAnnotation new];
        [self.mapView addAnnotation:self.mapPin];
    }
    self.mapPin.coordinate = coordinate;
    self.mapContainer.hidden = NO;
    [self.view bringSubviewToFront:self.mapContainer];
}

- (void)positionMapPicker {
    if (!self.mapContainer) return;
    CGRect bounds = self.view.bounds;
    CGFloat width = MIN(360, bounds.size.width - 20);
    CGFloat height = MIN(480, bounds.size.height - 100);
    self.mapContainer.frame = CGRectMake((bounds.size.width - width) / 2,
                                         (bounds.size.height - height) / 2, width, height);
    [self.mapContainer viewWithTag:101].frame = CGRectMake(12, 5, width - 24, 35);
    self.mapView.frame = CGRectMake(8, 42, width - 16, height - 94);
    [self.mapContainer viewWithTag:103].frame = CGRectMake(12, height - 48, 105, 40);
    [self.mapContainer viewWithTag:104].frame = CGRectMake(width - 145, height - 48, 133, 40);
}

- (void)mapTapped:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded) return;
    CGPoint point = [gesture locationInView:self.mapView];
    self.mapPin.coordinate = [self.mapView convertPoint:point toCoordinateFromView:self.mapView];
}

- (void)hideMapPicker {
    self.mapContainer.hidden = YES;
}

- (void)confirmMapPicker {
    CLLocationCoordinate2D coordinate = self.mapPin.coordinate;
    NSString *latitude = [NSString stringWithFormat:@"%.8f", coordinate.latitude];
    NSString *longitude = [NSString stringWithFormat:@"%.8f", coordinate.longitude];
    BOOL saved = EDTSetPref(@"test_latitude", latitude) &&
                 EDTSetPref(@"test_longitude", longitude) &&
                 EDTSetPref(@"custom_location_enabled", @YES);
    if (saved) {
        self.latitudeField.text = latitude;
        self.longitudeField.text = longitude;
        self.customLocationSwitch.on = YES;
        self.statusLabel.text = @"坐标已保存；请重新发起定位测试。";
        [self hideMapPicker];
    } else {
        self.statusLabel.text = @"坐标保存失败，请检查应用存储空间。";
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (CGRectEqualToRect(self.bubble.frame, CGRectZero)) return;
    CGRect bounds = self.view.bounds;
    CGPoint center = self.bubble.center;
    if (center.x < 26 || center.x > bounds.size.width - 26 ||
        center.y < 70 || center.y > bounds.size.height - 26) {
        center = CGPointMake(bounds.size.width - 36, 130);
    }
    self.bubble.center = center;
    [self positionPanel];
    [self positionMapPicker];
}

- (void)positionPanel {
    CGRect bounds = self.view.bounds;
    CGFloat width = MIN(320, bounds.size.width - 20);
    CGFloat height = MIN(421, bounds.size.height - 90);
    CGFloat x = MAX(10, MIN(self.bubble.center.x - width + 26, bounds.size.width - width - 10));
    CGFloat y = MIN(self.bubble.frame.origin.y + 58, bounds.size.height - height - 10);
    self.panel.frame = CGRectMake(x, MAX(10, y), width, height);
}

- (void)togglePanel {
    [self.view endEditing:YES];
    self.expanded = !self.expanded;
    self.panel.hidden = !self.expanded;
    if (self.expanded) {
        for (UIWindow *window in self.view.window.windowScene.windows) {
            if (window.isKeyWindow && window != self.view.window) {
                gPreviousKeyWindow = window;
                break;
            }
        }
        [self.view.window makeKeyWindow];
        [self positionPanel];
        [self refreshIdentifiers];
    } else {
        [self hideMapPicker];
        [gPreviousKeyWindow makeKeyWindow];
    }
}

- (void)dragBubble:(UIPanGestureRecognizer *)gesture {
    CGPoint movement = [gesture translationInView:self.view];
    CGPoint center = self.bubble.center;
    center.x = MAX(26, MIN(self.view.bounds.size.width - 26, center.x + movement.x));
    center.y = MAX(70, MIN(self.view.bounds.size.height - 26, center.y + movement.y));
    self.bubble.center = center;
    [gesture setTranslation:CGPointZero inView:self.view];
    [self positionPanel];
}

- (void)switchChanged:(UISwitch *)sender {
    BOOL saved = EDTSetPref(sender.accessibilityIdentifier, @(sender.on));
    self.statusLabel.text = saved ? @"已保存；请重新发起测试。" : @"保存失败：请检查应用存储空间。";
    if (!saved) sender.on = !sender.on;
    [self refreshIdentifiers];
}

- (void)modeChanged:(UISegmentedControl *)sender {
    BOOL saved = EDTSetPref(@"vpn_mode", sender.selectedSegmentIndex == 1 ? @"offline" : @"online");
    self.statusLabel.text = saved ? @"VPN 模式已保存；请重新发起测试。" : @"保存失败：请检查应用存储空间。";
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)field {
    NSString *value = [field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([field.accessibilityIdentifier isEqualToString:@"test_latitude"] ||
        [field.accessibilityIdentifier isEqualToString:@"test_longitude"]) {
        double parsed;
        double minimum = [field.accessibilityIdentifier isEqualToString:@"test_latitude"] ? -90 : -180;
        double maximum = -minimum;
        if (value.length > 0 && !EDTParseCoordinate(value, minimum, maximum, &parsed)) {
            self.statusLabel.text = @"经纬度格式或范围不正确。";
            return;
        }
    }
    if ([field.accessibilityIdentifier isEqualToString:@"authorized_idfv"] &&
        value.length > 0 && ![[NSUUID alloc] initWithUUIDString:value]) {
        self.statusLabel.text = @"IDFV 格式错误：需要有效 UUID。";
        return;
    }
    BOOL saved = EDTSetPref(field.accessibilityIdentifier, value ?: @"");
    self.statusLabel.text = saved ? @"参数已保存；请重新发起测试。" : @"保存失败：请检查应用存储空间。";
    [self refreshIdentifiers];
}

@end

static void EDTShowOverlay(void) {
    if (gOverlayWindow) return;
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if ([candidate isKindOfClass:[UIWindowScene class]] &&
            candidate.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)candidate;
            break;
        }
    }
    if (!scene) return;
    EDTOverlayWindow *window = [[EDTOverlayWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 10;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [EDTPanelController new];
    window.hidden = NO;
    gOverlayWindow = window;
    NSLog(@"[EDTProbe] floating panel displayed");
}

%hook NRVpnTool

- (BOOL)isVpnOnline {
    if (EDTEnabled(@"vpn_override")) {
        NSString *mode = EDTGetPref(@"vpn_mode");
        if ([mode isEqualToString:@"online"]) {
            NSLog(@"[EDTProbe] NRVpnTool isVpnOnline => YES");
            return YES;
        }
        if ([mode isEqualToString:@"offline"]) {
            NSLog(@"[EDTProbe] NRVpnTool isVpnOnline => NO");
            return NO;
        }
    }
    return %orig;
}

%end

static BOOL EDTShouldDirectLocation(void) {
    CLLocationCoordinate2D coordinate;
    return EDTEnabled(@"direct_location_delivery") && EDTTestCoordinate(&coordinate);
}

static void EDTDeliverLocation(CLLocationManager *manager) {
    CLLocation *location = EDTTestLocation();
    if (!location) return;
    __weak CLLocationManager *weakManager = manager;
    dispatch_async(dispatch_get_main_queue(), ^{
        CLLocationManager *strongManager = weakManager;
        id<CLLocationManagerDelegate> delegate = strongManager.delegate;
        if (strongManager && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [delegate locationManager:strongManager didUpdateLocations:@[location]];
            NSLog(@"[EDTProbe] delivered direct test location");
        }
    });
}

%hook CLLocation

- (CLLocationCoordinate2D)coordinate {
    CLLocationCoordinate2D coordinate;
    if (EDTTestCoordinate(&coordinate)) return coordinate;
    return %orig;
}

%end

%hook CLLocationManager

- (void)requestLocation {
    if (EDTShouldDirectLocation()) {
        EDTDeliverLocation(self);
        return;
    }
    %orig;
}

- (void)startUpdatingLocation {
    if (EDTShouldDirectLocation()) {
        EDTDeliverLocation(self);
        return;
    }
    %orig;
}

%end

%hook CLLocationSourceInformation

- (BOOL)isSimulatedBySoftware {
    if (EDTEnabled(@"location_override")) {
        NSLog(@"[EDTProbe] CLLocationSourceInformation isSimulatedBySoftware => NO");
        return NO;
    }
    return %orig;
}

%end

%hook AMapLocationManager

- (void)setDetectRiskOfFakeLocation:(BOOL)enabled {
    if (EDTEnabled(@"location_override")) {
        NSLog(@"[EDTProbe] AMapLocationManager fake-location risk check disabled");
        %orig(NO);
        return;
    }
    %orig;
}

%end

%hook AMapGeoFenceManager

- (void)setDetectRiskOfFakeLocation:(BOOL)enabled {
    if (EDTEnabled(@"location_override")) {
        NSLog(@"[EDTProbe] AMapGeoFenceManager fake-location risk check disabled");
        %orig(NO);
        return;
    }
    %orig;
}

%end

%hook NSUserDefaults

- (id)objectForKey:(NSString *)key {
    if (!EDTIsDeviceIDKey(key)) return %orig;
    id original = %orig;
    NSString *oldID = EDTEnabled(@"device_id_override") ? EDTOldDeviceID() : nil;
    id returned = oldID ? ([original isKindOfClass:[NSData class]]
                           ? [oldID dataUsingEncoding:NSUTF8StringEncoding] : oldID) : original;
    EDTRecordDeviceID(original, returned);
    if (oldID) {
        NSLog(@"[EDTProbe] supplied configured device ID through objectForKey:");
    }
    return returned;
}

- (NSString *)stringForKey:(NSString *)key {
    if (!EDTIsDeviceIDKey(key)) return %orig;
    // dictionaryRepresentation bypasses our objectForKey: hook when stringForKey:
    // internally delegates to it.
    id raw = [self dictionaryRepresentation][key];
    NSString *original = %orig;
    NSString *oldID = EDTEnabled(@"device_id_override") ? EDTOldDeviceID() : nil;
    NSString *returned = oldID ?: original;
    EDTRecordDeviceID(raw, returned);
    if (oldID) {
        NSLog(@"[EDTProbe] supplied configured device ID through stringForKey:");
    }
    return returned;
}

%end

%hook UIDevice

- (NSUUID *)identifierForVendor {
    NSUUID *original = %orig;
    NSUUID *returned = original;
    if (EDTEnabled(@"idfv_override")) {
        NSString *value = EDTGetPref(@"authorized_idfv");
        NSUUID *uuid = [value isKindOfClass:[NSString class]] ? [[NSUUID alloc] initWithUUIDString:value] : nil;
        if (uuid) {
            NSLog(@"[EDTProbe] supplied configured identifierForVendor");
            returned = uuid;
        }
    }
    EDTRecordIDFV(original, returned);
    return returned;
}

%end

%ctor {
    @autoreleasepool {
        // Bundle IDs may change after re-signing; activate only in the target app.
        if (!NSClassFromString(@"NRXinTongLoginVC") || !NSClassFromString(@"NRVpnTool")) return;
        gPrefs = [NSDictionary dictionaryWithContentsOfFile:EDTPrefsPath()] ?: @{};
        NSLog(@"[EDTProbe] loaded settings: vpn=%d location=%d device=%d idfv=%d",
              EDTEnabled(@"vpn_override"), EDTEnabled(@"location_override"),
              EDTEnabled(@"device_id_override"), EDTEnabled(@"idfv_override"));
        %init;
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            EDTShowOverlay();
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ EDTShowOverlay(); });
    }
}
