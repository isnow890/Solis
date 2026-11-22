#import "CDisplayBridge.h"
#import <dlfcn.h>
#import <unistd.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Private Function Typedefs

typedef int (*DSGetBrightnessFn)(CGDirectDisplayID, float *);
typedef int (*DSSetBrightnessFn)(CGDirectDisplayID, float);
typedef BOOL (*DSCanChangeBrightnessFn)(CGDirectDisplayID);

typedef CFTypeRef (*IOAVServiceCreateWithServiceFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVServiceReadI2CFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef IOReturn (*IOAVServiceWriteI2CFn)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

// MARK: - Dynamic Symbol Loading (DisplayServices)

static DSGetBrightnessFn gDSGetBrightness = NULL;
static DSSetBrightnessFn gDSSetBrightness = NULL;
static DSCanChangeBrightnessFn gDSCanChangeBrightness = NULL;

static void LDEnsureDisplayServicesLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        if (!handle) {
            handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices", RTLD_LAZY);
        }
        if (handle) {
            gDSGetBrightness = (DSGetBrightnessFn)dlsym(handle, "DisplayServicesGetBrightness");
            gDSSetBrightness = (DSSetBrightnessFn)dlsym(handle, "DisplayServicesSetBrightness");
            gDSCanChangeBrightness = (DSCanChangeBrightnessFn)dlsym(handle, "DisplayServicesCanChangeBrightness");
        }
    });
}

BOOL LDDisplayServicesIsAvailable(void) {
    LDEnsureDisplayServicesLoaded();
    return (gDSGetBrightness != NULL && gDSSetBrightness != NULL);
}

BOOL LDDisplayServicesCanChangeBrightness(CGDirectDisplayID displayID) {
    if (!LDDisplayServicesIsAvailable()) return NO;
    if (gDSCanChangeBrightness != NULL) {
        return gDSCanChangeBrightness(displayID);
    }
    if (gDSGetBrightness != NULL) {
        float val = 0.0f;
        return gDSGetBrightness(displayID, &val) == 0;
    }
    return NO;
}

BOOL LDDisplayServicesGetBrightness(CGDirectDisplayID displayID, float *outBrightness) {
    LDEnsureDisplayServicesLoaded();
    if (!gDSGetBrightness || !outBrightness) return NO;
    float value = 0;
    if (gDSGetBrightness(displayID, &value) != 0 || !isfinite(value) || value < 0 || value > 1) return NO;
    *outBrightness = value;
    return YES;
}

BOOL LDDisplayServicesSetBrightness(CGDirectDisplayID displayID, float brightness) {
    LDEnsureDisplayServicesLoaded();
    if (!gDSSetBrightness) return NO;
    float clamped = fminf(fmaxf(brightness, 0.0f), 1.0f);
    return gDSSetBrightness(displayID, clamped) == 0;
}

// MARK: - Dynamic Symbol Loading (IOAVService)

static IOAVServiceCreateWithServiceFn gIOAVCreateWithService = NULL;
static IOAVServiceReadI2CFn gIOAVReadI2C = NULL;
static IOAVServiceWriteI2CFn gIOAVWriteI2C = NULL;

static void LDEnsureIOAVServiceLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handles[3] = {
            RTLD_DEFAULT,
            dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
            dlopen("/System/Library/PrivateFrameworks/IOAVFamily.framework/IOAVFamily", RTLD_LAZY)
        };
        for (int i = 0; i < 3; i++) {
            void *h = handles[i];
            if (!h) continue;
            if (!gIOAVCreateWithService) gIOAVCreateWithService = (IOAVServiceCreateWithServiceFn)dlsym(h, "IOAVServiceCreateWithService");
            if (!gIOAVReadI2C) gIOAVReadI2C = (IOAVServiceReadI2CFn)dlsym(h, "IOAVServiceReadI2C");
            if (!gIOAVWriteI2C) gIOAVWriteI2C = (IOAVServiceWriteI2CFn)dlsym(h, "IOAVServiceWriteI2C");
        }
    });
}

BOOL LDIOAVServiceIsAvailable(void) {
    LDEnsureIOAVServiceLoaded();
    return (gIOAVCreateWithService != NULL && gIOAVReadI2C != NULL && gIOAVWriteI2C != NULL);
}

// MARK: - IORegistry Matching for Apple Silicon Displays

static NSString * _Nullable LDPortPrefixFromNameMatched(NSString *nameMatched) {
    if (!nameMatched.length) return nil;
    NSRange comma = [nameMatched rangeOfString:@","];
    if (comma.location != NSNotFound) {
        return [nameMatched substringToIndex:comma.location];
    }
    return nameMatched;
}

NSArray<NSDictionary<NSString *, id> *> *LDListAppleSiliconDisplays(void) {
    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];

    CFMutableDictionaryRef matching = IOServiceMatching("IOMobileFramebufferShim");
    if (!matching) return results;

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) return results;

    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef propsCF = NULL;
        if (IORegistryEntryCreateCFProperties(service, &propsCF, kCFAllocatorDefault, kNilOptions) == KERN_SUCCESS && propsCF) {
            NSDictionary *props = (__bridge_transfer NSDictionary *)propsCF;
            NSString *nameMatched = props[@"IONameMatched"];
            NSDictionary *displayAttrs = props[@"DisplayAttributes"];
            NSDictionary *productAttrs = [displayAttrs isKindOfClass:[NSDictionary class]] ? displayAttrs[@"ProductAttributes"] : nil;

            if ([productAttrs isKindOfClass:[NSDictionary class]]) {
                NSString *productName = productAttrs[@"ProductName"] ?: @"";
                NSNumber *legacyVendor = productAttrs[@"LegacyManufacturerID"] ?: @(0);
                NSNumber *productID = productAttrs[@"ProductID"] ?: @(0);
                NSNumber *serialNumber = productAttrs[@"SerialNumber"] ?: @(0);
                NSString *portPrefix = LDPortPrefixFromNameMatched(nameMatched ?: @"") ?: @"";

                io_string_t path = {0};
                IORegistryEntryGetPath(service, kIOServicePlane, path);
                [results addObject:@{
                    @"path": @(path),
                    @"name": productName,
                    @"vendorID": legacyVendor,
                    @"productID": productID,
                    @"serialNumber": serialNumber,
                    @"portName": portPrefix
                }];
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return results;
}

static NSDictionary * _Nullable LDDisplayInfo(CGDirectDisplayID displayID) {
    typedef CFDictionaryRef (*CopyInfo)(CGDirectDisplayID);
    static CopyInfo copyInfo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (h) copyInfo = (CopyInfo)dlsym(h, "CoreDisplay_DisplayCreateInfoDictionary");
    });
    return copyInfo ? CFBridgingRelease(copyInfo(displayID)) : nil;
}

NSDictionary<NSNumber *, NSString *> *LDMatchedDDCPorts(NSArray<NSNumber *> *onlineIDs) {
    NSArray *rows = LDListAppleSiliconDisplays();
    NSMutableDictionary *candidates = [NSMutableDictionary dictionary];
    NSCountedSet *claims = [NSCountedSet set];
    for (NSNumber *number in onlineIDs) {
        CGDirectDisplayID display = number.unsignedIntValue;
        if (CGDisplayIsBuiltin(display)) continue;
        NSDictionary *info = LDDisplayInfo(display);
        NSString *path = info[@"IODisplayLocation"];
        uint32_t serial = CGDisplaySerialNumber(display);
        NSMutableSet *ports = [NSMutableSet set];
        for (NSDictionary *row in rows) {
            NSString *port = row[@"portName"];
            if (![port hasPrefix:@"dispext"] ||
                [row[@"vendorID"] unsignedIntValue] != CGDisplayVendorNumber(display) ||
                [row[@"productID"] unsignedIntValue] != CGDisplayModelNumber(display)) continue;
            uint32_t other = [row[@"serialNumber"] unsignedIntValue];
            if (serial && other && serial != other) continue;
            // A location, when available, is binding. Without it require a real EDID serial.
            if (path.length ? ![row[@"path"] isEqual:path] : (!serial || serial != other)) continue;
            [ports addObject:port];
        }
        for (NSString *port in ports) [claims addObject:port];
        if (ports.count == 1) candidates[number] = ports.anyObject;
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSNumber *number in candidates) {
        NSString *port = candidates[number];
        if ([claims countForObject:port] == 1) result[number] = port;
    }
    return result;
}

static BOOL LDProxyMatchesPortPrefix(io_service_t proxyService, NSString *portPrefix) {
    NSString *expectedPrefix = [portPrefix stringByAppendingString:@":"];
    NSString *expectedRole = [portPrefix stringByReplacingOccurrencesOfString:@"dispext" withString:@"DCPEXT"];

    // Walk up parent chain (up to 4 levels) looking for interface-name or role matching dispextN
    io_registry_entry_t current = proxyService;
    IOObjectRetain(current);

    BOOL matched = NO;
    for (int depth = 0; depth < 4 && current != IO_OBJECT_NULL; depth++) {
        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS || parent == IO_OBJECT_NULL) {
            break;
        }

        CFTypeRef ifNameRef = IORegistryEntryCreateCFProperty(parent, CFSTR("interface-name"), kCFAllocatorDefault, kNilOptions);
        if (ifNameRef) {
            NSString *ifName = (__bridge_transfer NSString *)ifNameRef;
            if ([ifName isKindOfClass:[NSString class]] && [ifName hasPrefix:expectedPrefix]) {
                matched = YES;
            }
        }

        if (!matched) {
            CFTypeRef roleRef = IORegistryEntryCreateCFProperty(parent, CFSTR("role"), kCFAllocatorDefault, kNilOptions);
            if (roleRef) {
                NSString *role = (__bridge_transfer NSString *)roleRef;
                if ([role isKindOfClass:[NSString class]] && [role caseInsensitiveCompare:expectedRole] == NSOrderedSame) {
                    matched = YES;
                }
            }
        }

        // Also check parent's IOService name (e.g. "dispext0:dcpav-service-epic:0")
        if (!matched) {
            io_name_t entryName = {0};
            if (IORegistryEntryGetName(parent, entryName) == KERN_SUCCESS) {
                NSString *entryNameStr = [NSString stringWithUTF8String:entryName];
                if ([entryNameStr hasPrefix:expectedPrefix]) {
                    matched = YES;
                }
            }
        }

        IOObjectRelease(current);
        current = parent;
        if (matched) break;
    }

    if (current != IO_OBJECT_NULL) {
        IOObjectRelease(current);
    }
    return matched;
}

CFTypeRef _Nullable LDCreateAVServiceForPort(NSString *portPrefix) {
    if (!LDIOAVServiceIsAvailable() || !portPrefix.length) return NULL;

    CFMutableDictionaryRef matching = IOServiceMatching("DCPAVServiceProxy");
    if (!matching) return NULL;

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return NULL;
    }

    io_service_t candidate = IO_OBJECT_NULL;
    BOOL ambiguous = NO;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef locRef = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, kNilOptions);
        NSString *location = (__bridge_transfer NSString *)locRef;

        if ([location isKindOfClass:[NSString class]] && [location isEqualToString:@"External"]) {
            if (LDProxyMatchesPortPrefix(service, portPrefix)) {
                if (candidate) ambiguous = YES;
                else {
                    candidate = service;
                    IOObjectRetain(candidate);
                }
            }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    CFTypeRef result = candidate && !ambiguous ? gIOAVCreateWithService(kCFAllocatorDefault, candidate) : NULL;
    if (candidate) IOObjectRelease(candidate);
    return result;
}

// MARK: - DDC/CI over IOAVService

static const uint32_t kDDCChipAddress = 0x37;
static const uint32_t kDDCDataAddress = 0x51;

LDVCPReadResult LDDDCReadVCP(CFTypeRef avService, uint8_t code,
                             uint16_t *current, uint16_t *maximum, uint8_t *preferredReadProfile) {
    if (!LDIOAVServiceIsAvailable() || !avService || !current || !maximum || !preferredReadProfile)
        return LDVCPReadResultTransportError;
    uint8_t request[] = {0x82, 0x01, code, (uint8_t)(0x6e ^ 0x51 ^ 0x82 ^ 0x01 ^ code)};
    LDVCPReadResult result = LDVCPReadResultTransportError;
    for (unsigned attempt = 0; attempt < 3; ++attempt) {
        unsigned profile = (*preferredReadProfile + attempt) % 3;
        if (attempt) usleep(25000);
        if (gIOAVWriteI2C(avService, kDDCChipAddress, kDDCDataAddress, request, sizeof(request))) continue;
        // Retry a slow panel with a longer reply interval. Some adapters need the host subaddress.
        usleep(profile == 0 ? 40000 : 80000);
        uint8_t reply[11] = {0};
        uint32_t offset = profile == 2 ? kDDCDataAddress : 0;
        if (gIOAVReadI2C(avService, kDDCChipAddress, offset, reply, sizeof(reply))) continue;
        result = LDVCPReadResultInvalidReply;
        if (reply[0] != 0x6e || reply[1] != 0x88 || reply[2] != 0x02 || reply[4] != code) continue;
        size_t checksumIndex = 2 + (reply[1] & 0x7f);
        uint8_t checksum = 0x50;
        for (size_t i = 0; i < checksumIndex; ++i) checksum ^= reply[i];
        if (checksum != reply[checksumIndex]) continue;
        if (reply[3] == 1) return LDVCPReadResultUnsupported;
        if (reply[3] != 0) continue;
        uint16_t maxValue = (reply[6] << 8) | reply[7];
        uint16_t value = (reply[8] << 8) | reply[9];
        if (!maxValue || value > maxValue) continue;
        *preferredReadProfile = (uint8_t)profile;
        *maximum = maxValue;
        *current = value;
        return LDVCPReadResultValid;
    }
    return result;
}

BOOL LDDDCWriteVCP(CFTypeRef avService,
                   uint8_t vcpCode,
                   uint16_t newValue) {
    if (!LDIOAVServiceIsAvailable() || !avService) {
        return NO;
    }

    uint8_t hi = (uint8_t)((newValue >> 8) & 0xFF);
    uint8_t lo = (uint8_t)(newValue & 0xFF);

    uint8_t packet[6];
    packet[0] = 0x84; // Length 4 + protocol flag 0x80
    packet[1] = 0x03; // Set VCP Feature
    packet[2] = vcpCode;
    packet[3] = hi;
    packet[4] = lo;
    packet[5] = (uint8_t)(0x6E ^ kDDCDataAddress ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]);

    BOOL anySuccess = NO;
    // Apple Silicon DCPAVServiceProxy often drops the first I2C wake-up frame on LG/Dell monitors;
    // sending 2 cycles 10ms apart matches m1ddc / MonitorControl reliability.
    for (int attempt = 0; attempt < 2; attempt++) {
        IOReturn wr = gIOAVWriteI2C(avService, kDDCChipAddress, kDDCDataAddress, packet, sizeof(packet));
        if (wr == kIOReturnSuccess) {
            anySuccess = YES;
        }
        usleep(10000);
    }
    return anySuccess;
}

// MARK: - Private CGVirtualDisplay ObjC Declarations

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) uint32_t width;
@property (readonly, nonatomic) uint32_t height;
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
- (instancetype)init;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint redPrimary;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (instancetype)init;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// MARK: - LDVirtualDisplayModeSpec & LDVirtualDisplayHandle

@implementation LDVirtualDisplayModeSpec
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}
@end

@interface LDVirtualDisplayHandle ()
@property (nonatomic, strong, nullable) id virtualDisplay;
@property (nonatomic, strong) dispatch_queue_t displayQueue;
@end

@implementation LDVirtualDisplayHandle

+ (BOOL)isSupported {
    Class mode = NSClassFromString(@"CGVirtualDisplayMode");
    NSMethodSignature *signature = [mode instanceMethodSignatureForSelector:@selector(initWithWidth:height:refreshRate:)];
    if (signature.numberOfArguments != 5 ||
        strcmp([signature getArgumentTypeAtIndex:2], @encode(uint32_t)) ||
        strcmp([signature getArgumentTypeAtIndex:3], @encode(uint32_t)) ||
        strcmp([signature getArgumentTypeAtIndex:4], @encode(CGFloat))) return NO;
    Class descriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    for (NSString *name in @[@"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                             @"setSizeInMillimeters:", @"setVendorID:", @"setProductID:",
                             @"setSerialNum:", @"setQueue:", @"setWhitePoint:", @"setRedPrimary:",
                             @"setGreenPrimary:", @"setBluePrimary:", @"setTerminationHandler:"]) {
        if (![descriptor instancesRespondToSelector:NSSelectorFromString(name)]) return NO;
    }
    Class display = NSClassFromString(@"CGVirtualDisplay");
    Class settings = NSClassFromString(@"CGVirtualDisplaySettings");
    return [display instancesRespondToSelector:@selector(initWithDescriptor:)] &&
           [display instancesRespondToSelector:@selector(displayID)] &&
           [display instancesRespondToSelector:@selector(applySettings:)] &&
           [settings instancesRespondToSelector:@selector(setHiDPI:)] &&
           [settings instancesRespondToSelector:@selector(setModes:)];
}

- (nullable instancetype)initWithName:(NSString *)name
                             maxWidth:(NSUInteger)maxWidth
                            maxHeight:(NSUInteger)maxHeight
                    sizeInMillimeters:(CGSize)sizeInMM
                                modes:(NSArray<LDVirtualDisplayModeSpec *> *)modes
                                hiDPI:(BOOL)hiDPI
                         serialNumber:(uint32_t)serialNumber
                   terminationHandler:(nullable void (^)(void))terminationHandler {
    self = [super init];
    if (!self) return nil;

    if (!maxWidth || !maxHeight || maxWidth > UINT32_MAX || maxHeight > UINT32_MAX || ![LDVirtualDisplayHandle isSupported]) {
        return nil;
    }

    Class DescriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class DisplayClass = NSClassFromString(@"CGVirtualDisplay");

    _displayQueue = dispatch_queue_create("com.isnow890.solis.virtualDisplay", DISPATCH_QUEUE_SERIAL);

    CGVirtualDisplayDescriptor *descriptor = [[DescriptorClass alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)maxWidth;
    descriptor.maxPixelsHigh = (unsigned int)maxHeight;
    descriptor.sizeInMillimeters = sizeInMM;
    descriptor.vendorID = 0x1E6D;
    descriptor.productID = 0x5B11;
    descriptor.serialNum = serialNumber;
    descriptor.queue = _displayQueue;
    // Standard sRGB/Display P3-like D65 primaries
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.redPrimary = CGPointMake(0.6400, 0.3300);
    descriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
    descriptor.bluePrimary = CGPointMake(0.1500, 0.0600);

    if (terminationHandler) {
        descriptor.terminationHandler = ^(id _unused1, id _unused2) {
            dispatch_async(dispatch_get_main_queue(), terminationHandler);
        };
    }

    CGVirtualDisplay *display = [[DisplayClass alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == kCGNullDirectDisplay) {
        return nil;
    }

    _virtualDisplay = display;
    _displayID = display.displayID;

    if (![self applyModes:modes hiDPI:hiDPI]) {
        _virtualDisplay = nil;
        _displayID = kCGNullDirectDisplay;
        return nil;
    }

    return self;
}

- (BOOL)isActive {
    return self.virtualDisplay != nil && self.displayID != kCGNullDirectDisplay;
}

- (BOOL)applyModes:(NSArray<LDVirtualDisplayModeSpec *> *)modes hiDPI:(BOOL)hiDPI {
    if (!self.virtualDisplay) return NO;

    Class SettingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class ModeClass = NSClassFromString(@"CGVirtualDisplayMode");

    NSMutableArray *cgModes = [NSMutableArray arrayWithCapacity:modes.count];
    for (LDVirtualDisplayModeSpec *spec in modes) {
        if (!spec.width || !spec.height || spec.width > UINT32_MAX || spec.height > UINT32_MAX) return NO;
        id mode = [(CGVirtualDisplayMode *)[ModeClass alloc] initWithWidth:(uint32_t)spec.width height:(uint32_t)spec.height refreshRate:spec.refreshRate];
        if (mode) {
            [cgModes addObject:mode];
        }
    }

    CGVirtualDisplaySettings *settings = [[SettingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    if (cgModes.count != modes.count || !cgModes.count) return NO;
    settings.modes = cgModes;

    return [(CGVirtualDisplay *)self.virtualDisplay applySettings:settings];
}

- (void)invalidate {
    self.virtualDisplay = nil;
    _displayID = kCGNullDirectDisplay;
}

@end

// MARK: - Mirroring Helpers

BOOL LDMirrorDisplay(CGDirectDisplayID targetDisplay, CGDirectDisplayID masterDisplay) {
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) {
        return NO;
    }
    CGError err = CGConfigureDisplayMirrorOfDisplay(config, targetDisplay, masterDisplay);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return NO;
    }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession) == kCGErrorSuccess;
}

BOOL LDUnmirrorDisplay(CGDirectDisplayID targetDisplay) {
    return LDMirrorDisplay(targetDisplay, kCGNullDirectDisplay);
}

NS_ASSUME_NONNULL_END
