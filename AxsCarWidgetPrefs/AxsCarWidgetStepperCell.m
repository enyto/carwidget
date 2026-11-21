#import "AxsCarWidgetPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

// Value row with -/+ buttons, matching Airaw's own AirawStepperCell and AirawColorPicker cells.
@interface AxsCarWidgetStepperCell : PSTableCell {
    UILabel *_axs_carwidget_valueLabel;
    UIButton *_axs_carwidget_minusButton;
    UIButton *_axs_carwidget_plusButton;
}
@end

@implementation AxsCarWidgetStepperCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.accessoryView = [self axs_carwidget_stepperView];
        [self axs_carwidget_refreshValue];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.text = [self.specifier name];
}

- (UIView *)axs_carwidget_stepperView {
    UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
    minus.frame = CGRectMake(0, 0, 34, 30);
    [minus setTitle:@"−" forState:UIControlStateNormal];
    [minus addTarget:self action:@selector(axs_carwidget_decrement:) forControlEvents:UIControlEventTouchUpInside];

    _axs_carwidget_valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(36, 0, 56, 30)];
    _axs_carwidget_valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
    _axs_carwidget_valueLabel.textAlignment = NSTextAlignmentCenter;
    _axs_carwidget_valueLabel.textColor = [UIColor labelColor];

    UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
    plus.frame = CGRectMake(94, 0, 34, 30);
    [plus setTitle:@"+" forState:UIControlStateNormal];
    [plus addTarget:self action:@selector(axs_carwidget_increment:) forControlEvents:UIControlEventTouchUpInside];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 128, 30)];
    [container addSubview:minus];
    [container addSubview:_axs_carwidget_valueLabel];
    [container addSubview:plus];
    _axs_carwidget_minusButton = minus;
    _axs_carwidget_plusButton = plus;
    return container;
}

- (double)axs_carwidget_currentValue {
    id value = [self.specifier propertyForKey:@"axs_carwidget_value"];
    if ([value isKindOfClass:[NSNumber class]]) return [value doubleValue];
    id fallback = [self.specifier propertyForKey:@"default"];
    return [fallback isKindOfClass:[NSNumber class]] ? [fallback doubleValue] : 0.0;
}

- (void)axs_carwidget_refreshValue {
    _axs_carwidget_valueLabel.text = [NSString stringWithFormat:@"%.0f", [self axs_carwidget_currentValue]];
}

// The controller supplies the stored value; the cell only edits it.
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self axs_carwidget_refreshValue];
}

- (void)axs_carwidget_setValue:(double)value {
    double minimum = [[self.specifier propertyForKey:@"min"] doubleValue];
    double maximum = [[self.specifier propertyForKey:@"max"] doubleValue];
    if (!isfinite(minimum)) minimum = 0.0;
    if (!isfinite(maximum) || maximum <= minimum) maximum = minimum + 1.0;
    if (!isfinite(value)) value = minimum;
    value = fmax(minimum, fmin(maximum, value));

    [self.specifier setProperty:@(value) forKey:@"axs_carwidget_value"];
    [self axs_carwidget_refreshValue];

    if ([self.control respondsToSelector:@selector(axs_carwidget_setStepperValue:specifier:)]) {
        [self.control performSelector:@selector(axs_carwidget_setStepperValue:specifier:)
                           withObject:@(value)
                           withObject:self.specifier];
    }
}

- (void)axs_carwidget_increment:(id)sender {
    [self axs_carwidget_setValue:[self axs_carwidget_currentValue] + 10.0];
}

- (void)axs_carwidget_decrement:(id)sender {
    [self axs_carwidget_setValue:[self axs_carwidget_currentValue] - 10.0];
}

@end
