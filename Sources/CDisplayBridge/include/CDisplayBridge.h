#ifndef CDisplayBridge_h
#define CDisplayBridge_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - DisplayServices (Built-in & Apple Displays)

BOOL LDDisplayServicesIsAvailable(void);
BOOL LDDisplayServicesCanChangeBrightness(CGDirectDisplayID displayID);
BOOL LDDisplayServicesGetBrightness(CGDirectDisplayID displayID, float *outBrightness);
BOOL LDDisplayServicesSetBrightness(CGDirectDisplayID displayID, float brightness);

// MARK: - Apple Silicon DDC/CI (IOAVService over DCPAVServiceProxy)

BOOL LDIOAVServiceIsAvailable(void);

/// Unique physical framebuffer port for each unambiguous online display.
NSDictionary<NSNumber *, NSString *> *LDMatchedDDCPorts(NSArray<NSNumber *> *onlineIDs);
CFTypeRef _Nullable LDCreateAVServiceForPort(NSString *port) CF_RETURNS_RETAINED;

typedef NS_ENUM(NSInteger, LDVCPReadResult) {
    LDVCPReadResultValid,
    LDVCPReadResultTransportError,
    LDVCPReadResultInvalidReply,
    LDVCPReadResultUnsupported
};
LDVCPReadResult LDDDCReadVCP(CFTypeRef avService, uint8_t vcpCode,
                             uint16_t *outCurrentValue, uint16_t *outMaxValue,
                             uint8_t *preferredReadProfile);

/// Writes a DDC/CI VCP code value. Returns YES on success.
BOOL LDDDCWriteVCP(CFTypeRef avService,
                   uint8_t vcpCode,
                   uint16_t newValue);

// MARK: - Display Info from IORegistry (for matching & display names)

/// Returns an array of dictionaries describing external IOMobileFramebufferShim displays
/// (keys: "name", "vendorID", "productID", "serialNumber", "portName").
NSArray<NSDictionary<NSString *, id> *> *LDListAppleSiliconDisplays(void);

// MARK: - CGVirtualDisplay Wrapper

@interface LDVirtualDisplayModeSpec : NSObject
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface LDVirtualDisplayHandle : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) BOOL isActive;

+ (BOOL)isSupported;

- (nullable instancetype)initWithName:(NSString *)name
                             maxWidth:(NSUInteger)maxWidth
                            maxHeight:(NSUInteger)maxHeight
                      sizeInMillimeters:(CGSize)sizeInMM
                                modes:(NSArray<LDVirtualDisplayModeSpec *> *)modes
                                hiDPI:(BOOL)hiDPI
                         serialNumber:(uint32_t)serialNumber
                   terminationHandler:(nullable void (^)(void))terminationHandler;

- (BOOL)applyModes:(NSArray<LDVirtualDisplayModeSpec *> *)modes hiDPI:(BOOL)hiDPI;
- (void)invalidate;
@end

// MARK: - Mirroring Helpers

BOOL LDMirrorDisplay(CGDirectDisplayID targetDisplay, CGDirectDisplayID masterDisplay);
BOOL LDUnmirrorDisplay(CGDirectDisplayID targetDisplay);

NS_ASSUME_NONNULL_END

#endif /* CDisplayBridge_h */
