#import "AxsCarWidget.h"
#import "AxsCarWidgetConfig.h"
#import "AxsCarWidgetPreferences.h"
#import "AxsCarWidgetWeatherSource.h"

#import <objc/runtime.h>
#include <math.h>

// The Weather framework picks the unit from the device setting; the widget follows it.
static NSString *axs_carwidget_temperature_unit = @"C";

@interface AxsCarWidget ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UIStackView *weatherStack;
@property (nonatomic, strong) UIImageView *conditionView;
@property (nonatomic, strong) UILabel *conditionTextLabel;
@property (nonatomic, strong) UILabel *temperatureLabel;
@property (nonatomic, strong) UILabel *cityLabel;
@property (nonatomic, strong) UIView *pageRow;
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
    NSLog(@"[AxsCarWidget] mounted %@ bounds=%@ config=%@", self.superview ? @"yes" : @"no",
          NSStringFromCGRect(self.bounds), axs_carwidget_preferencesPath());
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
    [self axs_carwidget_layoutWidget];
    [self axs_carwidget_refreshClock];
}

#pragma mark - View construction

- (void)axs_carwidget_buildView {
    self.backgroundColor = [UIColor clearColor];
    self.clipsToBounds = YES;

    // Card: rounded, blurred material so the CarPlay wallpaper stays visible behind it.
    self.cardView = [[UIView alloc] initWithFrame:self.bounds];
    self.cardView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.cardView.layer.cornerRadius = 16.0;
    if (@available(iOS 13.0, *)) {
        self.cardView.layer.cornerCurve = kCACornerCurveContinuous;
    }
    self.cardView.layer.masksToBounds = YES;
    [self addSubview:self.cardView];

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.cardView addSubview:blurView];

    // Time and date.
    self.timeLabel = [self axs_carwidget_labelWithWeight:UIFontWeightBold color:[UIColor labelColor]];
    self.dateLabel = [self axs_carwidget_labelWithWeight:UIFontWeightMedium
                                                   color:[UIColor secondaryLabelColor]];
    [self.cardView addSubview:self.timeLabel];
    [self.cardView addSubview:self.dateLabel];

    // Weather block.
    self.conditionView = [[UIImageView alloc] init];
    self.conditionView.contentMode = UIViewContentModeScaleAspectFit;
    self.conditionView.tintColor = [UIColor labelColor];
    self.conditionView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.conditionView setContentHuggingPriority:UILayoutPriorityRequired
                                   forAxis:UILayoutConstraintAxisHorizontal];

    self.conditionTextLabel = [self axs_carwidget_labelWithWeight:UIFontWeightSemibold
                                                            color:[UIColor labelColor]];
    self.temperatureLabel = [self axs_carwidget_labelWithWeight:UIFontWeightSemibold
                                                          color:[UIColor labelColor]];
    self.cityLabel = [self axs_carwidget_labelWithWeight:UIFontWeightRegular
                                                   color:[UIColor secondaryLabelColor]];

    UIStackView *cityRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.cityLabel]];
    cityRow.axis = UILayoutConstraintAxisHorizontal;

    self.weatherStack = [[UIStackView alloc] initWithArrangedSubviews:@[cityRow]];
    self.weatherStack.axis = UILayoutConstraintAxisVertical;
    self.weatherStack.alignment = UIStackViewAlignmentLeading;
    self.weatherStack.spacing = 6.0;
    self.weatherStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:self.weatherStack];

    // Paging hint: Airaw moves between pages with left/right gestures.
    self.pageUpView = [[UIImageView alloc] init];
    self.pageUpView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pageUpView setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisVertical];
    self.pageDownView = [[UIImageView alloc] init];
    self.pageDownView.translatesAutoresizingMaskIntoConstraints = NO;
    self.pageLabel = [self axs_carwidget_labelWithWeight:UIFontWeightMedium
                                                   color:[UIColor tertiaryLabelColor]];
    self.pageLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightMedium];
    self.pageLabel.textAlignment = NSTextAlignmentCenter;
    // Narrow vertical strip: chevron, page number, chevron.
    UIStackView *pageStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.pageUpView,
                                                                             self.pageLabel,
                                                                             self.pageDownView]];
    pageStack.axis = UILayoutConstraintAxisVertical;
    pageStack.spacing = 1.0;
    pageStack.alignment = UIStackViewAlignmentCenter;
    pageStack.distribution = UIStackViewDistributionFillEqually;
    self.pageRow = pageStack;
    self.pageRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardView addSubview:self.pageRow];
}

- (UILabel *)axs_carwidget_labelWithWeight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:weight];
    label.textColor = color;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    label.numberOfLines = 1;
    label.text = @"--";
    return label;
}

#pragma mark - Layout

// Everything is proportional to the card height so Airaw can resize the widget freely.
- (void)axs_carwidget_layoutWidget {
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat width = CGRectGetWidth(self.bounds);
    if (height <= 1.0 || width <= 1.0) return;

    CGFloat padding = height * 0.09;
    // Page column: chevrons sit close to the edge, the number needs a little room.
    CGFloat pageColumn = self.axs_carwidget_pageVisible ? MAX(height * 0.10, 18.0) : 0.0;
    CGFloat reserve = self.axs_carwidget_pageVisible ? pageColumn + padding * 0.4 : 0.0;
    CGFloat contentWidth = MAX(width - padding * 2.0 - reserve, 1.0);

    self.cardView.layer.cornerRadius = height * 0.10;
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:height * 0.24 weight:UIFontWeightBold];
    self.dateLabel.font = [UIFont monospacedDigitSystemFontOfSize:height * 0.11 weight:UIFontWeightMedium];
    self.cityLabel.font = [UIFont systemFontOfSize:height * 0.095 weight:UIFontWeightRegular];
    self.temperatureLabel.font = [UIFont monospacedDigitSystemFontOfSize:height * 0.12
                                                                  weight:UIFontWeightSemibold];
    self.conditionTextLabel.font = [UIFont systemFontOfSize:height * 0.10
                                                      weight:UIFontWeightSemibold];
    self.pageLabel.font = [UIFont monospacedDigitSystemFontOfSize:MAX(height * 0.065, 8.0)
                                                           weight:UIFontWeightMedium];

    BOOL hasWeather = !self.weatherStack.hidden;
    // Vertical rhythm for a 200x200 square: clock, date, then the weather block pinned low.
    CGFloat timeHeight = height * 0.24;
    CGFloat dateHeight = height * 0.11;
    CGFloat weatherHeight = hasWeather ? height * 0.42 : 0.0;

    self.timeLabel.frame = CGRectMake(padding, padding, contentWidth, timeHeight);
    self.dateLabel.frame = CGRectMake(padding, CGRectGetMaxY(self.timeLabel.frame), contentWidth,
                                      dateHeight);
    if (hasWeather) {
        self.weatherStack.frame = CGRectMake(padding, height - padding - weatherHeight, contentWidth,
                                             weatherHeight);
    } else {
        // No weather data: move the clock block to the middle so the card does not look empty.
        CGFloat blockTop = (height - timeHeight - dateHeight) / 2.0;
        self.timeLabel.frame = CGRectMake(padding, blockTop, contentWidth, timeHeight);
        self.dateLabel.frame = CGRectMake(padding, blockTop + timeHeight, contentWidth, dateHeight);
        self.weatherStack.frame = CGRectZero;
    }

    CGFloat pageX = CGRectGetMaxX(self.cardView.bounds) - padding * 0.6 - pageColumn;
    self.pageRow.frame = CGRectMake(pageX, padding, pageColumn, height - padding * 2.0);
    self.pageRow.hidden = !self.axs_carwidget_pageVisible;
    [self axs_carwidget_sizePageChevrons];
}

- (void)axs_carwidget_sizePageChevrons {
    CGFloat side = MAX(CGRectGetHeight(self.pageRow.bounds) * 0.16, 6.0);
    if (CGSizeEqualToSize(self.pageUpView.image.size, CGSizeMake(side, side)) &&
        self.pageUpView.image != nil) {
        return;
    }
    self.pageUpView.image = [self axs_carwidget_chevronImageWithSize:side pointingUp:YES];
    self.pageDownView.image = [self axs_carwidget_chevronImageWithSize:side pointingUp:NO];
}

- (UIImage *)axs_carwidget_chevronImageWithSize:(CGFloat)side pointingUp:(BOOL)up {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef ctx = context.CGContext;
        CGContextSetStrokeColorWithColor(ctx, [UIColor tertiaryLabelColor].CGColor);
        CGContextSetLineWidth(ctx, MAX(side * 0.16, 1.0));
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGFloat inset = side * 0.2;
        CGFloat mid = side * 0.5;
        // Pages are reached with vertical swipes, so the hint is drawn as an up/down chevron.
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

    for (UIView *view in [self.weatherStack.arrangedSubviews copy]) {
        [self.weatherStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (hasWeather) {
        self.weatherStack.hidden = NO;
        [self axs_carwidget_buildWeatherRowsFromState:state];
    } else {
        // Without weather the clock alone fills the card; the stack collapses in -layoutWidget.
        self.weatherStack.hidden = YES;
    }
    [self axs_carwidget_updateAccessibilityLabel];
    [self setNeedsLayout];
}

- (void)axs_carwidget_buildWeatherRowsFromState:(NSDictionary *)state {
    int code = (int)AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherConditionCode, 0);
    double temperature = AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherTemperature, 0);
    NSString *unitKey = AxsCarWidgetString(state, AxsCarWidgetKeyWeatherUnit, @"C");
    axs_carwidget_temperature_unit = [unitKey isEqualToString:@"F"] ? @"F" : @"C";
    NSString *unit = axs_carwidget_temperature_unit;

    self.temperatureLabel.text = [NSString stringWithFormat:@"%.0f°%@", temperature, unit];
    self.conditionTextLabel.text = AxsCarWidgetConditionText(code);

    // Fetched place name wins; otherwise show the configured city while the first fetch runs.
    NSString *city = AxsCarWidgetString(state, AxsCarWidgetKeyWeatherCity, nil);
    self.cityLabel.text = city ?: [self axs_carwidget_configuredCity];

    // Condition glyph when the running symbol set knows the code, text otherwise.
    NSString *symbolName = AxsCarWidgetSymbolForConditionCode(code);
    UIImage *symbol = nil;
    if (symbolName.length > 0) {
        if (@available(iOS 13.0, *)) {
            symbol = [UIImage systemImageNamed:symbolName];
        }
    }
    symbol = [symbol imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:
        symbol ? @[self.conditionView, self.temperatureLabel, self.conditionTextLabel]
               : @[self.temperatureLabel, self.conditionTextLabel]];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 5.0;
    // Narrow cards: shrink the glyph and drop the text rather than truncating "Partly Cl…".
    [self.temperatureLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                          forAxis:UILayoutConstraintAxisHorizontal];
    [self.conditionTextLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                             forAxis:UILayoutConstraintAxisHorizontal];

    if (symbol) {
        self.conditionView.image = symbol;
        // Square glyph, capped so the row never grows past the bottom block.
        CGFloat cap = MAX(CGRectGetHeight(self.weatherStack.bounds) * 0.32, 10.0);
        self.conditionView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.conditionView.widthAnchor constraintEqualToAnchor:self.conditionView.heightAnchor].active = YES;
        NSLayoutConstraint *capConstraint =
            [self.conditionView.heightAnchor constraintLessThanOrEqualToConstant:cap];
        capConstraint.priority = UILayoutPriorityRequired;
        capConstraint.active = YES;
    } else {
        self.conditionView.image = nil;
    }

    [self.weatherStack addArrangedSubview:line];
    [self.weatherStack addArrangedSubview:self.cityLabel];

    if (self.axs_carwidget_forecastVisible) {
        UIStackView *forecast = [self axs_carwidget_forecastViewFromState:state];
        if (forecast) [self.weatherStack addArrangedSubview:forecast];
    }
}

- (UIStackView *)axs_carwidget_forecastViewFromState:(NSDictionary *)state {
    double high = AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherHigh, NAN);
    double low = AxsCarWidgetDouble(state, AxsCarWidgetKeyWeatherLow, NAN);
    if (isnan(high) && isnan(low)) return nil;

    NSString *unit = axs_carwidget_temperature_unit;
    NSMutableArray *values = [NSMutableArray array];
    if (!isnan(high)) [values addObject:[NSString stringWithFormat:@"高 %.0f°%@", high, unit]];
    if (!isnan(low)) [values addObject:[NSString stringWithFormat:@"低 %.0f°%@", low, unit]];

    NSMutableArray *labels = [NSMutableArray array];
    for (NSUInteger index = 0; index < values.count; index++) {
        UILabel *label = [self axs_carwidget_labelWithWeight:UIFontWeightMedium
                                                       color:[UIColor tertiaryLabelColor]];
        label.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        label.text = values[index];
        [labels addObject:label];
    }
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:labels];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6.0;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (void)axs_carwidget_updateAccessibilityLabel {
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:self.timeLabel.text ?: @"",
                                                              self.dateLabel.text ?: @"", nil];
    if (!self.weatherStack.hidden) {
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
    self.timeLabel.text = [self axs_carwidget_stringFromDate:now format:timeFormat fallback:@"HH:mm"];
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
