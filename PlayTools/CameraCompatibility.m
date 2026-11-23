#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#if TARGET_OS_MACCATALYST
#import <PlayTools/PlayTools-Swift.h>

static BOOL (*pt_nativePickerAvailability)(id, SEL, UIImagePickerControllerCameraDevice);
static void (*pt_nativeSetPickerCameraDevice)(UIImagePickerController *, SEL, UIImagePickerControllerCameraDevice);
static AVCaptureDevice *(*pt_nativeTypedCamera)(id, SEL, AVCaptureDeviceType, AVMediaType, AVCaptureDevicePosition);
static AVCaptureDeviceDiscoverySession *(*pt_nativeCameraDiscovery)(id, SEL, NSArray *, AVMediaType, AVCaptureDevicePosition);
static void (*pt_nativeCameraOrientation)(AVCaptureConnection *, SEL, AVCaptureVideoOrientation);
static void (*pt_nativeCameraAngle)(AVCaptureConnection *, SEL, CGFloat);
static void (*pt_nativeStartCameraSession)(AVCaptureSession *, SEL);
static __thread NSUInteger pt_nativePickerCheckDepth;
static __thread BOOL pt_applyingCameraAngle;
static char pt_frontFallbackKey;
static char pt_rotationCoordinatorKey;

// The settings are shared with PlayCover. An explicit angle overrides the app's orientation.
static const NSInteger pt_automaticCameraRotation = -1;

static BOOL pt_callNativePicker(id self, SEL command, UIImagePickerControllerCameraDevice device) {
    pt_nativePickerCheckDepth++;
    @try {
        return pt_nativePickerAvailability(self, command, device);
    } @finally {
        pt_nativePickerCheckDepth--;
    }
}

static BOOL pt_cameraAccessCanBeRequested(void) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    return status == AVAuthorizationStatusAuthorized || status == AVAuthorizationStatusNotDetermined;
}

static BOOL pt_usableCamera(AVCaptureDevice *device) {
    return device.isConnected && !device.isSuspended;
}

static BOOL pt_localFrontCamera(AVCaptureDevice *device) {
    if (!pt_usableCamera(device) || device.position != AVCaptureDevicePositionFront) { return NO; }
    if (@available(macCatalyst 16.0, *)) {
        if (device.isContinuityCamera) { return NO; }
    }
    return YES;
}

static AVCaptureDevice *pt_findLocalFrontCamera(void) {
    if (!pt_cameraAccessCanBeRequested()) { return nil; }

    AVCaptureDevice *device = pt_nativeTypedCamera(AVCaptureDevice.class,
        @selector(defaultDeviceWithDeviceType:mediaType:position:), AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVMediaTypeVideo, AVCaptureDevicePositionFront);
    return pt_localFrontCamera(device) ? device : nil;
}

static BOOL pt_hasNativeRearCamera(void) {
    if (!pt_nativePickerAvailability) { return NO; }
    return pt_callNativePicker(UIImagePickerController.class, @selector(isCameraDeviceAvailable:),
                               UIImagePickerControllerCameraDeviceRear);
}

static BOOL pt_pickerCameraAvailability(id self, SEL command, UIImagePickerControllerCameraDevice device) {
    BOOL topLevel = (pt_nativePickerCheckDepth == 0);
    BOOL available = pt_callNativePicker(self, command, device);
    return available || (topLevel && device == UIImagePickerControllerCameraDeviceRear &&
                         pt_findLocalFrontCamera() != nil);
}

static void pt_setPickerCameraDevice(UIImagePickerController *self, SEL command,
                                     UIImagePickerControllerCameraDevice device) {
    if (device == UIImagePickerControllerCameraDeviceRear &&
        !pt_hasNativeRearCamera() &&
        pt_nativePickerAvailability &&
        pt_callNativePicker(UIImagePickerController.class, @selector(isCameraDeviceAvailable:),
                            UIImagePickerControllerCameraDeviceFront)) {
        device = UIImagePickerControllerCameraDeviceFront;
    }
    pt_nativeSetPickerCameraDevice(self, command, device);
}

static AVCaptureDevice *pt_selectCamera(id self, SEL command, AVCaptureDeviceType type,
                                       AVMediaType media, AVCaptureDevicePosition position) {
    AVCaptureDevice *requested = pt_nativeTypedCamera(self, command, type, media, position);
    if (pt_nativePickerCheckDepth > 0 || position != AVCaptureDevicePositionBack ||
        ![media isEqualToString:AVMediaTypeVideo] || ![type isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera] ||
        (pt_usableCamera(requested) && pt_hasNativeRearCamera())) {
        return requested;
    }

    AVCaptureDevice *front = pt_findLocalFrontCamera();
    if (front) {
        objc_setAssociatedObject(front, &pt_frontFallbackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return front ?: requested;
}

static AVCaptureDeviceDiscoverySession *pt_discoverCameras(id self, SEL command, NSArray *types, AVMediaType media,
                                                          AVCaptureDevicePosition position) {
    AVCaptureDeviceDiscoverySession *requested = pt_nativeCameraDiscovery(self, command, types, media, position);
    if (pt_nativePickerCheckDepth > 0 || position != AVCaptureDevicePositionBack || ![media isEqualToString:AVMediaTypeVideo] ||
        ![types containsObject:AVCaptureDeviceTypeBuiltInWideAngleCamera]) {
        return requested;
    }
    if (pt_hasNativeRearCamera()) {
        for (AVCaptureDevice *device in requested.devices) {
            if (pt_usableCamera(device)) { return requested; }
        }
    }
    if (!pt_cameraAccessCanBeRequested()) { return requested; }

    AVCaptureDeviceDiscoverySession *front = pt_nativeCameraDiscovery(self, command,
        @[AVCaptureDeviceTypeBuiltInWideAngleCamera], media, AVCaptureDevicePositionFront);
    BOOL hasFront = NO;
    for (AVCaptureDevice *device in front.devices) {
        if (pt_localFrontCamera(device)) {
            hasFront = YES;
            objc_setAssociatedObject(device, &pt_frontFallbackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    // Report the actual front-facing device, including its true position and capabilities.
    return hasFront ? front : requested;
}

static AVCaptureDevice *pt_videoDeviceForConnection(AVCaptureConnection *connection) {
    for (AVCaptureInputPort *port in connection.inputPorts) {
        if ([port.mediaType isEqualToString:AVMediaTypeVideo] && [port.input isKindOfClass:AVCaptureDeviceInput.class]) {
            return ((AVCaptureDeviceInput *)port.input).device;
        }
    }
    return nil;
}

API_AVAILABLE(macCatalyst(17.0))
static CGFloat pt_horizonAngle(AVCaptureConnection *connection, AVCaptureDevice *device) {
    AVCaptureVideoPreviewLayer *preview = connection.videoPreviewLayer;
    AVCaptureDeviceRotationCoordinator *coordinator = objc_getAssociatedObject(connection, &pt_rotationCoordinatorKey);
    if (!coordinator || coordinator.device != device || coordinator.previewLayer != preview) {
        coordinator = [[AVCaptureDeviceRotationCoordinator alloc] initWithDevice:device previewLayer:preview];
        objc_setAssociatedObject(connection, &pt_rotationCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return preview ? coordinator.videoRotationAngleForHorizonLevelPreview : coordinator.videoRotationAngleForHorizonLevelCapture;
}

static BOOL pt_applyCameraRotation(AVCaptureConnection *connection) {
    if (pt_applyingCameraAngle || !pt_nativeCameraAngle) { return NO; }
    if (@available(macCatalyst 17.0, *)) {
        NSInteger setting = PlaySettings.shared.cameraRotation;
        BOOL automatic = setting == pt_automaticCameraRotation;
        if (!automatic && setting != 0 && setting != 90 && setting != 180 && setting != 270) { return NO; }
        AVCaptureDevice *device = pt_videoDeviceForConnection(connection);
        if (!device) { return NO; }

        if (automatic) {
            if (![device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera] ||
                 device.isContinuityCamera ||
                 !objc_getAssociatedObject(device, &pt_frontFallbackKey)) {
                return NO;
            }
        }

        CGFloat angle = automatic ? pt_horizonAngle(connection, device) : setting;
        if (![connection isVideoRotationAngleSupported:angle]) { return NO; }
        if (connection.videoRotationAngle != angle) {
            pt_applyingCameraAngle = YES;
            @try {
                pt_nativeCameraAngle(connection, @selector(setVideoRotationAngle:), angle);
            } @finally {
                pt_applyingCameraAngle = NO;
            }
        }
        return YES;
    }
    return NO;
}

static void pt_setCameraOrientation(AVCaptureConnection *connection, SEL command, AVCaptureVideoOrientation requested) {
    if (!pt_applyCameraRotation(connection)) { pt_nativeCameraOrientation(connection, command, requested); }
}

static void pt_setCameraAngle(AVCaptureConnection *connection, SEL command, CGFloat requested) {
    if (!pt_applyCameraRotation(connection)) { pt_nativeCameraAngle(connection, command, requested); }
}

static void pt_startCameraSession(AVCaptureSession *session, SEL command) {
    for (AVCaptureConnection *connection in session.connections) {
        pt_applyCameraRotation(connection);
    }
    pt_nativeStartCameraSession(session, command);
}

__attribute__((constructor))
static void pt_installCameraCompatibility(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        if (![bundle objectForInfoDictionaryKey:@"NSCameraUsageDescription"]) { return; }

        #define PT_CAMERA_HOOK(c, which, selectorName, original, hook) do { \
            Method method = class_get##which##Method(c.class, @selector(selectorName)); \
            if (method) original = (__typeof__(original))method_setImplementation(method, (IMP)hook); \
        } while (0)
        PT_CAMERA_HOOK(AVCaptureDevice, Class, defaultDeviceWithDeviceType:mediaType:position:,
                       pt_nativeTypedCamera, pt_selectCamera);
        PT_CAMERA_HOOK(AVCaptureDeviceDiscoverySession, Class, discoverySessionWithDeviceTypes:mediaType:position:,
                       pt_nativeCameraDiscovery, pt_discoverCameras);
        if (@available(macCatalyst 17.0, *)) {
            PT_CAMERA_HOOK(AVCaptureConnection, Instance, setVideoRotationAngle:, pt_nativeCameraAngle, pt_setCameraAngle);
            PT_CAMERA_HOOK(AVCaptureConnection, Instance, setVideoOrientation:,
                           pt_nativeCameraOrientation, pt_setCameraOrientation);
            PT_CAMERA_HOOK(AVCaptureSession, Instance, startRunning, pt_nativeStartCameraSession, pt_startCameraSession);
        }
        if (pt_nativeTypedCamera) {
            PT_CAMERA_HOOK(UIImagePickerController, Class, isCameraDeviceAvailable:,
                           pt_nativePickerAvailability, pt_pickerCameraAvailability);
            PT_CAMERA_HOOK(UIImagePickerController, Instance, setCameraDevice:,
                           pt_nativeSetPickerCameraDevice, pt_setPickerCameraDevice);
        }
        #undef PT_CAMERA_HOOK
    }
}
#endif
