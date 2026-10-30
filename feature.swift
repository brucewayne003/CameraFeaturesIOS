//
//  CameraManager+CameraFeatures.swift
//  OsirisCamera
//
//  Created by Joe Newbry on 7/19/24.
//

import AVFoundation

extension CameraManager {
    
    /// This function allows clients to discover devices that contain the following types: wide angle, ultra wide, telephoto
    public static func discoverVideoCaptureDevices(position: AVCaptureDevice.Position = .unspecified) -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            // Determine usability of these?
            .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera
            // Add optional support for continuity camera: .continuityCamera?
        ]
        
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: position)
        
        return session.devices
    }
    
    /// Returns the device instance that matches the id
    /// If not devices are found return nil
    ///  - Parameters:
    ///   - uniqueID: device id we want to try and match
    public func captureDeviceById(with uniqueID: String) -> AVCaptureDevice? {
        let devices = Self.discoverVideoCaptureDevices()
        
        return devices.first { $0.uniqueID == uniqueID }
    }
    
    public func getCameraResolution() -> String? {
        self.session.sessionPreset.userFriendlyName
    }
    
    public func setCameraResolution(to sessionPreset: AVCaptureSession.Preset) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.setCameraResolution(to: sessionPreset) }
            return
        }
        guard self.session.canSetSessionPreset(sessionPreset) else {
            Self.logger.warning("Unsupported camera resolution: \(sessionPreset.rawValue)")
            return
        }
        self.session.sessionPreset = sessionPreset
        if let camera = captureDeviceById(with: cameraPreferences.captureDeviceId) {
            do {
                try updateImageDimensions(forCamera: camera)
            } catch {
                Self.logger.log("... Failed! \(error.localizedDescription)")
            }
        }
    }
        
    internal func updateImageDimensions(forCamera camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        let dimensions = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        imageSize.width = CGFloat(dimensions.width)
        imageSize.height = CGFloat(dimensions.height)
        camera.unlockForConfiguration()
    }
    
    internal func clampWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains, for device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var clamped = gains
        clamped.redGain = max(1.0, min(gains.redGain, device.maxWhiteBalanceGain))
        clamped.greenGain = max(1.0, min(gains.greenGain, device.maxWhiteBalanceGain))
        clamped.blueGain = max(1.0, min(gains.blueGain, device.maxWhiteBalanceGain))
        return clamped
    }
    
    
    public func update(isSmoothAutoFocus mode: CameraPreferences.smoothAutoFocus) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(isSmoothAutoFocus: mode) }
            return
        }
        cameraPreferences.isSmoothAutoFocus = mode
        userDefaults.currentCameraPreferences = cameraPreferences
        
        guard let device = currentDevice else {return}
        setSmoothAutoFocus(forCamera: device, enable: mode.isOn)
    }
    
    public func setSmoothAutoFocus(forCamera device: AVCaptureDevice, enable: Bool) {
        do {
            try device.lockForConfiguration()
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = enable
            } else {
                
            }
            device.unlockForConfiguration()
        } catch {
            error.localizedDescription
        }
    }
    
    public func update(isAutoFocus: CameraPreferences.AutoFocus, focusDistance: AVCaptureDevice.AutoFocusRangeRestriction? = nil) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(isAutoFocus: isAutoFocus, focusDistance: focusDistance) }
            return
        }
        guard let camera = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            return
        }
        
        let rangeRestriction = focusDistance ?? {
            let restrictionInt = cameraPreferences.autoFocusRangeRestriction
            return CameraPreferences.AutoFocusRangeRestriction(rawValue: restrictionInt)?.asAVCaptureDeviceRangeRestriction ?? .near
        }()
        
        let effectiveMode: CameraPreferences.AutoFocus = usesAutomaticCameraMode ? .on : isAutoFocus
        self.setAutoFocus(forCamera: camera, enable: effectiveMode.isOn, focusDistance: rangeRestriction)
        
        self.cameraPreferences.isAutoFocus = effectiveMode
        self.userDefaults.currentCameraPreferences = cameraPreferences
    }
    
    public func update(autoFocusRangeRestriction: Int) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(autoFocusRangeRestriction: autoFocusRangeRestriction) }
            return
        }
        // Exit early if auto focus is not enabled
        guard cameraPreferences.isAutoFocus.isOn else {
            return
        }
        
        guard let camera = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            return
        }
        
        // Validate the range restriction value (0 = .none, 1 = .near, 2 = .far)
        guard let restriction = CameraPreferences.AutoFocusRangeRestriction(rawValue: autoFocusRangeRestriction) else {
            return
        }
        
        do {
            try camera.lockForConfiguration()
            
            if camera.isAutoFocusRangeRestrictionSupported {
                camera.autoFocusRangeRestriction = usesAutomaticCameraMode ? .none : restriction.asAVCaptureDeviceRangeRestriction
            }
            
            camera.unlockForConfiguration()
            
            self.cameraPreferences.autoFocusRangeRestriction = autoFocusRangeRestriction
            self.userDefaults.currentCameraPreferences = cameraPreferences
        } catch {
            print("Error configuring auto focus range restriction: \(error)")
        }
    }
    
    public func update(isAutoWhiteBalance: CameraPreferences.AutoWhiteBalance) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(isAutoWhiteBalance: isAutoWhiteBalance) }
            return
        }
        guard let camera = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            return
        }
        
        do {
            try camera.lockForConfiguration()
            
            // Virtual devices cannot lock arbitrary white-balance gains.
            let effectiveMode: CameraPreferences.AutoWhiteBalance = usesAutomaticCameraMode ? .on : isAutoWhiteBalance
            switch effectiveMode {
            case .on:
                if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                
            case .manual(let temperature, let tint):
                if camera.isWhiteBalanceModeSupported(.locked) {
                    let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: temperature,
                        tint: tint
                    )
                    let gains = camera.deviceWhiteBalanceGains(for: tempAndTint)
                    let clampedGains = clampWhiteBalanceGains(gains, for: camera)
                    camera.setWhiteBalanceModeLocked(with: clampedGains, completionHandler: nil)
                }
            }

            camera.unlockForConfiguration()
            self.cameraPreferences.isAutoWhiteBalance = effectiveMode
            self.userDefaults.currentCameraPreferences = cameraPreferences
        } catch {
            print("Error locking configuration for update(whiteBalance:): \(error)")
        }
    }
    
    public func update(isAutoExposure: CameraPreferences.AutoExposure) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(isAutoExposure: isAutoExposure) }
            return
        }
        guard let camera = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            return
        }
        
        do {
            try camera.lockForConfiguration()
            
            let effectiveMode: CameraPreferences.AutoExposure = usesAutomaticCameraMode ? .on : isAutoExposure
            if case .off(let exposureValue) = effectiveMode {
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    
                    // Set the exposure value to the device's acceptable range
                    let exposureBias = max(
                        min(exposureValue, camera.maxExposureTargetBias),
                        camera.minExposureTargetBias
                    )
                    
                    camera.setExposureTargetBias(exposureBias, completionHandler: nil)
                }
            } else {
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                    camera.setExposureTargetBias(0.0, completionHandler: nil)
                }
            }
            
            camera.unlockForConfiguration()
            self.cameraPreferences.isAutoExposure = effectiveMode
            self.userDefaults.currentCameraPreferences = cameraPreferences
        } catch {
            print("Error locking configuration for update(isAutoExposure: \(error)")
        }
    }
    
    public func update(isAutoISO: CameraPreferences.AutoISO) {
        guard isOnSessionQueue else {
            performCameraConfiguration { self.update(isAutoISO: isAutoISO) }
            return
        }
        guard let camera = captureDeviceById(with: cameraPreferences.captureDeviceId) else {
            return
        }
        
        do {
            try camera.lockForConfiguration()
            
            let effectiveMode: CameraPreferences.AutoISO = usesAutomaticCameraMode ? .on : isAutoISO
            if case .off(let iSOValue) = effectiveMode {
                if camera.isExposureModeSupported(.custom) {
                    // Set the iso value to the device's acceptable range
                    let iso = max(
                        min(iSOValue, camera.activeFormat.maxISO),
                        camera.activeFormat.minISO
                    )
                    
                    camera.setExposureModeCustom(
                        duration: AVCaptureDevice.currentExposureDuration,
                        iso: iso,
                        completionHandler: nil
                    )
                }
            } else {
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
            }
            
            camera.unlockForConfiguration()
            self.cameraPreferences.isAutoISO = effectiveMode
            self.userDefaults.currentCameraPreferences = cameraPreferences
        } catch {
            print("Error locking configuration for update(isAutoISO: \(error)")
        }
    }
}
