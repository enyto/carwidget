#pragma once

#import <Foundation/Foundation.h>

// Keys read from the panel (Config.plist).
static NSString * const AxsCarWidgetKeyTimeFormat = @"timeFormat";              // NSDateFormatter format
static NSString * const AxsCarWidgetKeyDateFormat = @"dateFormat";              // NSDateFormatter format
static NSString * const AxsCarWidgetKeyShowWeather = @"showWeather";            // bool
static NSString * const AxsCarWidgetKeyShowForecast = @"showForecast";          // bool
static NSString * const AxsCarWidgetKeyShowPage = @"showPage";                  // bool
static NSString * const AxsCarWidgetKeyWeatherCityInput = @"weatherCityInput";  // city used for lookups
static NSString * const AxsCarWidgetKeyWeatherAutoLocation = @"weatherAutoLocation"; // bool
static NSString * const AxsCarWidgetKeyStateRefresh = @"stateRefreshInterval";  // seconds

// Weather sample written by the widget after a successful fetch.
static NSString * const AxsCarWidgetKeyWeatherCity = @"weatherCity";
static NSString * const AxsCarWidgetKeyWeatherTemperature = @"weatherTemperature";
static NSString * const AxsCarWidgetKeyWeatherUnit = @"weatherUnit";            // "C" / "F"
static NSString * const AxsCarWidgetKeyWeatherConditionCode = @"weatherConditionCode";
static NSString * const AxsCarWidgetKeyWeatherHigh = @"weatherHigh";
static NSString * const AxsCarWidgetKeyWeatherLow = @"weatherLow";
static NSString * const AxsCarWidgetKeyWeatherFetchedAt = @"weatherFetchedAt";  // unix seconds

static NSString * const AxsCarWidgetDefaultTimeFormat = @"HH:mm";
static NSString * const AxsCarWidgetDefaultDateFormat = @"M月d日 EEE";
static NSString * const AxsCarWidgetDefaultWeatherCity = @"上海";

// Present weather is at most 20 minutes old; polling may run faster than that.
static const NSTimeInterval AxsCarWidgetWeatherStaleInterval = 20 * 60;

static inline BOOL AxsCarWidgetBool(NSDictionary *config, NSString *key, BOOL fallback) {
    id value = config[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static inline NSString *AxsCarWidgetString(NSDictionary *config, NSString *key, NSString *fallback) {
    id value = config[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return fallback;
}

static inline double AxsCarWidgetDouble(NSDictionary *config, NSString *key, double fallback) {
    id value = config[key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

// Weather polling is clamped so a bad value in the plist cannot spin the RunLoop.
static inline double AxsCarWidgetClampedStateRefresh(NSDictionary *config) {
    double seconds = AxsCarWidgetDouble(config, AxsCarWidgetKeyStateRefresh, 60.0);
    if (seconds < 10.0) seconds = 10.0;
    if (seconds > 600.0) seconds = 600.0;
    return seconds;
}

static inline BOOL AxsCarWidgetHasWeather(NSDictionary *config) {
    return AxsCarWidgetBool(config, AxsCarWidgetKeyShowWeather, YES) &&
           [config[AxsCarWidgetKeyWeatherTemperature] isKindOfClass:[NSNumber class]];
}

static inline BOOL AxsCarWidgetWeatherNeedsRefresh(NSDictionary *config) {
    double fetchedAt = AxsCarWidgetDouble(config, AxsCarWidgetKeyWeatherFetchedAt, 0);
    return [[NSDate date] timeIntervalSince1970] - fetchedAt > AxsCarWidgetWeatherStaleInterval;
}

// Weather condition codes follow Apple's Weather framework.
// Returns an SF Symbol name, or nil when the running symbol set does not cover the code.
static inline NSString *AxsCarWidgetSymbolForConditionCode(int code) {
    switch (code) {
        case 0: case 1: case 2: case 3: return @"tornado";
        case 4: case 5: case 6: case 7: case 8: case 9: case 10:
        case 11: case 12: case 37: case 38: case 39:
            return @"cloud.bolt.rain.fill";
        case 13: case 14: case 15: case 16: case 17: case 41: case 42: case 43:
            return @"cloud.snow.fill";
        case 18: case 19: case 20: case 21: case 22: case 23: return @"cloud.fog.fill";
        case 24: case 25: case 26: case 27: case 29: return @"wind";
        case 28: case 30: return @"cloud.moon.fill";
        case 31: case 33: return @"moon.stars.fill";
        case 32: case 34: return @"sun.max.fill";
        case 36: return @"thermometer.sun.fill";
        case 40: return @"cloud.heavyrain.fill";
        case 44: case 45: case 46: case 47: return @"cloud.fill";
        default: break;
    }
    return nil;
}

// Text for codes without an SF Symbol (e.g. "Hot", "Heavy Snow").
static inline NSString *AxsCarWidgetConditionText(int code) {
    if (code <= 3) return @"Tornado";
    if (code <= 12) return @"Thunderstorm";
    if (code <= 17) return @"Snow";
    if (code == 19 || code == 20 || code == 21) return @"Fog";
    if (code == 22) return @"Windy";
    if (code <= 30) return @"Snow";
    if (code <= 34) return @"Clear";
    if (code == 36) return @"Hot";
    if (code <= 39) return @"Scattered Storms";
    if (code <= 43) return @"Heavy Snow";
    return @"Partly Cloudy";
}

// Open-Meteo reports WMO weather codes; Apple's Weather framework uses its own numbering.
static inline int AxsCarWidgetConditionCodeFromWMO(int wmo) {
    switch (wmo) {
        case 0: return 32;              // clear
        case 1: return 34;              // mainly clear
        case 2: return 30;              // partly cloudy
        case 3: return 28;              // overcast
        case 45: case 48: return 20;    // fog / freezing fog
        case 51: case 53: case 55: case 56: case 57: return 9;   // drizzle
        case 61: case 63: case 66: case 67: return 12;           // rain
        case 65: return 40;             // heavy rain
        case 71: case 73: return 14;    // snow
        case 75: case 77: return 16;    // heavy snow
        case 80: case 81: case 82: return 39;  // rain showers
        case 85: case 86: return 16;    // snow showers
        case 95: return 4;              // thunderstorm
        case 96: case 99: return 6;     // thunderstorm with hail
        default: return 30;
    }
}
