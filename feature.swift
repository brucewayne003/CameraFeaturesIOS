//
//  CameraManager.swift
//  DiamondRnMvpoc
//
//  Created by Andres Vinueza on 3/10/23.
//

import AVFoundation
import Combine
import Foundation
import os
import Osiris
import UIKit

// Temporary diagnostics for macro lens transition timing.
func osirisMacroTrace(_ message: String) {
    let ms = Int(ProcessInfo.processInfo.systemUptime * 1_000)
    print("[MacroTiming] \(ms)ms \(message)")
}

public final class CameraManager: NSObject, ObservableObject {
    public func applyCameraPreset(_ preset: CameraPreferences.CameraPreset) {
        let preferences = CameraPreferences.preset(preset)
        self.cameraPreferences = preferences
        
        // Set frame rates based on preset
        let frameRates = CameraPreferences.frameRates(for: preset)
        userDefaults.activeVideoMinFrameRate = frameRates.min
        userDefaults.activeVideoMaxFrameRate = frameRates.max
        
        // Set video stabilization based on preset
        userDefaults.videoStabilizationEnabled = preferences.videoStabilizationEnabled
        
        if let device = currentDevice {
            refreshCameraSettings(forCamera: device)
        }
    }
    
    internal static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: CameraManager.self)
    )
    
    public enum Status: String {
        case unconfigured = "permission has not been requested"
        case configured = "all systems go"
        case running = "running AVCaptureSession"
        case unauthorized = "permission denied"
        case failed = "failed to connect"
    }
    
    internal let userDefaults: UserDefaults
    
    /// observable instance of the current `CameraError`
    @Published public private(set) var error: CameraError?
    
    /// observable instnace of the image, represented as `Data`
    @Published public internal(set) var imageData: Data?
    
    /// observale instance of the current camera status
    @Published public private(set) var status = Status.unconfigured
    private let statusSemaphore = DispatchSemaphore(value: 1)
    private let sampleBufferDelegateSemaphore = DispatchSemaphore(value: 1)
    
    /// observable instace of the camera preferences pulled from the user defaults instance
    @Published public var cameraPreferences: CameraPreferences
    
    /// The current camera output size, in pixels. This does not take into account pixel aspect ratio or clean aperture tags.
    @Published public var imageSize: CGSize = .zero
    
    /// Access to the instance of `AVCaptureSession` used
    @Published public private(set) var session = AVCaptureSession()
    
    private let sessionQueue = DispatchQueue(label: "com.walmart.diamond.SessionQ")
    private let sessionQueueKey = DispatchSpecificKey<Bool>()
    private let videoDataOutputQueue = DispatchQueue(label: "com.walmart.diamond.VideoDataOutput",
                                                     qos: .userInitiated,
                                                     autoreleaseFrequency: .workItem)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    private var cancellables = Set<AnyCancellable>()
    
    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.cameraPreferences = userDefaults.currentCameraPreferences
        super.init()
        sessionQueue.setSpecific(key: sessionQueueKey, value: true)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // Notifications & Lifecycle variables
    
    private var appLifecycleWired = false
    private var notificationsWired = false
    
    //  Camera, Lens, Torch, Macro Mode & FOV variables
    
    @Published public var currentDevice: AVCaptureDevice?
    
    @Published private var lensPosition: Float = 0.0
    
    @Published public private(set) var torchEnabled: Bool = false
    
    private var cameraStartTime: Date = .distantPast
    
    private var wantsTorchOnAfterResume = false
    private var wantsTorchOnAfterLensSwitch = false
    private var pendingReenableTorch = false
    
    private var lastLensSwitch: Date = .distantPast
    
    public var isUsingMacroCamera = false
    
    public var onCameraSwitch: (() -> Void)?
    
    private static let fovMatchRatio:CGFloat = 26.0 / 13.0
    
    public var onWillSwitchCamera: (()-> Void)?

    // Unlike onCameraSwitch, this only reports completion of a macro lens swap.
    internal var onLensSwitchCompleted: ((Bool) -> Void)?
    
    private var isSwitchingLens = false

    private let cameraModeLock = NSLock()
    private var storedLensSwitchingMode: OsirisCameraSwitchingMode = .manual
    internal private(set) var lensSwitchingMode: OsirisCameraSwitchingMode {
        get {
            cameraModeLock.lock()
            defer { cameraModeLock.unlock() }
            return storedLensSwitchingMode
        }
        set {
            cameraModeLock.lock()
            storedLensSwitchingMode = newValue
            cameraModeLock.unlock()
        }
    }
    internal var usesAutomaticCameraMode: Bool { lensSwitchingMode == .automatic }
    private var nativeCameraObservations = [NSKeyValueObservation]()
    private var nativeFocusPositionCancellables = Set<AnyCancellable>()
    private var nativeCameraObservationID = UUID()
    private var nativeCameraLoggingEnabled = false

    // Never wait synchronously for this queue from the UI. It can be suspended
    // while the user is answering the camera-permission prompt.
    internal func performCameraConfiguration(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: sessionQueueKey) == true {
            operation()
        } else {
            sessionQueue.async(execute: operation)
        }
    }

    internal var isOnSessionQueue: Bool {
        DispatchQueue.getSpecific(key: sessionQueueKey) == true
    }

    /// Keep configuration ahead of startSession() on the same serial queue.
    internal func applyScannerCameraConfiguration(_ settings: OsirisCameraConfig, enableLogging: Bool) {
        performCameraConfiguration {
            self.lensSwitchingMode = settings.lensSwitchingMode
            self.nativeCameraLoggingEnabled = enableLogging
            self.lensKvoCancellables.removeAll()
            self.stopNativeCameraDiagnostics()
            self.lowSharpnessSince = nil
            self.nativeCameraTrace("CONFIG begin, requestedResolution=\(settings.resolution.rawValue)")

            let device = self.scannerDevice(for: settings)
            self.updateCaptureDevice(to: device)
            self.setCameraResolution(to: settings.resolution)

            // This flag controls the legacy manual algorithm only. Automatic
            // switching is explicitly selected by lensSwitchingMode instead.
            let manualMacroEnabled = OsirisFlags.macroModeEnabled && settings.macroModeEnabled
            self.update(isMacroMode: manualMacroEnabled ? .on : .off)
            // Apply focus options before focusMode starts/restarts autofocus.
            self.update(isSmoothAutoFocus: .off)
            self.update(isAutoFocus: settings.autoFocusEnabled ? .on : .off)
            self.update(isAutoISO: settings.autoISOEnabled ? .on : .off(settings.manualISOValue))
            self.update(isAutoExposure: settings.autoExposureEnabled ? .on : .off(settings.manualExposureValue))
            self.update(isAutoWhiteBalance: settings.autoWhiteBalanceEnabled ? .on : .manual(
                temperature: settings.manualWhiteBalanceValue.temperature,
                tint: settings.manualWhiteBalanceValue.tint
            ))

            if self.usesAutomaticCameraMode, let camera = self.currentDevice {
                self.configureAutomaticSwitching(for: camera)
                self.startNativeCameraDiagnostics(for: camera)
                self.traceNativeCameraSettings("CONFIG end", for: camera)
            } else {
                self.observeLensPosition()
            }
        }
    }

    private func scannerDevice(for settings: OsirisCameraConfig) -> AVCaptureDevice? {
        guard settings.lensSwitchingMode == .automatic else { return settings.device }
        // Front-camera integrations must never silently turn on the rear camera.
        if settings.device?.position == .front { return settings.device }
        let devices = Self.discoverVideoCaptureDevices(position: .back)
        let preferredTypes: [AVCaptureDevice.DeviceType] = [.builtInDualWideCamera, .builtInTripleCamera]
        for type in preferredTypes {
            if let device = devices.first(where: {
                $0.deviceType == type &&
                $0.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported
            }) {
                return device
            }
        }
        // Do not fall back to the old manual swapping algorithm in automatic mode.
        return devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? settings.device
    }

    private func configureAutomaticSwitching(for device: AVCaptureDevice) {
        guard device.isVirtualDevice,
              device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported else {
            nativeCameraTrace("Automatic switching unavailable; using \(device.deviceType.rawValue)")
            return
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: [])
            device.fallbackPrimaryConstituentDevices = device.supportedFallbackPrimaryConstituentDevices
            device.videoZoomFactor = baselineZoom(for: device)
        } catch {
            Self.logger.error("Automatic camera configuration failed: \(error.localizedDescription)")
            return
        }
        nativeCameraTrace("Configured \(device.deviceType.rawValue), rawZoom=\(device.videoZoomFactor), switching=auto")
    }

    internal func setNativeCameraLoggingEnabled(_ enabled: Bool) {
        performCameraConfiguration {
            guard self.nativeCameraLoggingEnabled != enabled else { return }
            self.nativeCameraLoggingEnabled = enabled
            if enabled, self.usesAutomaticCameraMode, let device = self.currentDevice {
                self.startNativeCameraDiagnostics(for: device)
                self.traceNativeCameraSettings("LOGGING enabled", for: device)
            } else {
                self.stopNativeCameraDiagnostics()
            }
        }
    }

    private func nativeCameraTrace(_ message: String, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard usesAutomaticCameraMode, nativeCameraLoggingEnabled else { return }
        let milliseconds = Int(uptime * 1_000)
        print("[NativeCamera] \(milliseconds)ms \(message)")
    }

    // Temporary, event-only diagnostics. These observers never change camera
    // settings or wait for frames. All token/generation state stays on SessionQ.
    private func stopNativeCameraDiagnostics() {
        nativeCameraObservationID = UUID()
        nativeCameraObservations.removeAll()
        nativeFocusPositionCancellables.removeAll()
    }

    private func startNativeCameraDiagnostics(for device: AVCaptureDevice) {
        stopNativeCameraDiagnostics()
        guard usesAutomaticCameraMode, nativeCameraLoggingEnabled else { return }
        let observationID = nativeCameraObservationID

        nativeCameraObservations.append(device.observe(\.isAdjustingFocus, options: [.initial, .old, .new]) { [weak self] device, change in
            guard change.oldValue != change.newValue, let adjusting = change.newValue else { return }
            let event = change.oldValue == nil ? "FOCUS initial" : "FOCUS changed"
            // false means autofocus stopped adjusting, not that a barcode is sharp.
            self?.recordNativeCameraEvent("\(event), adjusting=\(adjusting)", for: device, observationID: observationID)
        })

        if device.isVirtualDevice {
            nativeCameraObservations.append(device.observe(\.activePrimaryConstituent, options: [.initial, .old, .new]) { [weak self] device, change in
                let previous = change.oldValue.flatMap { $0 }?.deviceType.rawValue ?? "none"
                let current = change.newValue.flatMap { $0 }?.deviceType.rawValue ?? "none"
                let initial = change.oldValue == nil
                guard initial || previous != current else { return }
                let event = initial ? "LENS initial: \(current)" : "LENS changed: \(previous) -> \(current)"
                self?.recordNativeCameraEvent(event, for: device, observationID: observationID)
            })
        }

        // Observe both the combined camera and its physical lenses: focus can
        // move without isAdjustingFocus reporting a contrast-detection scan.
        nativeCameraTrace("FOCUS position diagnostics: changes logged at most once every 200ms per source; position is a lens setting, not subject distance or proof of sharpness")
        var observedDeviceIDs = Set<String>()
        for source in [device] + device.constituentDevices {
            guard observedDeviceIDs.insert(source.uniqueID).inserted else { continue }
            observeNativeFocusPosition(on: source, sessionDevice: device, observationID: observationID)
        }
    }

    private func observeNativeFocusPosition(on source: AVCaptureDevice, sessionDevice: AVCaptureDevice, observationID: UUID) {
        let sourceName = source.deviceType.rawValue
        let scope = source.isVirtualDevice ? "virtual" : "physical"
        source.publisher(for: \.lensPosition, options: [.initial, .new])
            .removeDuplicates()
            .map { position in
                // Capture values before throttling, rather than reading a newer
                // position later and attaching an older timestamp to it.
                let eventTime = ProcessInfo.processInfo.systemUptime
                let primary = sessionDevice.isVirtualDevice ? sessionDevice.activePrimaryConstituent : sessionDevice
                return (time: eventTime, position: position,
                        activeLens: primary?.deviceType.rawValue ?? "none",
                        isPrimary: primary?.uniqueID == source.uniqueID,
                        autoFocusSystem: Self.nativeAutoFocusSystemName(for: source))
            }
            // Only diagnostic output is throttled. latest:true also delivers the
            // final pending sample when focus motion stops between log windows.
            .throttle(for: .milliseconds(200), scheduler: sessionQueue, latest: true)
            .sink { [weak self] sample in
                guard let self = self, self.nativeCameraObservationID == observationID,
                      self.usesAutomaticCameraMode, self.nativeCameraLoggingEnabled,
                      self.currentDevice?.uniqueID == sessionDevice.uniqueID else { return }
                let position = String(format: "%.4f", sample.position)
                let deliveryMilliseconds = Int((ProcessInfo.processInfo.systemUptime - sample.time) * 1_000)
                self.nativeCameraTrace("FOCUS position sample, source=\(sourceName), scope=\(scope), primary=\(sample.isPrimary), activeLens=\(sample.activeLens), position=\(position), autoFocusSystem=\(sample.autoFocusSystem), sample_to_log_ms=\(deliveryMilliseconds) (includes diagnostic throttling)", at: sample.time)
            }
            .store(in: &nativeFocusPositionCancellables)
    }

    private static func nativeAutoFocusSystemName(for device: AVCaptureDevice) -> String {
        switch device.activeFormat.autoFocusSystem {
        case .none: return "none"
        case .contrastDetection: return "contrastDetection"
        case .phaseDetection: return "phaseDetection"
        @unknown default: return "unknown"
        }
    }

    private func recordNativeCameraEvent(_ event: String, for device: AVCaptureDevice, observationID: UUID) {
        // Capture the time and device state at the callback, before any queue wait.
        let eventTime = ProcessInfo.processInfo.systemUptime
        let state = Self.nativeCameraFocusState(for: device)
        performCameraConfiguration { [weak self] in
            guard let self = self, self.nativeCameraObservationID == observationID,
                  self.usesAutomaticCameraMode, self.nativeCameraLoggingEnabled,
                  self.currentDevice?.uniqueID == device.uniqueID else { return }
            let deliveryMilliseconds = Int((ProcessInfo.processInfo.systemUptime - eventTime) * 1_000)
            self.nativeCameraTrace("\(event), callback_to_log_ms=\(deliveryMilliseconds), \(state)", at: eventTime)
        }
    }

    private static func nativeCameraFocusState(for device: AVCaptureDevice) -> String {
        let lens = device.isVirtualDevice ? device.activePrimaryConstituent?.deviceType.rawValue ?? "none" : device.deviceType.rawValue
        let focus = device.focusMode == .continuousAutoFocus ? "continuous" : (device.focusMode == .autoFocus ? "once" : "locked")
        let range = device.autoFocusRangeRestriction == .none ? "none" : (device.autoFocusRangeRestriction == .near ? "near" : "far")
        let point = device.focusPointOfInterest
        return "device=\(device.deviceType.rawValue), lens=\(lens), rawZoom=\(device.videoZoomFactor), focus=\(focus), range=\(range), smooth=\(device.isSmoothAutoFocusEnabled), point=(\(point.x),\(point.y)), lensPosition=\(device.lensPosition), autoFocusSystem=\(nativeAutoFocusSystemName(for: device)), adjustingFocus=\(device.isAdjustingFocus), adjustingExposure=\(device.isAdjustingExposure)"
    }

    private func traceNativeCameraSettings(_ event: String, for device: AVCaptureDevice) {
        guard usesAutomaticCameraMode, nativeCameraLoggingEnabled else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let minFrameMilliseconds = CMTimeGetSeconds(device.activeVideoMinFrameDuration) * 1_000
        let maxFrameMilliseconds = CMTimeGetSeconds(device.activeVideoMaxFrameDuration) * 1_000
        let stabilization = videoOutput.connection(with: .video)?.activeVideoStabilizationMode.rawValue ?? -1
        let fallbacks = device.fallbackPrimaryConstituentDevices.map { $0.deviceType.rawValue }.joined(separator: ",")
        let faceFocus: String
        if #available(iOS 15.4, *) {
            faceFocus = String(device.isFaceDrivenAutoFocusEnabled)
        } else {
            faceFocus = "unavailable"
        }
        nativeCameraTrace("\(event), \(Self.nativeCameraFocusState(for: device))")
        nativeCameraTrace("SETTINGS, running=\(session.isRunning), resolution=\(dimensions.width)x\(dimensions.height), frameDuration_ms=\(minFrameMilliseconds)...\(maxFrameMilliseconds), stabilization=\(stabilization), switching=\(device.activePrimaryConstituentDeviceSwitchingBehavior.rawValue), fallbacks=[\(fallbacks)], faceFocus=\(faceFocus)")
    }
    
    // Sharpness, smoothness for close up Macro variables
    
    private var closeEnterLensPos: Float = 0.015
    
    private var sharpnessEMA: Double = 0
    private let sharpnessAlpha: Double = 1
    private var lowSharpnessSince: Date?
    private let blurStableDuration: TimeInterval = 0.12
    
    public var sharpnessEnterThreshold: Double = 18
    
    private var isVeryBlur: Bool {
        if let t = lowSharpnessSince {
            return Date().timeIntervalSince(t) >= blurStableDuration
        }
        return false
    }
    
    public var sharpnessSmoothed: Double {sharpnessEMA}
    
    /**
     Configures the capture session and checks necessary permissions before initializing the camera.
     
     This function is responsible for setting up the capture session for camera usage and ensuring that the required permissions are granted before configuring the session. It is recommended to call this function before starting camera-related operations.
     
     The function performs the following steps:
     1. Checks and requests necessary permissions for camera usage.
     2. Asynchronously configures the capture session by invoking the `configureCaptureSession()` method.
     
     Calling this function initializes the camera capture session, allowing subsequent camera operations to take place.
     
     - Warning: If the required permissions are not granted or if any errors occur during the configuration process, camera-related functionality may not work as expected.
     
     - Postcondition: Upon successful execution, the camera capture session is configured and ready for use.
     */
    public final func configure() {
        checkPermissions()
        
        sessionQueue.async {
            self.configureCaptureSession()
            DispatchQueue.main.async {
                self.wireSessionNotifications()
                self.wireAppLifeCycleNotifications()
            }
            self.setuplensPosition()
        }
    }
    
    private func notifyTorchChanged(_ isOn: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .osirisTorchDidChange, object: nil, userInfo: ["isOn": isOn])
        }
    }
    
    /// Asynchronously sets the sample buffer delegate on the current `AVCaptureVideoDataOutput` instance
    ///
    ///  - Parameters:
    ///   - delegate:   object that conforms to the protocol AVCaptureVideoDataOutputSampleBufferDelegate
    ///   - queue:      A dispatch queue on which all sample buffer delegate methods will be called.
    public func setOutputSampleBufferDelegate(to delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
                                              queue: DispatchQueue?) {
        sampleBufferDelegateSemaphore.wait()
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(delegate, queue: queue ?? self.videoDataOutputQueue)
            self.sampleBufferDelegateSemaphore.signal()
        }
    }
    
    /// Sets the sample buffer delegate to nil
    public func tearDownOutputSampleBufferDelegate() {
        sampleBufferDelegateSemaphore.wait()
        sessionQueue.async {
            self.videoOutput.setSampleBufferDelegate(nil, queue: nil)
            self.sampleBufferDelegateSemaphore.signal()
        }
    }
    
    public func updateCameraPreferences(fromCamera camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            
            cameraPreferences.minExposureBias = camera.minExposureTargetBias
            cameraPreferences.maxExposureBias = camera.maxExposureTargetBias
            
            cameraPreferences.minISO = camera.activeFormat.minISO
            cameraPreferences.maxISO = camera.activeFormat.maxISO
            
            userDefaults.currentCameraPreferences = cameraPreferences
            
            camera.unlockForConfiguration()
        } catch {
            print("Error locking configuration for updateSettings(forCamera camera: \(error)")
        }
    }
    
    private func applyModelTuning(){
        let id = modelIdentifier().uppercased()
        
        if id.hasPrefix("IPHONE15,"){
            closeEnterLensPos = 0.020
        } else if id.hasPrefix("IPHONE16,") {
            closeEnterLensPos = 0.025
        } else if id.hasPrefix("IPHONE17,") {
           closeEnterLensPos = 0.030
        }
        else {
            closeEnterLensPos = 0.015
        }
        
        print("[MacroMode] model: \(id) closeEnterLensPos: \(closeEnterLensPos)")
    }
    
    private func configureCaptureSession() {
        guard getStatus() == .unconfigured else { return }
        
        defer {
            session.commitConfiguration()
        }
        
        session.beginConfiguration()
        
        guard let camera = configureCaptureDevice() else {
            set(error: .cameraUnavailable)
            setStatus(.failed)
            return
        }
        
        currentDevice = camera
        applyModelTuning()
        persistActiveDevice(camera)
        
        session.addOutput(photoOutput)
        session.addOutput(videoOutput)
        
        refreshCameraSettings(forCamera: camera)
        
        // Set Camera Device to use for updating camera settings later
        updateCameraPreferences(fromCamera: camera)
        
        setStatus(.configured)
    }
    
    internal func updateCaptureDevice(to captureDevice: AVCaptureDevice?) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.updateCaptureDevice(to: captureDevice) }
            return
        }
        // A settings reload must not rebuild an unchanged virtual-camera input.
        if let captureDevice = captureDevice,
           session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
            .contains(where: { $0.device.uniqueID == captureDevice.uniqueID }) {
            return
        }
        nativeCameraTrace("INPUT reconfiguration begin, target=\(captureDevice?.deviceType.rawValue ?? "none")")
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            nativeCameraTrace("INPUT reconfiguration end, device=\(currentDevice?.deviceType.rawValue ?? "none")")
        }
        
        guard
            let currentInput = session.inputs.first as? AVCaptureDeviceInput,
            let newDevice = captureDevice
        else { return }
        
        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)
            
            session.removeInput(currentInput)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                
                self.currentDevice = newDevice
                self.persistActiveDevice(newDevice)
                self.updateCameraPreferences(fromCamera: newDevice)
                // Need to refresh settings after adding cameraInput
                refreshCameraSettings(forCamera: newDevice)
                
                // Set Camera Device to use for updating camera settings later
                updateCameraPreferences(fromCamera: newDevice)
                
                let captureDevices = Self.discoverVideoCaptureDevices()
                
            } else {
                print("Cannot add new camera input.")
                // Re-add the old input if the new one can't be added
                if session.canAddInput(currentInput) { session.addInput(currentInput) }
            }
        } catch {
            print("Error creating camera input: \(error)")
            // Input creation failed before removing the original input.
        }
        
        DispatchQueue.main.async {
            self.onCameraSwitch?()
        }
    }
    
    // Refreshes camera settings
    // This ensures the barcode reticle is displayed properly
    internal func refreshCameraSettings(forCamera camera: AVCaptureDevice) {
        
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings =
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        
        let videoConnection = videoOutput.connection(with: .video)
        videoConnection?.videoOrientation = .portrait
        
        // Enable video stabilization if setting is enabled
        if let connection = videoConnection, connection.isVideoStabilizationSupported {
            if userDefaults.videoStabilizationEnabled {
                connection.preferredVideoStabilizationMode = .auto
            } else {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        
        photoOutput.isHighResolutionCaptureEnabled = true
        
        do {
            try updateImageDimensions(forCamera: camera)
            try camera.lockForConfiguration()
            
            // Set frame rates from UserDefaults, or use default if not set
            let defaultFrameRate: Float64 = 30.0
            let minFrameRate = userDefaults.activeVideoMinFrameRate ?? defaultFrameRate
            let maxFrameRate = userDefaults.activeVideoMaxFrameRate ?? defaultFrameRate
            
            // Validate against camera's supported frame rate ranges
            let supportedRanges = camera.activeFormat.videoSupportedFrameRateRanges
            var validMinFrameRate = minFrameRate
            var validMaxFrameRate = maxFrameRate
            
            // Find a supported range that contains our desired frame rates, or use default of 30 FPS
            var foundValidRange = false
            for range in supportedRanges {
                if minFrameRate >= range.minFrameRate && maxFrameRate <= range.maxFrameRate {
                    foundValidRange = true
                    break
                }
            }
            
            if !foundValidRange {
                // Fallback to default if no ranges available
                validMinFrameRate = defaultFrameRate
                validMaxFrameRate = defaultFrameRate
                Self.logger.warning("No supported frame rate ranges found. Using default: \(defaultFrameRate) FPS")
            }
            
            // Convert frame rates to CMTime (frame duration = 1 / frame rate)
            // Note: activeVideoMinFrameDuration = shortest duration = highest frame rate (maxFrameRate)
            //       activeVideoMaxFrameDuration = longest duration = lowest frame rate (minFrameRate)
            camera.activeVideoMinFrameDuration = CMTime(seconds: 1.0 / validMaxFrameRate, preferredTimescale: 600)
            camera.activeVideoMaxFrameDuration = CMTime(seconds: 1.0 / validMinFrameRate, preferredTimescale: 600)
            
            // Enable low light boost if user setting is enabled and device supports it
            if userDefaults.shouldTryToEnableLowLightCapture {
                if camera.isLowLightBoostSupported {
                    camera.automaticallyEnablesLowLightBoostWhenAvailable = true
                    Self.logger.info("Low light boost enabled for camera")
                } else {
                    Self.logger.info("Low light boost not supported on this device")
                }
            } else {
                // NOTE: Need this check because we can only turn low light boost on and off on specific devices
                if camera.isLowLightBoostSupported {
                    camera.automaticallyEnablesLowLightBoostWhenAvailable = false
                }
            }
            
            camera.unlockForConfiguration()
        } catch {
            ErrorLogger.log("bufferSize setting error: \(error)")
        }
        
    }
    
    /// Validates that the given frame rates are supported by the camera's active format
    /// - Parameters:
    ///   - minFrameRate: Minimum frame rate in FPS
    ///   - maxFrameRate: Maximum frame rate in FPS
    ///   - camera: The camera device to check
    /// - Returns: true if the frame rates are supported, false otherwise
    private func validateFrameRates(minFrameRate: Float64, maxFrameRate: Float64, forCamera camera: AVCaptureDevice) -> Bool {
        let supportedRanges = camera.activeFormat.videoSupportedFrameRateRanges
        
        // Check if the requested frame rates fall within any supported range
        for range in supportedRanges {
            if minFrameRate >= range.minFrameRate && maxFrameRate <= range.maxFrameRate {
                return true
            }
        }
        
        Self.logger.error("Frame rates (min: \(minFrameRate) FPS, max: \(maxFrameRate) FPS) are not supported. Supported ranges: \(supportedRanges.map { "[\($0.minFrameRate)-\($0.maxFrameRate)]" }.joined(separator: ", "))")
        return false
    }
    
    /// Sets the active video frame rate for the camera
    /// - Parameters:
    ///   - minFrameRate: Optional minimum frame rate in FPS. If provided, must be <= maxFrameRate (or existing max if maxFrameRate is nil)
    ///   - maxFrameRate: Optional maximum frame rate in FPS. If provided, must be >= minFrameRate (or existing min if minFrameRate is nil)
    /// - Returns: true if the frame rates were successfully set, false otherwise
    @discardableResult
    public func setFrameRate(minFrameRate: Float64? = nil, maxFrameRate: Float64? = nil) -> Bool {
        // Return early if neither is provided
        guard minFrameRate != nil || maxFrameRate != nil else {
            return false
        }
        
        // Get existing values from UserDefaults
        let existingMin = userDefaults.activeVideoMinFrameRate
        let existingMax = userDefaults.activeVideoMaxFrameRate
        
        // Determine the values to use
        let newMin = minFrameRate ?? existingMin
        let newMax = maxFrameRate ?? existingMax
        
        // Validate: if only one is provided, check against the other value
        if let min = newMin, let max = newMax {
            // Both values are present, ensure min <= max
            if min > max {
                Self.logger.error("Invalid frame rate: minFrameRate (\(min) FPS) must be <= maxFrameRate (\(max) FPS)")
                return false
            }
        } else if let min = newMin, let max = existingMax {
            // Only min provided, check against existing max
            if min > max {
                Self.logger.error("Invalid frame rate: minFrameRate (\(min) FPS) must be <= existing maxFrameRate (\(max) FPS)")
                return false
            }
        } else if let min = existingMin, let max = newMax {
            // Only max provided, check against existing min
            if min > max {
                Self.logger.error("Invalid frame rate: existing minFrameRate (\(min) FPS) must be <= maxFrameRate (\(max) FPS)")
                return false
            }
        }
        
        // Save to UserDefaults
        if let min = minFrameRate {
            userDefaults.activeVideoMinFrameRate = min
        }
        if let max = maxFrameRate {
            userDefaults.activeVideoMaxFrameRate = max
        }
        
        // Apply to camera if it's configured and we have a device
        guard let camera = currentDevice, let finalMin = newMin, let finalMax = newMax else {
            return true // Saved to UserDefaults, will apply when camera is configured
        }
        
        // Validate against camera's supported frame rate ranges
        guard validateFrameRates(minFrameRate: finalMin, maxFrameRate: finalMax, forCamera: camera) else {
            return false
        }
        
        // Convert frame rates to CMTime (frame duration = 1 / frame rate)
        // Note: activeVideoMinFrameDuration = shortest duration = highest frame rate (maxFrameRate)
        //       activeVideoMaxFrameDuration = longest duration = lowest frame rate (minFrameRate)
        let minFrameDuration = CMTime(seconds: 1.0 / finalMax, preferredTimescale: 600)
        let maxFrameDuration = CMTime(seconds: 1.0 / finalMin, preferredTimescale: 600)
        
        if getStatus() == .running || getStatus() == .configured {
            sessionQueue.async {
                do {
                    try camera.lockForConfiguration()
                    camera.activeVideoMinFrameDuration = minFrameDuration
                    camera.activeVideoMaxFrameDuration = maxFrameDuration
                    camera.unlockForConfiguration()
                    Self.logger.info("Successfully set frame rates: min=\(finalMin) FPS, max=\(finalMax) FPS")
                } catch {
                    Self.logger.error("Failed to set frame rate: \(error.localizedDescription)")
                }
            }
        }
        
        return true
    }
    
    internal func activeCaptureDevice() -> AVCaptureDevice? {
        guard let cameraDevice = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            return nil
        }
        
        return cameraDevice
    }
    
    private func configureCaptureDevice() -> AVCaptureDevice? {
        
        guard let cameraDevice = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            set(error: .cameraUnavailable)
            setStatus(.failed)
            return nil
        }
        
        do {
            let cameraInput = try AVCaptureDeviceInput(device: cameraDevice)
            guard session.canAddInput(cameraInput) == true else {
                set(error: .cannotAddInput)
                setStatus(.failed)
                return nil
            }
            
            session.addInput(cameraInput)
            
            return cameraDevice
        } catch {
            set(error: .createCaptureInput(error))
            setStatus(.failed)
            return nil
        }
    }
    
    internal func set(error: CameraError?) {
        DispatchQueue.main.async {
            self.error = error
        }
    }
    
    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { authorized in
                if !authorized {
                    self.setStatus(.unauthorized)
                    self.set(error: .deniedAuthorization)
                }
                self.sessionQueue.resume()
            }
        case .restricted:
            setStatus(.unauthorized)
            set(error: .restrictedAuthorization)
        case .denied:
            setStatus(.unauthorized)
            set(error: .deniedAuthorization)
        case .authorized:
            break
        @unknown default:
            setStatus(.unauthorized)
            set(error: .unknownAuthorization)
        }
    }
    
    private func setStatus(_ status: Status) {
        statusSemaphore.wait()
        defer {
            statusSemaphore.signal()
        }
        self.status = status
    }
    
    private func getStatus() -> Status {
        statusSemaphore.wait()
        defer {
            statusSemaphore.signal()
        }
        return self.status
    }
    
    /**
     Captures a photo using the configured capture session and outputs the result to the designated AVCapturePhotoCaptureDelegate.
     
     This function captures a photo using the camera's configured capture session. It first checks whether the camera session is in the running state, and if not, it sets an error indicating that the camera is unavailable. If the session is running, the function asynchronously configures and captures a photo using AVCapturePhotoSettings.
     
     The function performs the following steps:
     1. Checks if the camera session is in the running state. If not, it sets an error indicating that the camera is unavailable and exits.
     2. Asynchronously configures AVCapturePhotoSettings for the capture process.
     3. Sets properties such as high-resolution photo enablement, depth data delivery, and auto red-eye reduction.
     4. Captures a photo using the configured AVCapturePhotoOutput and delegates the capture process to the object conforming to AVCapturePhotoCaptureDelegate (usually self).
     5. Assumes that the same photo settings are reused for the next call and prepares the photo settings array accordingly.
     
     - Note: The captured photo result and delegate callbacks are handled by the object implementing AVCapturePhotoCaptureDelegate.
     
     - Precondition: The capture session must be in the running state before calling this function.
     
     - Warning: If the capture session is not running or if any errors occur during the capture process, the function sets an error and the photo capture may not occur as expected.
     */
    
    public func capturePhoto() {
        guard getStatus() == .running else {
            set(error: .cameraUnavailable)
            setStatus(.failed)
            return
        }
        
        sessionQueue.async {
            let photoSettings = AVCapturePhotoSettings()
            
            photoSettings.isHighResolutionPhotoEnabled = true
            //      photoSettings.photoQualityPrioritization = .quality
            photoSettings.isDepthDataDeliveryEnabled = self.photoOutput.isDepthDataDeliveryEnabled
            photoSettings.isAutoRedEyeReductionEnabled = false
            
            self.photoOutput.capturePhoto(with: photoSettings, delegate: self)
            
            // Assume capturePhoto reuses the same photoSettings for the next call
            self.photoOutput.setPreparedPhotoSettingsArray([photoSettings])
        }
    }
    
    /// Starts an AVCaptureSession instance running.
    /// And sets the current status to `.running`
    
    public func startSession() {
        if self.session.isRunning { return }
        self.cameraStartTime = Date()
        
        sessionQueue.async {
            self.nativeCameraTrace("SESSION start begin")
            if let device = self.currentDevice {
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = self.baselineZoom(for: device)
                    device.unlockForConfiguration()
                }
                catch{
                    print("Failed to setbaseline")
                }
                
            }
            self.session.startRunning()
            if let device = self.currentDevice {
                self.traceNativeCameraSettings("SESSION running", for: device)
            }
            
            DispatchQueue.main.async {
                self.onCameraSwitch?()
            }
            self.setStatus(.running)
        }
    }
    
    private func wireSessionNotifications() {
        guard !notificationsWired else { return }
        notificationsWired = true
        
        ////         Extra check if needed
        //        NotificationCenter.default.addObserver(
        //            self,
        //            selector: #selector(sessionDidStartRunning),
        //            name: .AVCaptureSessionDidStartRunning,
        //            object: session
        //        )
        //
        ////         Extra check if needed
        //        NotificationCenter.default.addObserver(
        //            self,
        //            selector: #selector(sessionInterruptionEnded),
        //            name: .AVCaptureSessionInterruptionEnded,
        //            object: session
        //        )
    }
    
    
    ////     Extra check if needed
    //    @objc private func sessionDidStartRunning() {
    //
    //        if pendingReenableTorch && wantsTorchOnAfterResume  {
    //            reenableTorchWithBackoff()
    //            pendingReenableTorch = false
    //        }
    //    }
    //
    ////     Extra check if needed
    //    @objc private func sessionInterruptionEnded() {
    //        resetTorchIfNeeded(delay: 1, retries: 2)
    //    }
    
    
    private func wireAppLifeCycleNotifications() {
        guard !appLifecycleWired else { return }
        appLifecycleWired = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecameActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }
    
    
    @objc private func appWillResignActive() {
        wantsTorchOnAfterResume = torchEnabled
        if torchEnabled {
            try? toggleTorch(.off)
        }
    }
    
    @objc func appDidBecameActive() {
        guard wantsTorchOnAfterResume else { return }
        if status == .running {
            reenableTorchWithBackoff()
        }
        else {
            pendingReenableTorch = true
        }
    }
    
    private func reenableTorchWithBackoff(delay: TimeInterval = 1, retries:Int = 2) {
        resetTorchIfNeeded(delay: delay, retries: retries)
        wantsTorchOnAfterResume = false
    }
    
    private func reenableTorchAfterLensSwitch(){
        if status == .running {
            try? toggleTorch(.on)
        } else {
            pendingReenableTorch = true
        }
        wantsTorchOnAfterLensSwitch = false
    }
    
    public func resetTorchIfNeeded(delay: TimeInterval = 1, retries:Int = 2) {
        func attempt(_ remaining: Int) {
            sessionQueue.asyncAfter(deadline: .now() + (remaining == retries ? delay: 0)) { [weak self] in
                
                guard let self = self else {return}
                
                try? toggleTorch(.on)
                
                guard self.status == .running,
                      self.torchEnabled else {return}
                
                let device = self.currentDevice ?? self.captureDeviceById(with: self.cameraPreferences.captureDeviceId)
                guard let dev = device, dev.hasTorch else {return}
                
                do {
                    try dev.lockForConfiguration()
                    defer {dev.unlockForConfiguration()}
                    
                    if dev.torchMode != .on {
                        
                        if dev.isTorchModeSupported(.on) {
                            try dev.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                            
                        } else {
                            dev.torchMode = .on
                        }
                    }
                }
                catch {
                    print("Torch restart failed: \(error)")
                }
                
                if dev.torchMode != .on, remaining > 0 {
                    attempt(remaining - 1)
                }
            }
        }
        attempt(retries)
    }
    
    /// Stops an AVCaptureSession instance running.
    /// First checks that the satus is running, otherwise it will stop early
    /// Upcon completion set the status to `.configured` which means it's ready to go
    public func stopSession() {
        guard getStatus() == .running else { return }
        imageData = nil
        let sem = DispatchSemaphore(value: 0)
        sessionQueue.async {
            self.nativeCameraTrace("SESSION stop begin")
            self.session.stopRunning()
            self.nativeCameraTrace("SESSION stopped")
            self.setStatus(.configured)
            sem.signal()
        }
        sem.wait()
    }
    
    // MARK: - Private
    internal func focus(at point: CGPoint, on device: AVCaptureDevice) {
        performCameraConfiguration {
            guard self.currentDevice?.uniqueID == device.uniqueID else { return }
            self.nativeCameraTrace("TAP focus requested, point=(\(point.x),\(point.y))")
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                // Apply options before focusMode, including on a reused device.
                if self.usesAutomaticCameraMode {
                    if device.isAutoFocusRangeRestrictionSupported {
                        device.autoFocusRangeRestriction = .none
                    }
                    if device.isSmoothAutoFocusSupported {
                        device.isSmoothAutoFocusEnabled = false
                    }
                }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    let mode: AVCaptureDevice.FocusMode = self.usesAutomaticCameraMode ? .continuousAutoFocus : .autoFocus
                    if device.isFocusModeSupported(mode) { device.focusMode = mode }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    let mode: AVCaptureDevice.ExposureMode = self.usesAutomaticCameraMode ? .continuousAutoExposure : .autoExpose
                    if device.isExposureModeSupported(mode) { device.exposureMode = mode }
                }
            } catch {
                Self.logger.error("Tap-to-focus failed: \(error.localizedDescription)")
            }
            self.traceNativeCameraSettings("TAP focus state", for: device)
            guard !self.usesAutomaticCameraMode else { return }
            self.sessionQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, !self.usesAutomaticCameraMode,
                      self.currentDevice?.uniqueID == device.uniqueID,
                      self.session.isRunning else { return }
                self.setAutoFocus(forCamera: device, enable: true)
            }
        }
    }

    func setAutoFocus(forCamera device: AVCaptureDevice, enable: Bool, focusDistance: AVCaptureDevice.AutoFocusRangeRestriction = .near) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.setAutoFocus(forCamera: device, enable: enable, focusDistance: focusDistance) }
            return
        }
        do {
            try device.lockForConfiguration()
            
            if enable || usesAutomaticCameraMode {
                // Apple requires range/smooth options before setting focusMode
                // to apply them to the next autofocus operation.
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = usesAutomaticCameraMode ? .none : focusDistance
                }
                if usesAutomaticCameraMode, device.isSmoothAutoFocusSupported {
                    device.isSmoothAutoFocusEnabled = false
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                
                // Enable continuous auto-exposure
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            } else {
                // Disable auto-focus by locking at current lens position or a default
                let currentLens = device.lensPosition
                if device.isFocusModeSupported(.locked) {
                    if device.isLockingFocusWithCustomLensPositionSupported {
                        device.setFocusModeLocked(lensPosition: currentLens)
                    } else {
                        device.focusMode = .locked
                        print("Manual focus locked (custom lens position not supported)")
                    }
                }
                
                // Optionally also lock exposure if desired
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = .none
                }
            }
            
            device.unlockForConfiguration()
            traceNativeCameraSettings("FOCUS configuration applied", for: device)
        } catch {
            print("Error configuring camera: \(error)")
        }
    }
    
    private func setuplensPosition() {
        
        $lensPosition
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] position in
                guard let self = self else { return }
                
            }
        
            .store(in: &cancellables)
        
        observeLensPosition()
    }
    
    private var lensKvoCancellables = Set<AnyCancellable>()
    
    private func observeLensPosition() {
        
        lensKvoCancellables.removeAll()
        
        guard !usesAutomaticCameraMode, cameraPreferences.isMacroMode.isOn,
              let device = currentDevice else {return}
        
        device.publisher(for: \.lensPosition, options: [.initial, .new])
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] position in
                self?.evaluateMacroSwitch(for: position)
            }
            .store(in: &lensKvoCancellables)
    }
    
    // MARK: MACRO MODE
    
    private func shouldSwitchCamera() -> Bool {
        Date().timeIntervalSince(lastLensSwitch) > 2.0
    }
    
    public func update(isMacroMode mode: CameraPreferences.MacroMode){
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(isMacroMode: mode) }
            return
        }
        cameraPreferences.isMacroMode = mode
        userDefaults.currentCameraPreferences = cameraPreferences
        guard !usesAutomaticCameraMode else {
            lensKvoCancellables.removeAll()
            lowSharpnessSince = nil
            return
        }
        
        if !mode.isOn, isUsingMacroCamera {
            switchToStandardCamera()
        }
        
        if mode.isOn {
            observeLensPosition()
        } else {
            lensKvoCancellables.removeAll()
            lowSharpnessSince = nil
        }
    }
    
    // Sharpness Detection for Close up Macro
    
    private func modelIdentifier()-> String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
    
    public func updateSharpnessScore(_ score: Double) {
        let s = max(0, score)
        
        sharpnessEMA = (sharpnessEMA == 0) ? s : (sharpnessAlpha * s + (1 - sharpnessAlpha) * sharpnessEMA)
        if sharpnessEMA < sharpnessEnterThreshold {
            if lowSharpnessSince == nil {
                lowSharpnessSince = Date()
            }
        } else {
            lowSharpnessSince = nil
        }
    }
    
    private func evaluateMacroSwitch(for position: Float) {
        
        guard !usesAutomaticCameraMode, cameraPreferences.isMacroMode.isOn else {
            return
        }
        guard !isSwitchingLens else { return }
        
        let backCameras = Self.discoverVideoCaptureDevices(position: .back)
        let hasTelephoto = backCameras.contains { $0.deviceType == .builtInTelephotoCamera }
        
        guard hasTelephoto else {
            print(" Dual Camera detected - Macro Disabled")
            return
        }
        
        let elapsed = Date().timeIntervalSince(cameraStartTime)
        guard elapsed > 2.0 else {
            
            DispatchQueue.main.async {
                self.onCameraSwitch?()
            }
            print("Skipping macro mode switch - camera not yet ready / waiting for lens to stabilize")
            return
        }
        
        let isClose = position <= closeEnterLensPos
        let isFar = position > 0.825
        let isMacro = currentDevice?.deviceType == .builtInUltraWideCamera
        
        let shouldEnterMacro = (isClose && isVeryBlur) && !isMacro
        let shouldExitMacro = (isFar && isMacro)
        
        guard currentDevice?.position == .back else {
            print("Macro Mode not allowed on Front Camera")
            return
        }
        guard shouldSwitchCamera() else { return }
        
        if shouldEnterMacro {
            print("Close Object detected - switching to Macro")
            lastLensSwitch = Date()
            switchToMacroCamera()
        } else if shouldExitMacro {
            print("Subject moved away - switching to Standard")
            lastLensSwitch = Date()
            switchToStandardCamera()
        }
        
    }
    
    private func switchToMacroCamera() {
        switchLens(useMacro: true)
    }

    private func switchToStandardCamera() {
        switchLens(useMacro: false)
    }

    private func switchLens(useMacro: Bool) {
        guard !usesAutomaticCameraMode else { return }
        // Prepare the covering view before changing inputs. Never wait for main
        // synchronously from sessionQueue: stopSession already waits on that queue.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.switchLens(useMacro: useMacro)
            }
            return
        }
        guard !isSwitchingLens, let previousDevice = currentDevice else { return }
        // Macro OFF must also restore the wide camera while the session is stopped.
        guard !useMacro || session.isRunning else { return }

        let deviceType: AVCaptureDevice.DeviceType = useMacro ? .builtInUltraWideCamera : .builtInWideAngleCamera
        guard previousDevice.deviceType != deviceType,
              let newDevice = Self.discoverVideoCaptureDevices(position: .back)
                .first(where: { $0.deviceType == deviceType }) else { return }

        let requestedZoom = useMacro
            ? previousDevice.videoZoomFactor * Self.fovMatchRatio
            : previousDevice.videoZoomFactor / Self.fovMatchRatio

        osirisMacroTrace(useMacro ? "REQUEST normal -> macro" : "REQUEST macro -> normal")
        isSwitchingLens = true
        wantsTorchOnAfterLensSwitch = torchEnabled
        if session.isRunning { onWillSwitchCamera?() }
        switchCaptureDevice(to: newDevice, replacing: previousDevice, zoomFactor: requestedZoom)
    }

    private func switchCaptureDevice(to newDevice: AVCaptureDevice,
                                     replacing previousDevice: AVCaptureDevice,
                                     zoomFactor: CGFloat) {
        osirisMacroTrace("SWAP queued: \(newDevice.deviceType.rawValue)")
        sessionQueue.async {
            osirisMacroTrace("SWAP begin")
            guard !self.usesAutomaticCameraMode,
                  self.session.isRunning || newDevice.deviceType == .builtInWideAngleCamera,
                  let oldInput = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                    .first(where: { $0.device.hasMediaType(.video) }),
                  oldInput.device.uniqueID == previousDevice.uniqueID else {
                self.finishLensSwitch(succeeded: false)
                return
            }

            let newInput: AVCaptureDeviceInput
            do {
                // Construct first, so a creation failure leaves the old camera intact.
                newInput = try AVCaptureDeviceInput(device: newDevice)
            } catch {
                osirisMacroTrace("SWAP failed: \(error.localizedDescription)")
                self.finishLensSwitch(succeeded: false)
                return
            }

            self.session.beginConfiguration()
            self.session.removeInput(oldInput)
            let installed = self.session.canAddInput(newInput)
            if installed {
                self.session.addInput(newInput)
                self.currentDevice = newDevice
                self.persistActiveDevice(newDevice)
                self.updateCameraPreferences(fromCamera: newDevice)
                self.refreshCameraSettings(forCamera: newDevice)
            } else if self.session.canAddInput(oldInput) {
                self.session.addInput(oldInput)
                osirisMacroTrace("SWAP failed; restored previous input")
            } else {
                self.currentDevice = nil
                osirisMacroTrace("SWAP failed; could not restore previous input")
            }

            osirisMacroTrace("COMMIT begin")
            self.session.commitConfiguration()
            osirisMacroTrace("COMMIT end")

            if installed {
                // Apply zoom in queue order after the input swap, without sleeping
                // or locking the camera from the main thread.
                do {
                    try newDevice.lockForConfiguration()
                    newDevice.videoZoomFactor = min(
                        max(zoomFactor, newDevice.minAvailableVideoZoomFactor),
                        newDevice.maxAvailableVideoZoomFactor
                    )
                    newDevice.unlockForConfiguration()
                    osirisMacroTrace("ZOOM applied")
                } catch {
                    osirisMacroTrace("ZOOM failed: \(error.localizedDescription)")
                }
            }
            self.finishLensSwitch(succeeded: installed)
        }
    }

    private func finishLensSwitch(succeeded: Bool) {
        DispatchQueue.main.async {
            guard !self.usesAutomaticCameraMode else {
                self.isSwitchingLens = false
                // Cancel any covering view left by an older manual request.
                self.onLensSwitchCompleted?(false)
                return
            }
            self.isUsingMacroCamera = self.currentDevice?.deviceType == .builtInUltraWideCamera
            self.isSwitchingLens = false
            self.observeLensPosition()
            let running = self.session.isRunning
            osirisMacroTrace("SWAP completed, success=\(succeeded)")
            self.onLensSwitchCompleted?(succeeded && running)
            self.onCameraSwitch?()

            if running, UIApplication.shared.applicationState == .active,
               self.wantsTorchOnAfterLensSwitch {
                self.reenableTorchAfterLensSwitch()
            } else {
                if running { try? self.toggleTorch(.off) }
                self.wantsTorchOnAfterLensSwitch = false
            }

            // Honour macro being disabled while an entry into macro was in flight.
            if succeeded, self.isUsingMacroCamera,
               !self.cameraPreferences.isMacroMode.isOn {
                self.switchToStandardCamera()
            }
        }
    }

    private func persistActiveDevice(_ device: AVCaptureDevice) {
        cameraPreferences.captureDeviceId = device.uniqueID
        userDefaults.currentCameraPreferences = cameraPreferences
    }
    
    public func toggleTorch(_ mode: CameraPreferences.Torch) throws {
        
        guard !isSwitchingLens else { return }
        
        let device = currentDevice ?? captureDeviceById(with: cameraPreferences.captureDeviceId)
        guard let captureDevice = device, captureDevice.hasTorch else { return }

        // Idempotency: if hardware is already in the desired state, skip entirely.
        let desiredMode: AVCaptureDevice.TorchMode = mode == .on ? .on : .off
        guard captureDevice.torchMode != desiredMode else {
            torchEnabled = mode == .on
            return
        }


        try captureDevice.lockForConfiguration()
        switch mode {
        case .off:
            captureDevice.torchMode = .off
        case .on:
            captureDevice.torchMode = .on
        }
        
        torchEnabled = mode == .on
        captureDevice.unlockForConfiguration()
        notifyTorchChanged(torchEnabled)
    }
    
    public func baselineZoom(for device: AVCaptureDevice) -> CGFloat {
        if usesAutomaticCameraMode {
            // Virtual-camera zoom is relative to its widest constituent. Raw 1x
            // is not necessarily the main wide camera's field of view.
            let wideZoom = Self.automaticWideZoomFactor(
                constituentTypes: device.constituentDevices.map(\.deviceType),
                switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            )
            return min(max(wideZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        }
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return 1.5 * Self.fovMatchRatio
        default: return 1.5
        }
    }

    internal static func automaticWideZoomFactor(constituentTypes: [AVCaptureDevice.DeviceType],
                                                  switchOverFactors: [CGFloat]) -> CGFloat {
        guard let wideIndex = constituentTypes.firstIndex(of: .builtInWideAngleCamera),
              wideIndex > 0, switchOverFactors.indices.contains(wideIndex - 1) else { return 1 }
        let factor = switchOverFactors[wideIndex - 1]
        return factor.isFinite && factor >= 1 ? factor : 1
    }
    
    //    Expose func reset Zoom if needed
    //    public func forceBaselineZoom() {
    //        sessionQueue.async { [weak self] in
    //            guard let self = self, let device = self.currentDevice else { return }
    //
    //            do {
    //                try device.lockForConfiguration()
    //                device.videoZoomFactor = 1.5
    //                device.unlockForConfiguration()
    //                print("[CameraManager] Reset zoom to 1.5×")
    //            } catch {
    //                print("Failed to reset zoom:", error)
    //            }
    //        }
    //    }
    
}

public extension Notification.Name {
    static let osirisTorchDidChange = Notification.Name("osirisTorchDidChange")
}
