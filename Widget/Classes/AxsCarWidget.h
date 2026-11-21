#pragma once

#import <UIKit/UIKit.h>

// Airaw loads the class named by NSPrincipalClass in the bundle Info.plist.
// The three protocol properties are required: Airaw drives paging and identification through them.
@protocol AxsCarWidgetAirawControlProtocol
@required
@property (nonatomic, retain) NSString *identifier;
@property (assign, nonatomic) int pageIndex;
@property (assign, nonatomic) int pageType;
@end

@interface AxsCarWidget : UIView <AxsCarWidgetAirawControlProtocol>
@property (nonatomic, retain) NSString *identifier;
@property (assign, nonatomic) int pageIndex;
@property (assign, nonatomic) int pageType;
@end
