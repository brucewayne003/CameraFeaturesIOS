//
//  OsirisScannerViewModel.swift
//  FirebaseCore
//
//  Created by Kyle McGinnis on 2/1/24.
//

import Combine
import Foundation
import Osiris
import OsirisBarcode
import UIKit

// swiftlint:disable:next type_body_length
public class OsirisScannerViewModel: ObservableObject {
    
    // MARK: Properties
    
    @Published private(set) var cameraStatus: CameraManager.Status = .unconfigured {
        didSet {
            Logging.log("Camera Status: \(cameraStatus.rawValue)", logLevel: .debug)
        }
    }

    var config: OsirisConfig? {
        didSet {
            subscribeToOsirisDynamicConfig()
        }
    }
        
    var cameraIsRunning: Bool {
        cameraManager.status == .running
    }
    
    var scannerIsRunning: Bool {
        decoderManager.scannerIsRunning
    }
    
    private var shouldStartCamera: Bool {
        sessionManager.shouldStartCameraSession && !cameraIsRunning
    }
    
    var title: String {
        decoderManager.barcodeDecoder.id
    }

    // To do: Make this private and clean up
    let cameraManager: CameraManager
    // To do: Only make benchmarkingManager if it's needed
    private let benchmarkingManager: ScannerBenchmarkingManager
    internal let sessionManager: ScannerSessionManager
    internal let barcodeManager: ScannerBarcodeManager
    internal let decoderManager: ScannerDecodingManager
    internal var didReceiveError: ((Error) -> Void)?
    internal var didFireEvent: ((OsirisEvent) -> Void)?
    
    private var dynamicConfigSubscription: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
        
    @Published public var fpsStatsDisplay: String = ""
    
    private var sessionStartTime = Date()
    
    // Camera (video) tracking
    private var totalFrameCount = 0
    private var lastCameraFPSCheck = Date()
    private var frameTimeStamps: [TimeInterval] = []
    
    // Decoding tracking
    private var totalDecodedFrameCount = 0
    private var decodingFrameCount = 0
    private var lastDecodingFPSCheck = Date()
    private var firstDecodingTimestamp: Date?
    private var lastDecodingTimeStamp: Date?
       
    // MARK: Public
    public func resetFrameStats() {
        sessionStartTime = Date()
        totalFrameCount = 0
        frameTimeStamps.removeAll()
        
        totalDecodedFrameCount = 0
        decodingFrameCount = 0
        
        lastCameraFPSCheck = Date()
        lastDecodingFPSCheck = Date()
        
        firstDecodingTimestamp = nil
        lastDecodingTimeStamp = nil
        
        fpsStatsDisplay = ""
    }
    
    // MARK: Lifecycle
    
    internal init(cameraManager: CameraManager = .init(),
                  benchmarkingManager: ScannerBenchmarkingManager = .init(),
                  sessionManager: ScannerSessionManager = .init(),
                  barcodeManager: ScannerBarcodeManager = .init(),
                  decoderManager: ScannerDecodingManager = .init(),
                  didReceiveError: ((Error) -> Void)? = nil,
                  didFireEvent: ((OsirisEvent) -> Void)? = nil) {
        self.cameraManager = cameraManager
        self.benchmarkingManager = benchmarkingManager
        self.sessionManager = sessionManager
        self.barcodeManager = barcodeManager
        self.decoderManager = decoderManager
        self.didReceiveError = didReceiveError
        self.didFireEvent = didFireEvent
        setupManagers()
        setupSubscriptions()
    }
    
    // MARK: Internal
    // swiftlint:disable:next function_body_length
    internal func processBuffer(_ pixelBuffer: CVImageBuffer) {
        
        totalFrameCount += 1

        let now = Date()
        let timestamp = now.timeIntervalSince1970
        frameTimeStamps.append(timestamp)
        frameTimeStamps = frameTimeStamps.filter { timestamp - $0 < 1.0 }

        // Track Camera FPS
        if now.timeIntervalSince(lastCameraFPSCheck) >= 1.0 {
            let currentCameraFPS = frameTimeStamps.count
            let elapsed = now.timeIntervalSince(sessionStartTime)
            let avgCameraFPS = elapsed > 0 ? Double(totalFrameCount) / elapsed : 0
            let elapsedSeconds = Int(elapsed)
            
            var avgActiveDecodingFPS: Double = 0
            var activeElapsedSeconds = 0
            
            if let first = firstDecodingTimestamp, let last = lastDecodingTimeStamp {
                let activeElapsed = last.timeIntervalSince(first)
                avgActiveDecodingFPS = activeElapsed > 0 ? Double(totalDecodedFrameCount) / activeElapsed : 0
                activeElapsedSeconds = Int(activeElapsed)
            }

            // Update display with latest decoding data too
            fpsStatsDisplay = """
            Zxing Camera:
            Time: \(elapsedSeconds)s
            Processed: \(totalFrameCount)
            FPS: \(currentCameraFPS) | Avg FPS: \(String(format: "%.1f", avgCameraFPS))
            
            Zxing Barcode Decoding:
            (A) Time: \(activeElapsedSeconds)s
            Total Decoded: \(totalDecodedFrameCount)
            FPS: \(decodingFrameCount) |  Avg (A) FPS: \(String(format: "%.1f", avgActiveDecodingFPS))
            Avg Total FPS: \(String(format: "%.1f", elapsed > 0 ? Double(totalDecodedFrameCount) / elapsed : 0))
            """

            lastCameraFPSCheck = now
            decodingFrameCount = 0 // reset per-second decoding counter
        }
        
        guard scannerIsRunning else {
            Logging.log("... Scanner isn't running... waiting to start scanner")
            DispatchQueue.main.asyncAfter(deadline: .now() + self.decoderManager.throttleBetweenScanAttemptsSuccess) {
                self.barcodeManager.removeBoundingBoxes()
            }
            return
        }
        
        guard decoderManager.decodingEnabled else {
            Logging.log("... Decoding not Enabled... waiting to start decoding, throttled most likely.")
            return
        }
        
        do {
            // Do we need buffersize?  Is that preventing us from decoding as quickly as Android?
            sessionManager.incrementFrameNumber()
            try decoderManager.decode(pixelBuffer,
                                      withSessionData: getSessionData(),
                                      benchmarkingManager: benchmarkingManager) { [weak self] barcodes in
                self?.didDecodeBarcodes(barcodes)
//                self?.handleDecodedBarcodes(barcodes)
            }
        } catch {
            Logging.log("failed... \(error.localizedDescription)", logLevel: .trace)
            self.didReceiveError?(error)
            self.barcodeManager.removeBoundingBoxesIfNeeded(for: [])
        }
    }
    
    private func handleDecodedBarcodes(_ barcodes: [Barcode]) {
        
        guard !barcodes.isEmpty else { return }
        barcodeManager.addBarcodesWithFeedback(barcodes)
        
        decodingFrameCount += 1
        totalDecodedFrameCount += barcodes.count
        
        let now = Date()
        if firstDecodingTimestamp == nil {
            firstDecodingTimestamp = now
        }
        
        lastDecodingTimeStamp = now
        
        switch decoderManager.scanActionType {
        case .single:
            if !barcodes.isEmpty {
                do {
                    try stopScanning()
                } catch {
                    Logging.log("Faied \(error.localizedDescription)")
                }
            }
        case .continuous:
            break
        }
    }
    
    // How to enforce this?
    internal func setCameraPreview(withSize size: CGSize?) {
        decoderManager.setOptionsCameraPreview(withSize: size)
    }
    
    internal func setReticle(withFrame frame: CGRect) {
        decoderManager.setOptionsReticle(withFrame: frame)
    }
    
    internal func startCamera() async throws {
        Logging.log(logLevel: .warning)
        guard shouldStartCamera else {
            throw OsirisScannerError.cameraSessionNotReady
        }
        sessionManager.reset()
        decoderManager.reset()
        barcodeManager.reset()
        benchmarkingManager.reset()
        cameraManager.startSession()
    }
    
    internal func stopCamera() async throws {
        Logging.log(logLevel: .warning)
        guard cameraIsRunning else {
            throw OsirisScannerError.cameraSessionHasNotStarted
        }
        cameraManager.stopSession()
        cameraManager.tearDownOutputSampleBufferDelegate()
    }
    
    internal func startScanning() throws {
        Logging.log(logLevel: .warning)
        guard !scannerIsRunning else {
            throw OsirisScannerError.scanningSessionInProgress
        }
        sessionManager.startScanningSession()
        decoderManager.scannerIsRunning = true
    }
    
    internal func stopScanning() throws {
        Logging.log(logLevel: .warning)
        guard scannerIsRunning else {
            throw OsirisScannerError.scanningSessionHasNotStarted
        }
        sessionManager.stopScanningSession()
        decoderManager.scannerIsRunning = false
        setBenchmarkingIsRunning(false)
    }
    
    internal func updateConfigAndLoadSettings(withConfig config: OsirisConfig?) {
        Logging.log(logLevel: .warning)
        updateConfig(withConfig: config)
        loadSettings()
    }
    
    internal func updateConfig(withConfig config: OsirisConfig?) {
        Logging.log(logLevel: .warning)
        self.config = config
        decoderManager.configDidUpdate(toConfig: config) { [weak self] error in
            self?.didReceiveError?(error)
        }
    }
    
    // MARK: Private
    
    private func setupManagers() {
        self.benchmarkingManager.delegate = self
        self.cameraManager.configure()
    }
    
    private func setupSubscriptions() {
      subscriptions.removeAll()

      cameraManager.$status
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] status in
          self?.setCameraStatus(toStatus: status)
        }
        .store(in: &subscriptions)

      cameraManager.$torchEnabled
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] isOn in
          self?.torchEnabled = isOn
        }
        .store(in: &subscriptions)

      getDecodingManagerMultiScanSubscription()
        .store(in: &subscriptions)

      NotificationCenter.default.addObserver(
        self,
        selector: #selector(appDidBecomeActive),
        name: UIApplication.didBecomeActiveNotification,
        object: nil
      )

      subscribeToOsirisDynamicConfig()
    }
    
    @objc private func appDidBecomeActive() {
        cameraManager.appDidBecameActive()
    }
    
    private func getDecodingManagerMultiScanSubscription() -> AnyCancellable {
        decoderManager.$multiScanEnabled
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] multiScanEnabled in
                self?.barcodeManager.multiScanEnabled = multiScanEnabled
            })
    }
    
    private func subscribeToOsirisDynamicConfig() {
        Logging.log(logLevel: .warning)
        dynamicConfigSubscription?.cancel()
        dynamicConfigSubscription = config?.$dynamicConfig
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [weak self] dynamicConfig in
            do {
                try self?.loadDynamicSettings(fromConfig: dynamicConfig)
            } catch {
                Logging.log("Failed to get updates from Osiris Dynamic Config \(error)", logLevel: .warning)
                self?.didReceiveError?(error)
            }
        })
    }
    
    private func getSessionData() -> ScannerSessionData? {
        if benchmarkingManager.isRunning {
            let startTime = self.sessionManager.benchmarkingSessionStartTime
            let frameNumber = self.sessionManager.frameNumber
            let resolution = cameraManager.getCameraResolution()
            let userName = self.config?.userID ?? "UnknownUser"
            return .init(startTime: startTime, frameNumber: frameNumber, resolution: resolution, userName: userName)
        }
        return nil
    }
    
    // MARK: Actions
    
    @Published public private(set) var torchEnabled = false
    public var torchStatePublisher: AnyPublisher<Bool, Never> {
        cameraManager.$torchEnabled.removeDuplicates().eraseToAnyPublisher()
    }
        
    private func setEnableTorch(_ enabled: Bool) throws {
        let mode: CameraPreferences.Torch = (enabled) ? .on : .off
        try cameraManager.toggleTorch(mode)
    }
        
    private func setBenchmarkingIsRunning(_ isRunning: Bool) {
        let isTurningOnBenchmarkingSession = !benchmarkingManager.isRunning && isRunning
        if isTurningOnBenchmarkingSession {
            sessionManager.startBenchmarkingSession()
        }
        benchmarkingManager.setIsRunning(isRunning)
    }
    
    private func setCameraStatus(toStatus status: CameraManager.Status) {
        guard self.cameraStatus != status else {
            Logging.log("Camera status already equal to \(status)... ignoring")
            return
        }
        self.cameraStatus = status
        if status == .running {
            self.sessionManager.startCameraSession()
        }
    }
    
    private func didDecodeBarcodes(_ barcodes: [Barcode]) {
        guard !barcodes.isEmpty else { return }
        /* Handling race condition by adding another check / guard for
          scannerIsRunning to refrain from unneccessary run if user has stopped
         scanner.
         */
        guard scannerIsRunning else { return }
        barcodeManager.addBarcodesWithFeedback(barcodes)
        
        decodingFrameCount += 1
        totalDecodedFrameCount += barcodes.count
        
        let now = Date()
        if firstDecodingTimestamp == nil {
            firstDecodingTimestamp = now
        }
        
        lastDecodingTimeStamp = now
        switch decoderManager.scanActionType {
        case .single:
            if !barcodes.isEmpty {
                do {
                    try self.stopScanning()
                    didFireEvent?(.didFreezeCameraAfterSingleScan)
                } catch {
                    Logging.log("Failed... \(error.localizedDescription)")
                }
            }
        case .continuous:
            break
        }
    }
            
    deinit {
        Logging.log("...")
    }
}

// MARK: Settings Loading
extension OsirisScannerViewModel {
    
    // MARK: Private - Loading Settings

    // TODO: Update in future to be async to check permissions for `extras` - fine for now
    private func loadSettings() {
        do {
            try self.loadCameraSettings()
            try self.loadDecoderOptions()
            try self.loadBenchmarkSettings()
            self.didFinishLoadingSettings()
        } catch {
            Logging.log("Failed! \(error)", logLevel: .warning)
            self.didReceiveError?(error)
        }
    }

    private func loadCameraSettings() throws {
        guard let cameraSettings = config?.cameraConfig else {
            throw OsirisScannerError.missingOsirisConfig
        }
        self.cameraManager.applyScannerCameraConfiguration(
            cameraSettings, enableLogging: config?.dynamicConfig.enableLogging ?? false
        )
    }

    private func loadBenchmarkSettings() throws {
        guard let extras = config?.extras else {
            throw OsirisScannerError.missingOsirisConfig
        }
        let benchmarkOutputString = (extras[OsirisBarcodeKey.benchmarkingOutputType.rawValue] as? String) ?? ""
        if let outputServiceType = BenchmarkOutputServiceType(rawValue: benchmarkOutputString) {
            benchmarkingManager.setOutputServiceType(toType: outputServiceType)
        }
        benchmarkingManager.setAllowBenchmarking(extras[OsirisBarcodeKey.allowBenchmarking.rawValue] as? Bool ?? false)
    }

    private func loadDecoderOptions() throws {
        guard let config = config else {
            throw OsirisScannerError.missingOsirisConfig
        }
        self.decoderManager.loadDecoderOptions(fromConfig: config)
        self.barcodeManager.feedbackConfig = config.feedbackConfig
    }
    
    private func didFinishLoadingSettings() {
        sessionManager.shouldStartCameraSession = true
    }
    
    internal func loadDynamicSettings(fromConfig dynamicConfig: OsirisDynamicConfig?) throws {
        Logging.log(logLevel: .warning)
        guard let dynamicConfig = dynamicConfig else {
            return
        }
        cameraManager.setNativeCameraLoggingEnabled(dynamicConfig.enableLogging)
        
        /// Camera Settings
        
        // Adding check to avoid race conditions of when screens are in transition
        // As dynamicSettings are observed they get published on every viewWillAppear
        if !sessionManager.shouldStartCameraSession && cameraIsRunning && scannerIsRunning {
            try self.setEnableTorch(dynamicConfig.enableTorch)
        }
        // This ternary condition addresses a bug where enabling benchmarking resets the zoom percentage to 1.5.
        // This reset causes the zoom button to become out of sync with the actual zoom percentage.
        // By checking if zoomState == .medium, we can infer that the zoom button has been tapped at least once.
        // If that happens, use the zoom from the actual zoomState.
        
        decoderManager.loadDynamicSettings(fromConfig: dynamicConfig)
        decoderManager.throttlingManager.setThrottleBetweenScanAttempts(0.01)
        
        /// Benchmarking
        if let benchmarkingIsRunning = dynamicConfig.extras[OsirisBarcodeKey.benchmarkingIsRunning.rawValue] as? Bool {
            setBenchmarkingIsRunning(benchmarkingIsRunning)
        }
    }
}

// MARK: ScannerBenchmarkingManagerDelegate Conformance
extension OsirisScannerViewModel: ScannerBenchmarkingManagerDelegate {
    
    func didEnableAllowBenchmarking() {
        Logging.log(logLevel: .warning)
        didFireEvent?(.didEnableAllowBenchmarking)
    }
    
    func didDisableAllowBenchmarking() {
        Logging.log(logLevel: .warning)
        didFireEvent?(.didDisableAllowBenchmarking)
    }
    
    func didFinishRunningBenchmarking() {
        Logging.log(logLevel: .warning)
        didFireEvent?(.didFinishRunningBenchmarking)
    }
    
    func didStartRunningBenchmarking() {
        Logging.log(logLevel: .warning)
        didFireEvent?(.didStartRunningBenchmarking)
    }
    
    func didStartBenchmarkExport() {
        Logging.log(logLevel: .warning)
        didFireEvent?(.didStartBenchmarkExport)
    }
    
    func didFinishBenchmarkExport(withError error: Error? = nil) {
        Logging.log(logLevel: .warning)
        didFireEvent?(.didFinishBenchmarkExport(error))
    }
}
