//
//  OsirisScannerView.swift
//  FirebaseCore
//
//  Created by Kyle McGinnis on 2/1/24.
//

import AVFoundation
import Osiris
import SwiftUI
import UIKit

public class OsirisScannerView: UIView {
    
    // MARK: Properties
    
    var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
        didSet {
            setupPreviewLayer()
            setupOverlays()
        }
    }
    
    // Default no-op implementation. Will be overridden or assigned externally.
    var isRecordingDidUpdate: (Bool) -> Void = { _ in } {
        didSet {
            recordingButton.isRecordingDidUpdate = isRecordingDidUpdate
        }
    }
    
    var didTapToFocus: ((_ touchPoint: CGPoint) -> Void)?
    
    var showRecordingButton = false {
        didSet {
            recordingButton.isHidden = !showRecordingButton
        }
    }
    
    var isRecording = false {
        didSet {
            recordingButton.isRecording = isRecording
        }
    }
    
    // Default no-op implementation. Will be overridden or assigned externally.
    var workItem: DispatchWorkItem = .init(block: {})

    private let magnifyingSymbolConfig = UIImage.SymbolConfiguration(pointSize: 20)
    
    public var captureDevice: AVCaptureDevice? {
        didSet{
            guard let device = captureDevice else { return }
            isMacroMode = (device.deviceType == .builtInUltraWideCamera)
            baseZoomFactor = cameraManager?.baselineZoom(for: device) ?? (isMacroMode ? device.videoZoomFactor : defaultStandardZoom)
        }
    }
    
    public var isMacroMode: Bool = false

    private var resumeOverlayView: UIView?
    private var resumeTapCallback: (() -> Void)?
    
    private enum ToggleZoom { case normal, zoomed
        var symbol: String {
            switch self {
            case .normal: return "plus.magnifyingglass"
            case .zoomed: return "minus.magnifyingglass"
            }
        }
    }

    private var toggleZoomState: ToggleZoom = .normal

    public func resetZoomToggleState() {
        toggleZoomState = .normal
        zoomButton.setImage(UIImage(systemName: ToggleZoom.normal.symbol, withConfiguration: magnifyingSymbolConfig), for: .normal)
        zoomDescription.isHidden = true
    }
    
    lazy var zoomButton: UIButton = {
        let image = UIImage(systemName: ToggleZoom.normal.symbol, withConfiguration: magnifyingSymbolConfig)
        let button = UIButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = UIColor.white
        button.setImage(image, for: .normal)
        button.frame = .init(origin: .zero, size: .init(width: 32, height: 32))
        button.addTarget(self, action: #selector(zoomTapped), for: .touchUpInside)
        return button
    }()
    
    lazy var zoomDescription: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = .white
        label.textColor = .black
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()
    
    lazy var recordingButton: RecordingButton = {
        let button = RecordingButton(frame: .zero, isRecordingDidUpdate: isRecordingDidUpdate)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    
    lazy var boundingBoxes = BarcodeBoundingBoxes()
    
    public let videoContainerView: UIView = {
        let view = UIView()
        view.backgroundColor = .black
        view.translatesAutoresizingMaskIntoConstraints = false
        
        return view
    }()
    
    private lazy var vpnErrorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = UIColor.red.withAlphaComponent(0.8)
        label.textColor = .white
        label.textAlignment = .center
        label.font = UIFont.boldSystemFont(ofSize: 15)
        label.text = "VPN is off. Please connect VPN"
        label.isHidden = true
        return label
    }()
    
    public lazy var fpsStatsLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        label.textColor = .white
        label.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        label.numberOfLines = 0
        label.clipsToBounds = true
        label.textAlignment = .left
        label.text = ""
        return label
    }()
    
    private var focusIndicator: UIImageView?
    
    private let reticleSize: CGFloat = 240
    private let context: OsirisDataCaptureContext
    
    var reticle = ScannerReticleView()
    
    // MARK: Lifecycle
    
    init(frame: CGRect, context: OsirisDataCaptureContext) {
        self.context = context
        super.init(frame: frame)
        createView()
        setLayoutConstraints()
    }
    
    override init(frame: CGRect) {
        self.context = .init()
        super.init(frame: frame)
        createView()
        setLayoutConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer?.frame = videoContainerView.bounds
        
        reticle.didLayoutSubviews = { [weak self] in
            guard let self else { return }
            self.boundingBoxes.reticlePoint = self.reticle.frame.origin
        }
    }
    
    // MARK: Public API

    /// Applies values belonging to this scanner; no global resource provider is consulted.
    func applyAppearance(_ appearance: OsirisScannerAppearance) {
        reticle.reticleColor = appearance.reticleColor
        reticle.detectedReticleColor = appearance.detectedReticleColor
    }
    
    public func reticle(shouldHide: Bool) {
        reticle.isHidden = shouldHide
        boundingBoxes.isReticleEnabled = !shouldHide
    }

    @objc private func handleResumeTap() {
        videoPreviewLayer?.connection?.isEnabled = true
        resumeOverlayView?.removeFromSuperview()
        resumeOverlayView = nil
        resumeTapCallback?()
    }
    
    // to control visibility of fps Stats label
    public func fpsStats(shouldHide: Bool) {
        fpsStatsLabel.isHidden = shouldHide
    }

    private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        let touchPoint = gesture.location(in: self)
        didTapToFocus?(touchPoint)
    }
    
    public var baseZoomFactor: CGFloat = 1.5
    
    private let defaultStandardZoom: CGFloat = 1.5
    
    public weak var cameraManager:CameraManager?
    
    @objc private func zoomTapped() {
        guard let device = cameraManager?.currentDevice else { return }
        
        let rawNewZoom: CGFloat
        
        switch toggleZoomState {
            
        case .normal:
            // zoom out → zoom in: always allowed
            let candidate = device.videoZoomFactor * 2
            rawNewZoom = min(candidate, device.maxAvailableVideoZoomFactor)
            toggleZoomState = .zoomed
            
        case .zoomed:
            // zoom in → zoom out: but never below baseZoomFactor
            let candidate = device.videoZoomFactor / 2
            let minimum = cameraManager?.baselineZoom(for: device) ?? baseZoomFactor
            rawNewZoom = max(candidate, minimum)
            toggleZoomState = .normal
        }
        
        // clamp to hardware limits as well ???
        let newZoom = min(max(rawNewZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        
        cameraManager?.performCameraConfiguration { [weak cameraManager] in
            guard cameraManager?.currentDevice?.uniqueID == device.uniqueID else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.videoZoomFactor = min(max(newZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            } catch {
                print("Zoom failed:", error)
            }
        }
        
        // update the button icon & label
        zoomButton.setImage(
            UIImage(systemName: toggleZoomState.symbol,
                    withConfiguration: magnifyingSymbolConfig),
            for: .normal
        )
        let standardZoom: CGFloat = cameraManager?.usesAutomaticCameraMode == true ? 1 : defaultStandardZoom
        let zoomDisplayFactor = (toggleZoomState == .normal) ? standardZoom : standardZoom * 2
        zoomDescription.text = String(format: "%.1fx", zoomDisplayFactor)
        setZoomDescriptionVisibility(isHidden: false)
    }

    // MARK: Private Helpers

    public func showTapToResumeOverlay(onTap: @escaping () -> Void) {
        guard resumeOverlayView == nil else { return }

        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        let label = UILabel()
        label.text = "Tap Anywhere to Resume"
        label.textColor = .white
        label.font = UIFont.boldSystemFont(ofSize: 18)
        label.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(label)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleResumeTap))
        overlay.addGestureRecognizer(tap)
        self.resumeTapCallback = onTap
        self.resumeOverlayView = overlay

        videoPreviewLayer?.connection?.isEnabled = false
        videoContainerView.addSubview(overlay)

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: videoContainerView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: videoContainerView.bottomAnchor),
            
            label.centerXAnchor.constraint(equalTo: videoContainerView.centerXAnchor),
            label.topAnchor.constraint(equalTo: videoContainerView.topAnchor, constant: 120)

        ])
    }

    // MARK: Private Helpers

    private func createView() {
        backgroundColor = .white
        addSubview(videoContainerView)
    }
    
    public func setVPNErrorMessage(_ message:String?){
        if let message = message, !message.isEmpty {
            vpnErrorLabel.text = message
            vpnErrorLabel.isHidden = false
        } else {
            vpnErrorLabel.isHidden = true
        }
    }
    
    /// If we want a square Camera Container in the future - Uncomment height anchor and get rid of bottom anchor
    private func setLayoutConstraints() {
        NSLayoutConstraint.activate([
            videoContainerView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            videoContainerView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            videoContainerView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            videoContainerView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
            //            videoContainerView.heightAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor)
        ])
    }
    
    private func setupPreviewLayer() {
        guard let videoPreviewLayer = videoPreviewLayer else {
            return
        }
        videoContainerView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        videoPreviewLayer.videoGravity = .resizeAspectFill
        videoPreviewLayer.frame = videoContainerView.bounds
        videoContainerView.layer.addSublayer(videoPreviewLayer)
    }
    
    private func setupOverlays() {
        videoContainerView.addSubview(reticle)
        videoContainerView.addSubview(boundingBoxes)
        videoContainerView.addSubview(recordingButton)
        videoContainerView.addSubview(zoomButton)
        videoContainerView.addSubview(zoomDescription)
        videoContainerView.addSubview(vpnErrorLabel)
        videoContainerView.addSubview(fpsStatsLabel)
        
        NSLayoutConstraint.activate([
            reticle.widthAnchor.constraint(equalToConstant: reticleSize),
            reticle.heightAnchor.constraint(equalToConstant: reticleSize),
            reticle.centerXAnchor.constraint(equalTo: videoContainerView.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: videoContainerView.centerYAnchor),
            
            boundingBoxes.centerXAnchor.constraint(equalTo: videoContainerView.centerXAnchor),
            boundingBoxes.centerYAnchor.constraint(equalTo: videoContainerView.centerYAnchor),
            boundingBoxes.widthAnchor.constraint(equalTo: videoContainerView.widthAnchor),
            boundingBoxes.heightAnchor.constraint(equalTo: videoContainerView.heightAnchor),
            
            recordingButton.widthAnchor.constraint(equalToConstant: 64),
            recordingButton.heightAnchor.constraint(equalToConstant: 64),
            recordingButton.centerXAnchor.constraint(equalTo: videoContainerView.centerXAnchor),
            recordingButton.topAnchor.constraint(equalTo: reticle.bottomAnchor, constant: 24),
            
            vpnErrorLabel.topAnchor.constraint(equalTo: videoContainerView.safeAreaLayoutGuide.topAnchor),
            vpnErrorLabel.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor),
            vpnErrorLabel.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor),
            vpnErrorLabel.heightAnchor.constraint(equalToConstant: 40),
            
            fpsStatsLabel.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor, constant: 3),
            fpsStatsLabel.centerYAnchor.constraint(equalTo: reticle.bottomAnchor,constant: 24),
            fpsStatsLabel.widthAnchor.constraint(equalToConstant: 170),
            
            zoomButton.centerYAnchor.constraint(equalTo: reticle.centerYAnchor),
            zoomButton.trailingAnchor.constraint(equalTo: reticle.trailingAnchor, constant: 32),
            
            zoomDescription.centerXAnchor.constraint(equalTo: reticle.centerXAnchor),
            zoomDescription.bottomAnchor.constraint(equalTo: reticle.topAnchor, constant: -24),
            zoomDescription.widthAnchor.constraint(equalToConstant: 64),
            zoomDescription.heightAnchor.constraint(equalToConstant: 24)
        ])
        
        // Set context to pass down configs.
        boundingBoxes.context = context
        boundingBoxes.didTapOnEmptyArea = { [weak self] gesture in
            self?.handleTapToFocus(gesture)
        }
    }
    
    private func setZoomDescriptionVisibility(isHidden: Bool) {
        withAnimation {
            zoomDescription.isHidden = isHidden
        }
        if !isHidden {
            workItem.cancel()
            workItem = DispatchWorkItem { [ weak self ] in
                withAnimation {
                    self?.zoomDescription.isHidden = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
        }
    }
    
    func showFocusSquare(at point: CGPoint) {
        focusIndicator?.removeFromSuperview()
        
        let size: CGFloat = 70
        
        let newFocusIndicator = UIImageView()
        if let focusImage = UIImage(systemName: "camera.metering.center.weighted.average") {
            newFocusIndicator.image = focusImage.withTintColor(.yellow, renderingMode: .alwaysOriginal)
            newFocusIndicator.contentMode = .scaleAspectFit
            newFocusIndicator.frame = CGRect(x: point.x - size/2, y: point.y - size/2, width: size, height: size)
            
            addSubview(newFocusIndicator)
            
            self.focusIndicator = newFocusIndicator
            
            newFocusIndicator.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
            newFocusIndicator.alpha = 1.0
            
            UIView.animate(withDuration: 0.3, animations: {
                newFocusIndicator.transform = CGAffineTransform.identity
            }) { _ in
                UIView.animate(withDuration: 0.2, delay: 0.5, options: [], animations: {
                    newFocusIndicator.alpha = 0
                }) { [weak self] _ in
                    if self?.focusIndicator == newFocusIndicator {
                        newFocusIndicator.removeFromSuperview()
                        self?.focusIndicator = nil
                    }
                }
            }
        }
    }
}
