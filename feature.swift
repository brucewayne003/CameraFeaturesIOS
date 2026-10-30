//
//  OsirisScannerViewController.swift
//  FirebaseCore
//
//  Created by Kyle McGinnis on 2/1/24.
//

import AVFoundation
import Combine
import Foundation
import Osiris
import OsirisBarcode
import UIKit

public typealias BarcodeValue = String

/// `OsirisScannerDelegate` delegate functions for receiving of barcode values, errors, and lifecycle events
/// This needs to be set immediately after `OsirisScannerViewController` is instantiated in order to receive all events
public protocol OsirisScannerDelegate: AnyObject {
    func didTapDetectedBarcodeBoundingBox(_ barcode: Barcode, setBoundingBoxSettings: @escaping (_ settings: OsirisBoundingBoxConfig) -> Void)
    func didDetectBarcodes(_ barcodes: [Barcode], setBoundingBoxesSettings: @escaping (_ settings: [BarcodeValue: OsirisBoundingBoxConfig]) -> Void)
    func didDetectBarcode(_ barcode: Barcode)
    func didFireEvent(_ event: OsirisEvent)
    func didReceiveError(_ error: Error)
    func cameraIdleDetected()
}

/// `OsirisScannerViewController` main object to allow for camaera display and decoding of barcodes.  This needs to be initialized and added to the view hierarchy of the embedding App's controller.
/// `OsirisScannerDelegate` functions can be accessed after setting the `delegate` to allow for reading of Barcodes, accessing lifecycle events, and receiving errors.
public final class OsirisScannerViewController: UIViewController {
    
    // MARK: Public Properties
    
    var frameCounter = 0
    
    /// Delegates barcode detection, events and errors
    /// This needs to be set immediately after `OsirisScannerViewController` is instantiated in order to receive all events
    public weak var delegate: OsirisScannerDelegate? {
        didSet {
            delegateDidUpdate()
        }
    }
    
    /// The name of the current decoder in use by the scanner
    public var decoderID: String {
        // Are we going to expose this?  Are we ok with that?
        viewModel.title
    }
    
    /// Property indicating whether the camera is running, displaying and allow frames to be accessible from the scanner
    public var cameraIsRunning: Bool {
        viewModel.cameraIsRunning
    }
    
    /// Property indicating whether the scanner is running ( attempting to decode barcodes )
    public var scannerIsRunning: Bool {
        viewModel.scannerIsRunning
    }
    
    public func setMacroModeEnabled(_ enabled: Bool){
        // This API controls only Osiris's legacy manual algorithm. Automatic
        // lens selection is chosen through OsirisCameraConfig.lensSwitchingMode.
        viewModel.cameraManager.update(isMacroMode: enabled ? .on : .off)
    }
    
    public var isMacroModeEnabled: Bool {
        viewModel.cameraManager.cameraPreferences.isMacroMode.isOn
    }
    
    public var cameraIdleTimeout: TimeInterval?
    
    // MARK: Internal Properties
    
    let context: OsirisDataCaptureContext
    public let viewModel: OsirisScannerViewModel = .init()
    
    var emptyFrameDetectedTime: TimeInterval?
    var idleCameraSessionTimer: Timer?
    
    var config: OsirisConfig? {
        OsirisApp.shared.getConfig(forContext: context)
    }
    
    public var scannerView: OsirisScannerView? {
        self.view as? OsirisScannerView
    }
    
    public func updateVPNEM(_ message: String?){
        scannerView?.setVPNErrorMessage(message)
    }
    
    var pixelBufferSize: CGSize?
    var boundingBoxSettings: [BarcodeValue: OsirisBoundingBoxConfig] = [:]
    
    var subscriptions: Set<AnyCancellable> = []

    // MARK: Blur Overlay

    private var blurOverlayView: UIVisualEffectView?
    
    // MARK: Lifecycle
    
    public init(context: OsirisDataCaptureContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private var freezeOverlay: UIView?
    private var macroFreezeTimeout: DispatchWorkItem?
    private var awaitingLensSwitchCompletion = false
    private let macroFrameLock = NSLock()
    private var macroTransitionID = UUID()
    private var waitingForFrameAfterSwap = false
    private let framesToSkipAfterSwap = 3
    private var postSwapFrameCount = 0
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        setupViews()
        scannerView?.applyAppearance(config?.scannerAppearance ?? .init())
        setupSubscriptions()
        
        if let scannerView = scannerView {
            scannerView.cameraManager = viewModel.cameraManager
        }
        
        viewModel.cameraManager.onWillSwitchCamera = { [weak self] in
            guard self?.viewModel.cameraManager.usesAutomaticCameraMode == false else { return }
            self?.freezePreview()
        }

        viewModel.cameraManager.onLensSwitchCompleted = { [weak self] succeeded in
            guard let self = self, self.awaitingLensSwitchCompletion,
                  self.freezeOverlay != nil else { return }
            self.awaitingLensSwitchCompletion = false
            guard succeeded else {
                self.clearMacroPreviewTransition()
                return
            }
            // Only begin the settling-frame heuristic after the swap and zoom finish.
            self.macroFrameLock.lock()
            self.postSwapFrameCount = 0
            self.waitingForFrameAfterSwap = true
            self.macroFrameLock.unlock()
            osirisMacroTrace("WAIT for post-switch callbacks")
        }
        
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        scannerView?.resetZoomToggleState()
        
        // Macro mode is now gated by OsirisFlags.macroModeEnabled in loadCameraSettings().
        // Do not force-disable here — the feature flag is the single source of truth.
    }
    
    private func freezePreview() {
        clearMacroPreviewTransition()
        guard let container = scannerView?.videoContainerView else { return }
        osirisMacroTrace("FREEZE begin")

        guard let overlay = container.snapshotView(afterScreenUpdates: false) else {
            osirisMacroTrace("FREEZE skipped; snapshot unavailable")
            return
        }
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        container.addSubview(overlay)

        // The snapshot covers the change; leave the preview connection running.
        freezeOverlay = overlay
        awaitingLensSwitchCompletion = true
        osirisMacroTrace("FREEZE ready")

        // A stopped/interrupted camera must not leave a still image covering the UI.
        let timeout = DispatchWorkItem { [weak self, weak overlay] in
            guard let self = self, let overlay = overlay,
                  self.freezeOverlay === overlay else { return }
            osirisMacroTrace("FREEZE timeout; revealing preview")
            self.unfreezePreview()
        }
        macroFreezeTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)
    }
    
    private func unfreezePreview() {
        guard let overlay = freezeOverlay else { return }
        macroFreezeTimeout?.cancel()
        macroFreezeTimeout = nil
        awaitingLensSwitchCompletion = false
        cancelMacroFrameWait()
        osirisMacroTrace("UNFREEZE begin")
        
        UIView.animate(withDuration: 0.1, animations: {
            overlay.alpha = 0
        }) { [weak self] finished in
            overlay.removeFromSuperview()
            if self?.freezeOverlay === overlay {
                self?.freezeOverlay = nil
            }
            osirisMacroTrace("FADE end, completed=\(finished)")
        }
    }

    private func cancelMacroFrameWait() {
        macroFrameLock.lock()
        waitingForFrameAfterSwap = false
        postSwapFrameCount = 0
        macroTransitionID = UUID()
        macroFrameLock.unlock()
    }

    private func clearMacroPreviewTransition() {
        macroFreezeTimeout?.cancel()
        macroFreezeTimeout = nil
        awaitingLensSwitchCompletion = false
        cancelMacroFrameWait()
        let overlay = freezeOverlay
        freezeOverlay = nil
        overlay?.layer.removeAllAnimations()
        overlay?.removeFromSuperview()
    }
    
    private func centerROISharpness(from pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)}
        
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        let roiW = width / 4
        let roiH = height / 4
        let startX = (width - roiW) / 2
        let startY = (height - roiH) / 2
        
        let step = 2
        let gw = roiW / step
        let gh = roiH / step
        
        if gw < 3 || gh < 3 {return 0}
        
        var gray = Array(repeating: UInt8(0), count: gw * gh)
        
        var gy = 0
        var y = startY
        while y < startY + roiH {
            var gx = 0
            var x = startX
            while x < startX + roiW {
                let off = y * bpr + x * 4
                let b = Double(base[off + 0])
                let g = Double(base[off + 1])
                let r = Double(base[off + 2])
                
                let l = UInt8(min(255, max(0, Int(0.114*b + 0.587*g + 0.299*r))))
                gray[gy * gw + gx] = 1
                gx += 1
                x += step
            }
            gy += 1
            y += step
            
        }
        
        var sum: Double = 0
          var count = 0
          for j in 1..<(gh-1) {
            for i in 1..<(gw-1) {
              let tl = Int(gray[(j-1)*gw + (i-1)]),  t = Int(gray[(j-1)*gw + i]),    tr = Int(gray[(j-1)*gw + (i+1)])
              let l  = Int(gray[j*gw + (i-1)]),      _c = Int(gray[j*gw + i]),       r  = Int(gray[j*gw + (i+1)])
              let bl = Int(gray[(j+1)*gw + (i-1)]),  b = Int(gray[(j+1)*gw + i]),    br = Int(gray[(j+1)*gw + (i+1)])

              let gx = (-tl + tr) + (-2*l + 2*r) + (-bl + br)
              let gy = (-tl - 2*t - tr) + (bl + 2*b + br)
              sum += Double(gx*gx + gy*gy)
              count += 1
            }
          }
          if count == 0 { return 0 }
          // average gradient energy = "sharpness". Low = blurred.
          return sum / Double(count)
    }
    
    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCamera()
        
    }
    
    // MARK: Public API
    
    /// `startCamera` starts the camera and begins displaying frames in the scanner view.  This also loads all settings configured in the OsirisApp for the OsirisDataCaptureContext associated with this scanner.
    /// Make sure `OsirisApp.configure` is called before attempting to run the camera
    public func startCamera() {
        Logging.log("cameraIsRunning \(cameraIsRunning)", logLevel: .warning)
        clearMacroPreviewTransition()
        scannerView?.applyAppearance(config?.scannerAppearance ?? .init())
        
        cancelIdleCameraSessionTimer()

        // Show blur overlay when starting camera to hide jerky frame transitions
        showBlurOverlay()
        
        self.viewModel.updateConfigAndLoadSettings(withConfig: config)
    }
    
    /// `stopCamera` stops the camera from processing or displaying more frames - this will freeze the current frame.  This automatically stops scanning if it is currently active.
    public func stopCamera() {
        Logging.log("cameraIsRunning \(cameraIsRunning)", logLevel: .warning)
        clearMacroPreviewTransition()
        
        stopScanning()
        
        Task { [ weak self ] in
            try await self?.stopCameraSession()
        }
    }
    
    /// `startScanning` starts the barcode decoder and begins processing and scanning the frames from the camera.  If the camera isn't currently running, this will start the camera automatically.
    public func startScanning() {
        Logging.log("isScanning \(scannerIsRunning)", logLevel: .warning)
        
        cancelIdleCameraSessionTimer()
        
        do {
            try self.viewModel.startScanning()
            delegate?.didFireEvent(.didStartScanning)
            if !self.cameraIsRunning {
                self.startCamera()
            }
        } catch {
            Logging.log("Failed... \(error.localizedDescription)", logLevel: .warning)
        }
    }
    
    /// `stopScanning` stops the barcode decoder and ignores scanning barcodes from any frames coming in from the camera.
    /// The active camera still runs when scanning is stopped - only no barcode decoding is attempted.
    public func stopScanning() {
        Logging.log("isScanning \(scannerIsRunning)", logLevel: .warning)
        do {
            try self.viewModel.stopScanning()
            delegate?.didFireEvent(.didFinishScanning)
        } catch {
            Logging.log("Failed... \(error.localizedDescription)", logLevel: .warning)
        }
    }
    
    // MARK: Private Helpers

    private func showBlurOverlay() {
        guard blurOverlayView == nil else { return }
        let blurEffect = UIBlurEffect(style: .light)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurView.alpha = 1.0

        view.addSubview(blurView)
        self.blurOverlayView = blurView
    }

    private func hideBlurOverlayWithAnimation() {
        guard let blurView = blurOverlayView else { return }

        UIView.animate(withDuration: 0.2, animations: {
            blurView.alpha = 0.0
        }) { _ in
            blurView.removeFromSuperview()
            self.blurOverlayView = nil
        }
    }
    
    private func cancelIdleCameraSessionTimer() {
        idleCameraSessionTimer?.invalidate()
        idleCameraSessionTimer = nil
    }
    
    private func setupViews() {
        let oScannerView = OsirisScannerView(frame: view.bounds, context: context)
        self.view = oScannerView
        oScannerView.videoPreviewLayer = AVCaptureVideoPreviewLayer(session: viewModel.cameraManager.session)
        oScannerView.captureDevice = viewModel.cameraManager.currentDevice
        oScannerView.didTapToFocus = { [weak self] touchPoint in
            guard let self = self else {
                return
            }
            
            let isFocusEnabled = UserDefaults.standard.currentCameraPreferences.isAutoFocus.isOn
            
            if isFocusEnabled {
                self.focus(at: touchPoint)
            }
        }
        oScannerView.isRecordingDidUpdate = { [weak self] isRecording in
            guard let config = self?.config else {
                Logging.log("Missing config...", logLevel: .warning)
                return
            }
            guard let context = self?.context else {
                Logging.log("Missing context...", logLevel: .warning)
                return
            }
            var extras = config.dynamicConfig.extras
            extras[OsirisBarcodeKey.benchmarkingIsRunning.rawValue] = isRecording
            do {
                try OsirisApp.setDynamicExtras(extras, context: context)
            } catch {
                Logging.log("Failed! ... \(error.localizedDescription)", logLevel: .warning)
            }
        }
    }
    
    private func setupSubscriptions() {
        subscriptions = [
            getCameraStatusSubscription(),
            getBarcodeSubscription(),
            getBarcodeBoundingBoxSubscription(),
            getReticleEnabledSubscription(),
            getFpsStatsEnabledSubscription()
            
        ]
        
        if let tapSubscription = getBarcodeBoundingBoxTappedSubscription() {
            subscriptions.insert(tapSubscription)
        }
        
        setupOsirisConfigSubscription()
        
        viewModel.cameraManager
            .$currentDevice
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (device: AVCaptureDevice) in
                guard let self = self else { return }
                self.scannerView?.captureDevice = device
                let isMacro = (device.deviceType == .builtInUltraWideCamera)
                self.scannerView?.isMacroMode = isMacro
                self.scannerView?.baseZoomFactor = self.viewModel.cameraManager.baselineZoom(for: device)
            }
            .store(in: &subscriptions)
        
        viewModel.$fpsStatsDisplay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                
                self?.scannerView?.fpsStatsLabel.text = text
            }
            .store(in: &subscriptions)
    }
    
    @MainActor
    private func startCameraSession() async throws {
        do {
            try await self.viewModel.startCamera()
            delegate?.didFireEvent(.didStartCamera)
            Logging.log("cameraIsRunning \(cameraIsRunning)", logLevel: .warning)
        } catch {
            didReceiveError(error)
            throw error
        }
    }
    
    @MainActor
    private func stopCameraSession() async throws {
        do {
            try await self.viewModel.stopCamera()
//            try OsirisApp.setEnableTorch(false, context: context)
            delegate?.didFireEvent(.didShutDownCamera)
            Logging.log("cameraIsRunning \(cameraIsRunning)", logLevel: .warning)
        } catch {
            didReceiveError(error)
            throw error
        }
    }
    
    private func cameraStatusDidUpdate(toStatus status: CameraManager.Status) {
        switch status {
        case .configured:
            Task { [weak self] in
                try await self?.startCameraSession()
            }
        case .running:
            let cameraManager: CameraManager = self.viewModel.cameraManager
            if let scannerView = self.scannerView {
                self.viewModel.setCameraPreview(withSize: scannerView.videoPreviewLayer?.bounds.size)
                let frame = scannerView.reticle.frame
                self.viewModel.setReticle(withFrame: frame)
            }
            
            // Camera status events can fire during teardown re-initialization, briefly turning on
            // the torch after/when in transition. Delaying dynamic settings application avoids
            // redundant call. As blur animation is of 0.2 seconds we are adding 0.3 to finish transition.
            // Increasing 0.3 to 0.5 as low performant devices need more time.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self,
                      self.viewIfLoaded?.window != nil else { return }
                try? self.viewModel.loadDynamicSettings(fromConfig: self.config?.dynamicConfig)
            }
            cameraManager.setOutputSampleBufferDelegate(to: self, queue: nil)
            
            // Hide blur overlay with animation when camera is running
            hideBlurOverlayWithAnimation()
        case .unconfigured:
            break
        default:
            break
        }
    }
    
    private func delegateDidUpdate() {
        viewModel.didReceiveError = { [weak self] error in
            DispatchQueue.main.async {
                self?.didReceiveError(error)
            }
        }
        viewModel.didFireEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.processEvent(event)
            }
        }
    }
    
    // MARK: Events
    
    private func processEvent(_ event: OsirisEvent) {
        Logging.log("...Forwarding to OsirisScannerDelegate: \(event)", logLevel: .warning)
        switch event {
        case .didStartBenchmarkExport:
            self.delegate?.didFireEvent(.didStartBenchmarkExport)
        case .didFinishBenchmarkExport(let error):
            self.delegate?.didFireEvent(.didFinishBenchmarkExport(error))
            self.scannerView?.isRecording = false
        case .didStartScanning:
            self.delegate?.didFireEvent(.didStartScanning)
        case .didFinishScanning:
            self.delegate?.didFireEvent(.didFinishScanning)
        case .didStartRunningBenchmarking:
            self.delegate?.didFireEvent(.didStartRunningBenchmarking)
        case .didFinishRunningBenchmarking:
            self.delegate?.didFireEvent(.didFinishRunningBenchmarking)
        case .didEnableAllowBenchmarking:
            self.delegate?.didFireEvent(.didEnableAllowBenchmarking)
            self.scannerView?.showRecordingButton = true
        case .didDisableAllowBenchmarking:
            self.delegate?.didFireEvent(.didDisableAllowBenchmarking)
            self.scannerView?.showRecordingButton = false
        case .didStartCamera:
            self.delegate?.didFireEvent(.didStartCamera)
        case .didShutDownCamera:
            self.delegate?.didFireEvent(.didShutDownCamera)
        case .didFreezeCameraAfterSingleScan:
            guard viewModel.decoderManager.scanActionType == .single else {
                return
            }
            self.delegate?.didFireEvent(.didFreezeCameraAfterSingleScan)
        }
    }
    
    private func focus(at point: CGPoint) {
        
        guard let device = viewModel.cameraManager.activeCaptureDevice(),
              let scannerView = scannerView,
              let previewLayer = scannerView.videoPreviewLayer else {
            return
        }
        
        scannerView.showFocusSquare(at: point)
        
        let focusPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        
        viewModel.cameraManager.focus(at: focusPoint, on: device)
    }
    
    // MARK: Error Handling
    
    private func didReceiveError(_ error: Error) {
        var logLevel: LoggingLevel = .trace
        switch error {
        case let error as OsirisBarcodeError:
            switch error {
            case .barcodeNotFound:
                break
            default:
                logLevel = .warning
            }
        case let error as OsirisScannerError:
            switch error {
            case .cameraSessionNotReady, .cameraSessionHasNotStarted:
                break
            case .decodingNotReady:
                break
            default:
                logLevel = .warning
            }
        default:
            logLevel = .warning
        }
        if logLevel == .warning {
            delegate?.didReceiveError(error)
        }
        Logging.log("... Error: \(error.localizedDescription)", logLevel: logLevel)
    }
    
    // MARK: Deinit
    
    deinit {
        Logging.log("...")
        NotificationCenter.default.removeObserver(self)
    }
    
}

// MARK: Subscriptions
extension OsirisScannerViewController {
    
    // MARK: Private Subscriptions
    
    private func getCameraStatusSubscription() -> AnyCancellable {
        viewModel.$cameraStatus.removeDuplicates()
            .combineLatest(viewModel.sessionManager.$shouldStartCameraSession.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, _ in
                self?.cameraStatusDidUpdate(toStatus: status)
            }
        
    }
    
    private func getBarcodeSubscription() -> AnyCancellable {
        viewModel.barcodeManager.$barcodes
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] barcodes in
                if let barcode = barcodes.last {
                    self?.delegate?.didDetectBarcode(barcode)
                    self?.scannerView?.reticle.toggleReticleColor()
                }
            })
    }
    
    private func getBarcodeBoundingBoxTappedSubscription() -> AnyCancellable? {
        scannerView?.boundingBoxes.$foundBarcodeBox
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] foundBarcodeBox in
                guard let self, let foundBarcodeBox else {
                    return
                }
                
                let selectedBarcode = foundBarcodeBox.barcode
                self.delegate?.didTapDetectedBarcodeBoundingBox(selectedBarcode, setBoundingBoxSettings: { settings in
                    self.boundingBoxSettings[selectedBarcode.value] = settings
                    self.scannerView?.boundingBoxes.updateBarcodes(self.viewModel.barcodeManager.barcodeBoundingBoxes, customSettings: self.boundingBoxSettings)
                })
            })
    }
    
    private func getBarcodeBoundingBoxSubscription() -> AnyCancellable {
        viewModel.barcodeManager.$barcodeBoundingBoxes
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] barcodeBoundingBoxes in
                for box in barcodeBoundingBoxes {
                    guard let previewLayer = self?.scannerView?.videoPreviewLayer,
                          let pixelBufferSize = self?.pixelBufferSize,
                          !box.barcode.quadPoints.isEmpty else
                    {
                        self?.scannerView?.boundingBoxes.resetQuadPoints()
                        continue
                    }
                    
                    if !box.barcode.quadPoints.isEmpty {
                        self?.scannerView?.boundingBoxes.registerQuadPoints(
                            forBarcodeValue: box.barcode.value,
                            pixelBufferPoints: box.barcode.quadPoints,
                            previewLayer: previewLayer,
                            videoOrientation: previewLayer.connection?.videoOrientation ?? .portrait,
                            isMirrored: false, // Should handle front camera mirroring
                            pixelBufferSize: pixelBufferSize,
                            videoZoomFactor: 1.0 // To-be supported..
                        )
                    } else {
                        self?.scannerView?.boundingBoxes.resetQuadPoints()
                    }
                }
                
                // Draw Default Bounding Boxes
                self?.scannerView?.boundingBoxes.updateBarcodes(barcodeBoundingBoxes, customSettings: self?.boundingBoxSettings ?? [:])
                self?.delegate?.didDetectBarcodes(barcodeBoundingBoxes.map(\.barcode), setBoundingBoxesSettings: { settings in
                    // Re-draw customized boxes
                    // 1. Merging new settings into existing settings
                    for (key, newValue) in settings {
                        // Update or insert the key-value pair
                        self?.boundingBoxSettings[key] = newValue
                    }
                    
                    // 2. Pass down `boundingBoxSettings` to bounding boxes manager to draw using the given settings.
                    self?.scannerView?.boundingBoxes.updateBarcodes(barcodeBoundingBoxes, customSettings: self?.boundingBoxSettings ?? [:])
                })
            })
    }
    
    private func getReticleEnabledSubscription() -> AnyCancellable {
        viewModel.decoderManager.$reticleEnabled
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] isEnabled in
                self?.scannerView?.reticle(shouldHide: !isEnabled)
            })
    }
    
    // to subscribe fpsStats enablement status
    private func getFpsStatsEnabledSubscription() -> AnyCancellable {
        viewModel.decoderManager.$fpsStatsEnabled
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] isEnabled in
                self?.scannerView?.fpsStats(shouldHide: !isEnabled)
            })
    }
    
    private func setupOsirisConfigSubscription() {
        NotificationCenter.default.publisher(for: .osirisConfigDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    do {
                        try await self?.stopCameraSession()
                        self?.startCamera()
                        Logging.log("Success... did start camera session", logLevel: .warning)
                    } catch {
                        Logging.log("Failed... \(error)", logLevel: .warning)
                        Logging.log("Updating Config anyway...", logLevel: .warning)
                        self?.viewModel.updateConfig(withConfig: self?.config)
                    }
                }
            }
            .store(in: &subscriptions)
    }
}

extension OsirisScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    private func checkIdleState(_ firstEmptyScan: TimeInterval) {
        if isCameraIdle(firstEmptyScan) {
            delegate?.cameraIdleDetected()
        }
    }
    
    private func isCameraIdle(_ firstEmptyScan: TimeInterval) -> Bool {
        guard let cameraIdleTimeout = cameraIdleTimeout else {
            return false
        }
        
        let currentTime = Date().timeIntervalSince1970 * 1000
        return (currentTime - firstEmptyScan) > (cameraIdleTimeout * 1000)
    }
    
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let callbackStart = ProcessInfo.processInfo.systemUptime
        var tracedFrame: Int? = nil

        defer {
            if let number = tracedFrame {
                let ms = Int(
                    (ProcessInfo.processInfo.systemUptime - callbackStart) * 1_000
                )
                osirisMacroTrace("CALLBACK \(number) finished, work_ms=\(ms)")
            }
        }
        
        macroFrameLock.lock()
        let transitionID = macroTransitionID
        var shouldUnfreeze = false
        if waitingForFrameAfterSwap {
            postSwapFrameCount += 1
            tracedFrame = postSwapFrameCount
            if postSwapFrameCount >= framesToSkipAfterSwap {
                waitingForFrameAfterSwap = false
                shouldUnfreeze = true
            }
        }
        macroFrameLock.unlock()

        if let number = tracedFrame {
            osirisMacroTrace("CALLBACK \(number) received")
        }
        if shouldUnfreeze {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.macroFrameLock.lock()
                let isCurrentTransition = self.macroTransitionID == transitionID
                self.macroFrameLock.unlock()
                if isCurrentTransition {
                    self.unfreezePreview()
                }
            }
        }
        
        if viewModel.scannerIsRunning && !viewModel.barcodeManager.barcodes.isEmpty {
            emptyFrameDetectedTime = nil
        } else {
            if emptyFrameDetectedTime == nil {
                emptyFrameDetectedTime = Date().timeIntervalSince1970 * 1000
            } else if let emptyFrameDetectedTime = emptyFrameDetectedTime {
                checkIdleState(emptyFrameDetectedTime)
            }
        }
        
        if let captureDevice = viewModel.cameraManager.activeCaptureDevice() {
            viewModel.decoderManager.currentCaptureDevice = captureDevice
        }
        
        if !viewModel.cameraManager.usesAutomaticCameraMode,
           let pb = CMSampleBufferGetImageBuffer(sampleBuffer){
            let s = centerROISharpness(from: pb)
            viewModel.cameraManager.updateSharpnessScore(s)
            
            frameCounter += 1
            if frameCounter % 10 == 0{
                let sharp = viewModel.cameraManager.sharpnessSmoothed
                let pos = viewModel.cameraManager.currentDevice?.lensPosition ?? -1
                let usingUW = (viewModel.cameraManager.currentDevice?.deviceType == .builtInUltraWideCamera)
//
//                print(String(format: "[CAL] sharp≈%.1f  lensPos=%.3f  lens=%@",
//                                 sharp, pos, usingUW ? "UltraWide" : "Wide"))
                
            }
        }
        
        viewModel.processBuffer(pixelBuffer)
    }
}
