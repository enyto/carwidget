#import "AxsCarWidget.h"
#import "AxsCarWidgetConfig.h"
#import "AxsCarWidgetPreferences.h"
#import "AxsCarWidgetWeatherSource.h"

#import <objc/runtime.h>
#include <math.h>

// The Weather framework picks the unit from the device setting; the widget follows it.
static NSString *axs_carwidget_temperature_unit = @"C";

// Without a console (no SSH / no Mac) the widget reports what it did to a file next to its
// preferences, so the log can be read in Filza and sent back.
static NSString * const AxsCarWidgetDiagnosticsName = @"com.axs.carwidget.log";

static void axs_carwidget_log(NSString *format, ...) {
    NSDateFormatter *stamp = [[NSDateFormatter alloc] init];
    stamp.dateFormat = @"HH:mm:ss.SSS";
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [stamp stringFromDate:[NSDate date]], message];
    NSLog(@"[AxsCarWidget] %@", message);
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *directory = [axs_carwidget_preferencesPath() stringByDeletingLastPathComponent];
    [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [directory stringByAppendingPathComponent:AxsCarWidgetDiagnosticsName];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:[NSURL fileURLWithPath:path]
                                                            error:&error];
    if (!handle) {
        [data writeToFile:path atomically:YES];
        return;
    }
    // Keep the file small: start over once it grows past ~64 KB.
    unsigned long long size = [handle seekToEndOfFile];
    if (size > 64 * 1024) {
        [handle closeFile];
        [data writeToFile:path atomically:YES];
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

@interface AxsCarWidget ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UIView *weatherBlock;
@property (nonatomic, strong) UIImageView *conditionView;
@property (nonatomic, strong) UILabel *conditionTextLabel;
@property (nonatomic, strong) UILabel *temperatureLabel;
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UILabel *forecastLabel;
@property (nonatomic, strong) UIImageView *pageUpView;
@property (nonatomic, strong) UIImageView *pageDownView;
@property (nonatomic, strong) UILabel *pageLabel;
@property (nonatomic, strong) NSDictionary *axs_carwidget_state;
@property (nonatomic, strong) NSTimer *clockTimer;
@property (nonatomic, strong) NSTimer *stateTimer;
@property (nonatomic, assign) BOOL axs_carwidget_forecastVisible;
@property (nonatomic, assign) BOOL axs_carwidget_pageVisible;
@end

@implementation AxsCarWidget {
    // Auto-synthesis is deferred when the property is declared by a protocol and only re-declared
    // in the class extension, so the storage is declared explicitly.
    NSString *_identifier;
    int _pageIndex;
    int _pageType;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        axs_carwidget_log(@"initWithFrame %@ (iOS %@)", NSStringFromCGRect(frame),
                          [[UIDevice currentDevice] systemVersion]);
        [self axs_carwidget_buildView];
        self.axs_carwidget_state = axs_carwidget_readPreferences();
        [self axs_carwidget_observePreferences];
        [self axs_carwidget_applyConfig];
        [self axs_carwidget_applyState];
        [self axs_carwidget_refreshClock];
        [self axs_carwidget_startTimers];
        // Network work must never run on the construction path of a CarPlay view.
        dispatch_async(dispatch_get_main_queue(), ^{
            [[AxsCarWidgetWeatherSource axs_carwidget_shared] axs_carwidget_refreshIfNeeded];
        });
    }
    return self;
}

- (void)dealloc {
    [_clockTimer invalidate];
    [_stateTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    axs_carwidget_log(@"mounted=%@ window=%@ bounds=%@ super=%@ class=%@",
        self.superview ? @"yes" : @"no", self.window ? @"yes" : @"no",
        NSStringFromCGRect(self.bounds), self.superview ? NSStringFromClass(self.superview.class) : @"nil",
        NSStringFromClass(self.class));
    if (self.superview) {
        [self axs_carwidget_layoutWidget];
        [self axs_carwidget_startTimers];
        [self axs_carwidget_refreshClock];
    } else {
        [self axs_carwidget_stopTimers];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self axs_carwidget_layoutWidget];
}

// A host may create the view with CGRectZero and only later give it a frame; pick that up.
- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (!CGRectEqualToRect(frame, self.bounds)) {
        axs_carwidget_log(@"setFrame %@", NSStringFromCGRect(frame));
    }
    [self axs_carwidget_layoutWidget];
    [self axs_carwidget_refreshClock];
}

#pragma mark - View construction

- (UILabel *)axs_carwidget_makeLabel:(CGFloat)size weight:(UIFontWeight)weight
                               color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.numberOfLines = 1;
    label.text = @"";
    label.backgroundColor = [UIColor clearColor];
    return label;
}

// Airaw hosts widgets inside CarPlay's own view tree. Everything here is frame based: no
// constraints, no stack views, so a rewrite of the hierarchy by the host cannot blank the card.
- (void)axs_carwidget_buildView {
    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = YES;
    self.opaque = NO;

    // Card: rounded, blurred material so the CarPlay wallpaper stays visible behind it.
    self.cardView = [[UIView alloc] initWithFrame:self.bounds];
    self.cardView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.cardView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.55];
    self.cardView.layer.cornerRadius = 16.0;
    self.cardView.layer.masksToBounds = YES;
    [self addSubview:self.cardView];

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.frame = self.cardView.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.cardView addSubview:blurView];

    // Clock.
    self.timeLabel = [self axs_carwidget_makeLabel:44.0 weight:UIFontWeightBold color:[UIColor whiteColor]];
    [self.cardView addSubview:self.timeLabel];
    self.dateLabel = [self axs_carwidget_makeLabel:18.0 weight:UIFontWeightMedium
                                             color:[UIColor colorWithWhite:1.0 alpha:0.65]];
    [self.cardView addSubview:self.dateLabel];

    // Weather block: one glyph, temperature, condition text and the city, stacked by frame.
    self.weatherBlock = [[UIView alloc] initWithFrame:CGRectZero];
    self.weatherBlock.backgroundColor = [UIColor clearColor];
    self.weatherBlock.userInteractionEnabled = NO;
    [self.cardView addSubview:self.weatherBlock];

    self.conditionView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.conditionView.contentMode = UIViewContentModeScaleAspectFit;
    self.conditionView.tintColor = [UIColor whiteColor];
    [self.weatherBlock addSubview:self.conditionView];

    self.temperatureLabel = [self axs_carwidget_makeLabel:22.0 weight:UIFontWeightSemibold
                                                   color:[UIColor whiteColor]];
    [self.weatherBlock addSubview:self.temperatureLabel];
    self.conditionTextLabel = [self axs_carwidget_makeLabel:18.0 weight:UIFontWeightSemibold
                                                     color:[UIColor whiteColor]];
    [self.weatherBlock addSubview:self.conditionTextLabel];
    self.cityLabel = [self axs_carwidget_makeLabel:17.0 weight:UIFontWeightRegular
                                            color:[UIColor colorWithWhite:1.0 alpha:0.65]];
    [self.weatherBlock addSubview:self.cityLabel];
    self.forecastLabel = [self axs_carwidget_makeLabel:15.0 weight:UIFontWeightMedium
                                                color:[UIColor colorWithWhite:1.0 alpha:0.45]];
    [self.weatherBlock addSubview:self.forecastLabel];

    // Page hint: Airaw pages with vertical swipes.
    self.pageUpView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.pageDownView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.pageLabel = [self axs_carwidget_makeLabel:11.0 weight:UIFontWeightMedium
                                            color:[UIColor colorWithWhite:1.0 alpha:0.4]];
    self.pageLabel.textAlignment = NSTextAlignmentCenter;
    [self.cardView addSubview:self.pageUpView];
    [self.cardView addSubview:self.pageDownView];
    [self.cardView addSubview:self.pageLabel];

    self.weatherBlock.hidden = YES;
    self.timeLabel.text = @"--:--";
    self.dateLabel.text = @"--";
    axs_carwidget_log(@"buildView done, self=%@", self.class);
}

#pragma mark - Layout

// Vertical rhythm for a 200x200 card: clock on top, weather pinned to the bottom.
- (void)axs_carwidget_layoutWidget {
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat width = CGRectGetWidth(self.bounds);
    if (height <= 1.0 || width <= 1.0) {
        axs_carwidget_log(@"layout skipped, bounds=%@", NSStringFromCGRect(self.bounds));
        return;
    }

    self.cardView.frame = self.bounds;
    CGFloat padding = height * 0.09;
    CGFloat pageColumn = self.axs_carwidget_pageVisible ? MAX(height * 0.10, 18.0) : 0.0;
    CGFloat reserve = self.axs_carwidget_pageVisible ? pageColumn + padding * 0.4 : 0.0;
    CGFloat contentWidth = MAX(width - padding * 2.0 - reserve, 1.0);

    self.cardView.layer.cornerRadius = height * 0.10;
    self.timeLabel.font = [UIFont systemFontOfSize:height * 0.24 weight:UIFontWeightBold];
    self.dateLabel.font = [UIFont systemFontOfSize:height * 0.11 weight:UIFontWeightMedium];
    self.temperatureLabel.font = [UIFont systemFontOfSize:height * 0.13 weight:UIFontWeightSemibold];
    self.conditionTextLabel.font = [UIFont systemFontOfSize:height * 0.10 weight:UIFontWeightSemibold];
    self.cityLabel.font = [UIFont systemFontOfSize:height * 0.095 weight:UIFontWeightRegular];
    self.forecastLabel.font = [UIFont systemFontOfSize:height * 0.08 weight:UIFontWeightMedium];
    self.pageLabel.font = [UIFont systemFontOfSize:MAX(height * 0.065, 8.0) weight:UIFontWeightMedium];

    CGFloat timeHeight = height * 0.26;
    CGFloat dateHeight = height * 0.11;
    self.timeLabel.frame = CGRectMake(padding, padding, contentWidth, timeHeight);
    self.dateLabel.frame = CGRectMake(padding, CGRectGetMaxY(self.timeLabel.frame) + height * 0.01,
                                      contentWidth, dateHeight);

    BOOL hasWeather = !self.weatherBlock.hidden;
    CGFloat blockHeight = height - padding * 2.0 - timeHeight - dateHeight - height * 0.04;
    CGFloat blockY = hasWeather ? height - padding - blockHeight
                                : CGRectGetMaxY(self.dateLabel.frame) + height * 0.04;
    if (!hasWeather) blockHeight = 0.0;
    self.weatherBlock.frame = CGRectMake(padding, blockY, contentWidth, blockHeight);

    // The weather block stacks its own rows; recompute them for the current size.
    [self axs_carwidget_layoutWeatherBlock];

    // Page hint column on the right.
    CGFloat side = MAX(height * 0.02, 6.0);
    CGFloat pageX = width - padding * 0.6 - pageColumn;
    CGFloat pageTop = padding;
    self.pageUpView.frame = CGRectMake(pageX + (pageColumn - side) / 2.0, pageTop, side, side);
    self.pageUpView.image = [self axs_carwidget_chevronImageWithSize:side pointingUp:YES];
    self.pageDownView.frame = CGRectMake(pageX + (pageColumn - side) / 2.0,
                                         height - padding - side, side, side);
    self.pageDownView.image = [self axs_carwidget_chevronImageWithSize:side pointingUp:NO];
    self.pageLabel.frame = CGRectMake(pageX, pageTop + side + 2.0, pageColumn,
                                      CGRectGetMinY(self.pageDownView.frame) - pageTop - side - 4.0);
    BOOL showPage = self.axs_carwidget_pageVisible;
    self.pageUpView.hidden = !showPage;
    self.pageDownView.hidden = !showPage;
    self.pageLabel.hidden = !showPage;
}

- (void)axs_carwidget_layoutWeatherBlock {
    CGFloat blockHeight = CGRectGetHeight(self.weatherBlock.bounds);
    CGFloat blockWidth = CGRectGetWidth(self.weatherBlock.bounds);
    if (blockHeight <= 1.0) return;

    CGFloat rowHeight = blockHeight * 0.28;
    CGFloat symbolSide = MIN(rowHeight * 0.9, blockHeight * 0.26);
    CGFloat y = 0.0;

    // Row 1: optional glyph, temperature, condition text.
    if (self.conditionView.image) {
        self.conditionView.frame = CGRectMake(0, y + (rowHeight - symbolSide) / 2.0, symbolSide, symbolSide);
        self.conditionView.hidden = NO;
        self.temperatureLabel.frame = CGRectMake(symbolSide + 5.0, y, blockWidth * 0.33, rowHeight);
    } else {
        self.conditionView.hidden = YES;
        self.temperatureLabel.frame = CGRectMake(0, y, blockWidth * 0.36, rowHeight);
    }
    CGFloat conditionX = CGRectGetMaxX(self.temperatureLabel.frame) + 6.0;
    self.conditionTextLabel.frame = CGRectMake(conditionX, y,
                                               MAX(blockWidth - conditionX, 1.0), rowHeight);
    y += rowHeight + blockHeight * 0.05;

    self.cityLabel.frame = CGRectMake(0, y, blockWidth, blockHeight * 0.20);
    y += blockHeight * 0.20;

    BOOL showForecast = self.axs_carwidget_forecastVisible && self.forecastLabel.text.length > 0;
    self.forecastLabel.hidden = !showForecast;
    if (showForecast) {
        self.forecastLabel.frame = CGRectMake(0, y, blockWidth, MIN(blockHeight - y, blockHeight * 0.20));
    }
}

- (UIImage *)axs_carwidget_chevronImageWithSize:(CGFloat)side pointingUp:(BOOL)up {
    if (side <= 0.0) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    UIColor *tint = [UIColor colorWithWhite:1.0 alpha:0.35];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextSetStrokeColorWithColor(ctx, tint.CGColor);
        CGContextSetLineWidth(ctx, MAX(side * 0.16, 1.0));
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGFloat inset = side * 0.2;
        CGFloat mid = side * 0.5;
        CGFloat tip = up ? inset : side - inset;
        CGFloat base = up ? side - inset : inset;
        CGContextMoveToPoint(ctx, inset, base);
        CGContextAddLineToPoint(ctx, mid, tip);
        CGContextAddLineToPoint(ctx, side - inset, base);
        CGContextStrokePath(ctx);
    }];
}

#pragma mark - Configuration

- (void)axs_carwidget_observePreferences {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        axs_carwidget_weatherPreferencesDidChange,
        (__bridge CFStringRef)AxsCarWidgetPreferencesChanged, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void axs_carwidget_weatherPreferencesDidChange(CFNotificationCenterRef center, void *observer,
                                                      CFStringRef name, const void *object,
                                                      CFDictionaryRef info) {
    AxsCarWidget *widget = (__bridge AxsCarWidget *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [widget axs_carwidget_applyExternalState];
    });
}

// Re-read the plist and repaint in place: Airaw keeps one instance per widget.
- (void)axs_carwidget_applyExternalState {
    self.axs_carwidget_state = axs_carwidget_readPreferences();
    [self axs_carwidget_applyConfig];
    [self axs_carwidget_applyState];
    [self axs_carwidget_layoutWidget];
    [self axs_carwidget_startTimers];
    [[AxsCarWidgetWeatherSource axs_carwidget_shared] axs_carwidget_refreshIfNeeded];
}

- (void)axs_carwidget_applyConfig {
    NSDictionary *config = self.axs_carwidget_state ?: @{};
    BOOL showPage = AxsCarWidgetBool(config, AxsCarWidgetKeyShowPage, YES);
    if (showPage != self.axs_carwidget_pageVisible) {
        self.axs_carwidget_pageVisible = showPage;
        self.pageUpView.image = nil;
    }
    self.axs_carwidget_forecastVisible = AxsCarWidgetBool(config, AxsCarWidgetKeyShowForecast, YES);
}

- (NSString *)axs_carwidget_configuredCity {
    return AxsCarWidgetString(self.axs_carwidget_state ?: @{}, AxsCarWidgetKeyWeatherCityInput,
                              AxsCarWidgetDefaultWeatherCity);
}

#pragma mark - Rendering

- (void)axs_carwidget_applyState {
    NSDictionary *state = self.axs_carwidget_state ?: @{};
    BOOL showWeather = AxsCarWidgetBool(state, AxsCarWidgetKeyShowWeather, YES);
    BOOL hasWeather = showWeather && AxsCarWidgetHasWeather(state);
    self.weatherBlock.hidden = !hasWeather;
    if (!hasWeather) {
        self.temperatureLabel.text = @"";
        self.conditionTextLabel.text = @"";
        self.cityLabel.text = @"";
        self.forecastLabel.text = @"";
        self.conditionView.image = nil;
    } else {
        [self axs_carwidget_fillWeatherFromState:state];
    }
    [self axs_carwidget_updateAccessibilityLabel];
    [self setNeedsLayout];
}

- (void)axs_carwidget_fillWeatherFromState:(NSDictionary *)state {
    int code = (int)AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherConditionCode, 0);
    double temperature = AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherTemperature, 0);
    NSString *unitKey = AxsCarWidgetString(state, AxsCarWidgetKeyWeatherUnit, @"C");
    axs_carwidget_temperature_unit = [unitKey isEqualToString:@"F"] ? @"F" : @"C";
    NSString *unit = axs_carwidget_temperature_unit;

    self.temperatureLabel.text = [NSString stringWithFormat:@"%.0f°%@", temperature, unit];
    self.conditionTextLabel.text = AxsCarWidgetConditionText(code);

    // Fetched place name wins; while the first fetch runs, show the configured city.
    NSString *city = AxsCarWidgetString(state, AxsCarWidgetKeyWeatherCity, nil);
    self.cityLabel.text = city ?: [self axs_carwidget_configuredCity];

    // SF Symbols only exist from iOS 13; without one the condition is shown as text alone.
    NSString *symbolName = AxsCarWidgetSymbolForConditionCode(code);
    UIImage *symbol = nil;
    if (symbolName.length > 0) {
        if (@available(iOS 13.0, *)) {
            symbol = [UIImage systemImageNamed:symbolName];
        }
    }
    self.conditionView.image = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    self.forecastLabel.text = self.axs_carwidget_forecastVisible
        ? [self axs_carwidget_forecastTextFromState:state] : @"";
}

- (NSString *)axs_carwidget_forecastTextFromState:(NSDictionary *)state {
    double high = AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherHigh, NAN);
    double low = AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherLow, NAN);
    if (isnan(high) && isnan(low)) return @"";
    NSString *unit = axs_carwidget_temperature_unit;
    if (isnan(high)) return [NSString stringWithFormat:@"低 %.0f°%@", low, unit];
    if (isnan(low)) return [NSString stringWithFormat:@"高 %.0f°%@", high, unit];
    return [NSString stringWithFormat:@"高 %.0f°%@  低 %.0f°%@", high, unit, low, unit];
}

- (void)axs_carwidget_updateAccessibilityLabel {
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:self.timeLabel.text ?: @"",
                                                              self.dateLabel.text ?: @"", nil];
    if (!self.weatherBlock.hidden) {
        [parts addObject:self.temperatureLabel.text ?: @""];
        [parts addObject:self.cityLabel.text ?: @""];
    }
    self.accessibilityLabel = [parts componentsJoinedByString:@", "];
}

#pragma mark - Timers

- (void)axs_carwidget_startTimers {
    [self axs_carwidget_stopTimers];
    // The clock ticks every second (monospaced digits, no seconds shown by default).
    self.clockTimer = [NSTimer timerWithTimeInterval:1.0 target:self
                                           selector:@selector(axs_carwidget_refreshClock)
                                           userInfo:nil repeats:YES];
    self.clockTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.clockTimer forMode:NSRunLoopCommonModes];

    // Weather is written by the host; poll the plist at the configured interval.
    NSTimeInterval interval = AxsCarWidgetClampedStateRefresh(self.axs_carwidget_state);
    self.stateTimer = [NSTimer timerWithTimeInterval:interval target:self
                                           selector:@selector(axs_carwidget_pollState)
                                           userInfo:nil repeats:YES];
    self.stateTimer.tolerance = interval * 0.2;
    [[NSRunLoop mainRunLoop] addTimer:self.stateTimer forMode:NSRunLoopCommonModes];
}

- (void)axs_carwidget_stopTimers {
    [self.clockTimer invalidate];
    self.clockTimer = nil;
    [self.stateTimer invalidate];
    self.stateTimer = nil;
}

- (void)axs_carwidget_refreshClock {
    NSDictionary *config = self.axs_carwidget_state ?: @{};
    NSDate *now = [NSDate date];

    NSString *timeFormat = AxsCarWidgetString(config, AxsCarWidgetKeyTimeFormat, @"HH:mm");
    NSString *dateFormat = AxsCarWidgetString(config, AxsCarWidgetKeyDateFormat, @"M月d日 EEE");
    NSString *timeText = [self axs_carwidget_stringFromDate:now format:timeFormat fallback:@"HH:mm"];
    if (![timeText isEqualToString:self.timeLabel.text]) {
        axs_carwidget_log(@"clock %@ (%@), state=%@", timeText, timeFormat,
                          self.axs_carwidget_state ?: @{});
    }
    self.timeLabel.text = timeText;
    self.dateLabel.text = [self axs_carwidget_stringFromDate:now format:dateFormat fallback:@"M月d日 EEE"];

    // Date only changes at midnight, so the rest of the tick is cheap.
    [self axs_carwidget_updateAccessibilityLabel];
}

- (NSString *)axs_carwidget_stringFromDate:(NSDate *)date format:(NSString *)format
                                  fallback:(NSString *)fallback {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale currentLocale];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = format;
    NSString *result = [formatter stringFromDate:date];
    if (result.length > 0) return result;
    formatter.dateFormat = fallback;
    return [formatter stringFromDate:date] ?: @"";
}

- (void)axs_carwidget_pollState {
    // A stale sample is refreshed in the background; the plist notification repaints afterwards.
    [[AxsCarWidgetWeatherSource axs_carwidget_shared] axs_carwidget_refreshIfNeeded];
    NSDictionary *state = axs_carwidget_readPreferences();
    if ([state isEqualToDictionary:self.axs_carwidget_state ?: @{}]) return;
    self.axs_carwidget_state = state;
    [self axs_carwidget_applyConfig];
    [self axs_carwidget_applyState];
    [self axs_carwidget_layoutWidget];
}

#pragma mark - Airaw bridge

// Airaw sets these three properties when it creates and pages the widget.
- (NSString *)identifier {
    return _identifier;
}

- (void)setIdentifier:(NSString *)identifier {
    _identifier = identifier;
    // Airaw sets this once during setup; it is also the natural place to pick up config edits.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *state = axs_carwidget_readPreferences();
        if (![state isEqualToDictionary:self.axs_carwidget_state ?: @{}]) {
            self.axs_carwidget_state = state;
            [self axs_carwidget_applyConfig];
            [self axs_carwidget_applyState];
            [self axs_carwidget_layoutWidget];
        }
    });
}

- (int)pageIndex {
    return _pageIndex;
}

- (void)setPageIndex:(int)pageIndex {
    _pageIndex = pageIndex;
    NSString *text = pageIndex >= 0 ? [NSString stringWithFormat:@"%d", pageIndex + 1] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pageLabel.text = text;
    });
}

- (int)pageType {
    return _pageType;
}

- (void)setPageType:(int)pageType {
    _pageType = pageType;
}

@end
