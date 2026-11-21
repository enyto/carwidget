#import "AxsCarWidgetWeatherSource.h"
#import "AxsCarWidgetConfig.h"
#import "AxsCarWidgetPreferences.h"

#import <CoreLocation/CoreLocation.h>

#include <math.h>

// Open-Meteo needs no key. City names are resolved locally with CLGeocoder, so a request only
// carries coordinates; the city name itself never leaves the device.
static NSString * const AxsCarWidgetWeatherEndpoint = @"https://api.open-meteo.com/v1/forecast";

@interface AxsCarWidgetWeatherSource () <CLLocationManagerDelegate>
@property (nonatomic, assign) BOOL axs_carwidget_fetching;
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, copy) void (^axs_carwidget_locationCompletion)(CLLocation *location, BOOL denied);
@end

@implementation AxsCarWidgetWeatherSource

+ (instancetype)axs_carwidget_shared {
    static AxsCarWidgetWeatherSource *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)axs_carwidget_refreshIfNeeded {
    NSDictionary *config = axs_carwidget_readPreferences();
    if (!AxsCarWidgetBool(config, AxsCarWidgetKeyShowWeather, YES)) return;
    if (!AxsCarWidgetWeatherNeedsRefresh(config)) return;
    [self axs_carwidget_fetchForConfig:config];
}

- (void)axs_carwidget_refreshNow {
    [self axs_carwidget_fetchForConfig:axs_carwidget_readPreferences()];
}

- (void)axs_carwidget_fetchForConfig:(NSDictionary *)config {
    if (self.axs_carwidget_fetching) return;
    if (!AxsCarWidgetBool(config, AxsCarWidgetKeyShowWeather, YES)) return;
    self.axs_carwidget_fetching = YES;

    if (AxsCarWidgetBool(config, AxsCarWidgetKeyWeatherAutoLocation, YES)) {
        __weak typeof(self) weakSelf = self;
        [self axs_carwidget_requestLocation:^(CLLocation *location, BOOL denied) {
            if (location) {
                [weakSelf axs_carwidget_fetchLatitude:location.coordinate.latitude
                                            longitude:location.coordinate.longitude];
            } else {
                // Permission refused or timed out: fall back to the configured city.
                [weakSelf axs_carwidget_fetchCity:AxsCarWidgetString(config,
                        AxsCarWidgetKeyWeatherCityInput, AxsCarWidgetDefaultWeatherCity)];
            }
        }];
    } else {
        [self axs_carwidget_fetchCity:AxsCarWidgetString(config, AxsCarWidgetKeyWeatherCityInput,
                                                        AxsCarWidgetDefaultWeatherCity)];
    }
}

#pragma mark - Location

- (void)axs_carwidget_requestLocation:(void (^)(CLLocation *location, BOOL denied))completion {
    self.axs_carwidget_locationCompletion = [completion copy];
    if (!self.locationManager) {
        self.locationManager = [[CLLocationManager alloc] init];
        self.locationManager.delegate = self;
        self.locationManager.desiredAccuracy = kCLLocationAccuracyKilometer;
    }
    CLAuthorizationStatus status = self.locationManager.authorizationStatus;
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        [self axs_carwidget_finishLocation:nil denied:YES];
        return;
    }
    if (status == kCLAuthorizationStatusNotDetermined) {
        [self.locationManager requestWhenInUseAuthorization];
    }
    [self.locationManager requestLocation];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // requestLocation can stall without a fix indoors; never leave the fetch hanging.
        [weakSelf axs_carwidget_finishLocation:nil denied:YES];
    });
}

// The first call wins: a later timer or delegate callback must not start a second fetch.
- (void)axs_carwidget_finishLocation:(CLLocation *)location denied:(BOOL)denied {
    void (^completion)(CLLocation *, BOOL) = self.axs_carwidget_locationCompletion;
    if (!completion) return;
    self.axs_carwidget_locationCompletion = nil;
    completion(location, denied);
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    [self axs_carwidget_finishLocation:locations.lastObject denied:NO];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    BOOL denied = error.code == kCLErrorDenied;
    [self axs_carwidget_finishLocation:nil denied:denied];
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse ||
        manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways) {
        [manager requestLocation];
    } else if (manager.authorizationStatus == kCLAuthorizationStatusDenied ||
               manager.authorizationStatus == kCLAuthorizationStatusRestricted) {
        [self axs_carwidget_finishLocation:nil denied:YES];
    }
}

#pragma mark - Lookup

- (void)axs_carwidget_fetchCity:(NSString *)city {
    CLGeocoder *geocoder = [[CLGeocoder alloc] init];
    __weak typeof(self) weakSelf = self;
    [geocoder geocodeAddressString:city completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        CLLocation *location = placemarks.firstObject.location;
        if (!location) {
            [weakSelf axs_carwidget_finishWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain
                code:NSURLErrorCannotFindHost userInfo:@{NSLocalizedDescriptionKey: @"Unknown city"}]];
            return;
        }
        [weakSelf axs_carwidget_fetchLatitude:location.coordinate.latitude
                                    longitude:location.coordinate.longitude];
    }];
}

- (void)axs_carwidget_fetchLatitude:(double)latitude longitude:(double)longitude {
    NSURLComponents *components = [NSURLComponents componentsWithString:AxsCarWidgetWeatherEndpoint];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"latitude" value:[NSString stringWithFormat:@"%.4f", latitude]],
        [NSURLQueryItem queryItemWithName:@"longitude" value:[NSString stringWithFormat:@"%.4f", longitude]],
        [NSURLQueryItem queryItemWithName:@"current" value:@"temperature_2m,weather_code"],
        [NSURLQueryItem queryItemWithName:@"daily" value:@"temperature_2m_max,temperature_2m_min"],
        [NSURLQueryItem queryItemWithName:@"forecast_days" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"timezone" value:@"auto"],
    ];
    NSURL *url = components.URL;
    if (!url) {
        [self axs_carwidget_finishWithError:nil];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:12.0];
    request.HTTPMethod = @"GET";
    NSURLSession *session = [NSURLSession sessionWithConfiguration:
                             [NSURLSessionConfiguration ephemeralSessionConfiguration]];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if (!error && status == 200 && [json isKindOfClass:[NSDictionary class]]) {
                [weakSelf axs_carwidget_applyPayload:json latitude:latitude longitude:longitude];
            } else {
                [weakSelf axs_carwidget_finishWithError:error];
            }
        }];
    [task resume];
}

#pragma mark - Store

- (void)axs_carwidget_applyPayload:(NSDictionary *)json latitude:(double)latitude longitude:(double)longitude {
    NSDictionary *current = json[@"current"];
    if (![current isKindOfClass:[NSDictionary class]]) {
        [self axs_carwidget_finishWithError:nil];
        return;
    }
    double temperature = [current[@"temperature_2m"] doubleValue];
    int wmo = [current[@"weather_code"] intValue];

    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    changes[AxsCarWidgetKeyWeatherTemperature] = @((double)lround(temperature));
    changes[AxsCarWidgetKeyWeatherConditionCode] = @(AxsCarWidgetConditionCodeFromWMO(wmo));
    // Open-Meteo reports its unit as "°C" / "°F"; anything but °F is shown as Celsius.
    NSString *units = json[@"current_units"][@"temperature_2m"];
    BOOL fahrenheit = [units isKindOfClass:[NSString class]] && [units containsString:@"F"];
    changes[AxsCarWidgetKeyWeatherUnit] = fahrenheit ? @"F" : @"C";
    changes[AxsCarWidgetKeyWeatherFetchedAt] = @([[NSDate date] timeIntervalSince1970]);

    NSDictionary *daily = json[@"daily"];
    id high = [daily[@"temperature_2m_max"] firstObject];
    id low = [daily[@"temperature_2m_min"] firstObject];
    if ([high isKindOfClass:[NSNumber class]]) changes[AxsCarWidgetKeyWeatherHigh] = @((double)lround([high doubleValue]));
    if ([low isKindOfClass:[NSNumber class]]) changes[AxsCarWidgetKeyWeatherLow] = @((double)lround([low doubleValue]));

    // City label: reverse geocoding happens on the phone, so time zones and place names stay local.
    CLLocation *location = [[CLLocation alloc] initWithLatitude:latitude longitude:longitude];
    [[[CLGeocoder alloc] init] reverseGeocodeLocation:location
      preferredLocale:[NSLocale currentLocale]
      completionHandler:^(NSArray<CLPlacemark *> *placemarks, NSError *error) {
        NSString *name = placemarks.firstObject.locality ?: placemarks.firstObject.administrativeArea;
        if (name.length > 0) changes[AxsCarWidgetKeyWeatherCity] = name;
        [self axs_carwidget_finishWithChanges:changes];
    }];
}

- (void)axs_carwidget_finishWithChanges:(NSDictionary *)changes {
    self.axs_carwidget_fetching = NO;
    axs_carwidget_updatePreferences(changes, NULL);
}

- (void)axs_carwidget_finishWithError:(NSError *)error {
    self.axs_carwidget_fetching = NO;
    if (error) {
        NSLog(@"[AxsCarWidget] weather refresh failed: %@", error.localizedDescription);
    }
}

@end
