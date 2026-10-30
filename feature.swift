//
//  OsirisCameraConfig.swift
//  Osiris
//
//  Created by Kyle McGinnis on 2/20/24.
//

import AVFoundation
import Foundation

/// Chooses who manages lens changes while scanning.
public enum OsirisCameraSwitchingMode {
    /// Keeps the existing camera selection and Osiris-managed macro switching.
    case manual

    /// Uses a rear dual-wide or triple virtual camera so iOS can select its lenses.
    /// This mode is independent of `macroModeEnabled` and the manual macro feature flag.
    /// An explicitly selected front camera is preserved. If no suitable rear virtual
    /// camera is available, the scanner falls back to the rear wide-angle camera.
    /// Uses continuous, unrestricted autofocus and automatic exposure, ISO and white
    /// balance; manual camera controls are ignored in this mode. Starts at the main
    /// wide camera's field of view instead of the legacy fixed 1.5x zoom.
    case automatic
}

/// `OsirisCameraConfig` is the Camera configuration setup for barcode scanner
public struct OsirisCameraConfig {
    
    // MARK: Properties
    
    public internal(set) var resolution: AVCaptureSession.Preset
    public internal(set) var device: AVCaptureDevice?
    public internal(set) var macroModeEnabled: Bool
    public internal(set) var autoFocusEnabled: Bool
    public internal(set) var autoISOEnabled: Bool
    public internal(set) var autoExposureEnabled: Bool
    public internal(set) var autoWhiteBalanceEnabled: Bool
    public internal(set) var manualISOValue: Float
    public internal(set) var manualExposureValue: Float
    public internal(set) var manualWhiteBalanceValue: (temperature: Float, tint: Float)
    public internal(set) var lensSwitchingMode: OsirisCameraSwitchingMode

    // MARK: Lifecycle
    
    /// `init` for OsirisCameraConfig
    /// - Parameter resolution: AVCaptureSession.Preset - resolution of camera
    /// - Parameter deviceType: AVCaptureDevice.DeviceType - capture device ( camera type ) selection, if available
    /// - Parameter lensSwitchingMode: Opt in to iOS-managed rear lens switching with `.automatic`.
    public init(resolution: AVCaptureSession.Preset = .hd1920x1080,
                device: AVCaptureDevice? = AVCaptureDevice.default(for: .video),
                macroModeEnabled: Bool = true,
                autoFocusEnabled: Bool = true,
                autoISOEnabled: Bool = true,
                autoExposureEnabled: Bool = true,
                autoWhiteBalanceEnabled: Bool = true,
                manualISOValue: Float = 0.0,
                manualExposureValue: Float = 0.0,
                manualWhiteBalanceValue: (temperature: Float, tint: Float) = (0, 0),
                lensSwitchingMode: OsirisCameraSwitchingMode = .manual
    ) {
        self.resolution = resolution
        self.device = device
        self.macroModeEnabled = macroModeEnabled
        self.autoFocusEnabled = autoFocusEnabled
        self.autoISOEnabled = autoISOEnabled
        self.autoExposureEnabled = autoExposureEnabled
        self.autoWhiteBalanceEnabled = autoWhiteBalanceEnabled
        self.manualISOValue = manualISOValue
        self.manualExposureValue = manualExposureValue
        self.manualWhiteBalanceValue = manualWhiteBalanceValue
        self.lensSwitchingMode = lensSwitchingMode
    }
    
    public var frontFacing: Bool {
        guard let currentDevice = self.device else {
            return false
        }
        
        return currentDevice.position == .front
    }
}

