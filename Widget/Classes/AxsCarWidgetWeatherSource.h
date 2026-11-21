#pragma once

#import <Foundation/Foundation.h>

// Fetches the current weather (Open-Meteo, no API key) and stores the sample in the canonical
// Airaw preference plist. One request at a time; results are shared by every widget instance.
@interface AxsCarWidgetWeatherSource : NSObject
+ (instancetype)axs_carwidget_shared;
// Fetches when the stored sample is missing or older than AxsCarWidgetWeatherStaleInterval.
- (void)axs_carwidget_refreshIfNeeded;
- (void)axs_carwidget_refreshNow;
@end
