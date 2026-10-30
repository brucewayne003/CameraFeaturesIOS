import CoreImage
import CoreVideo
import Osiris
@testable import OsirisBarcode
import XCTest
import ZXingCpp

final class BarcodeGeometryTests: XCTestCase {
    func testCropTransformUsesOffCenterPreviewOriginWithoutScalingItAgain() {
        let decoder = makeDecoder(imageSize: CGSize(width: 640, height: 480),
                                  previewSize: CGSize(width: 320, height: 240))

        let result = decoder.transformRect(originalBounds: CGRect(x: 10, y: 20, width: 40, height: 30),
                                           from: decoder.pixelBufferSize,
                                           to: decoder.options.previewSize,
                                           originOffset: CGPoint(x: 50, y: 30),
                                           sizeOffset: CGSize(width: 80, height: 60))

        XCTAssertEqual(result, CGRect(x: 55, y: 40, width: 20, height: 15))
    }

    func testOffCenterCropKeepsDecoderRectangleLocalAndReturnsFullImageCorners() throws {
        let decoder = makeDecoder(imageSize: CGSize(width: 640, height: 480),
                                  previewSize: CGSize(width: 320, height: 240))
        let pixelBuffer = try makePixelBuffer(width: 640, height: 480)
        transformResult(using: decoder, pixelBuffer: pixelBuffer,
                        cropOrigin: CGPoint(x: 100, y: 60))

        let barcode = try XCTUnwrap(decoder.detectedBarcodes.first)
        XCTAssertEqual(barcode.boundingBoxInPixelBuffer, CGRect(x: 10, y: 20, width: 40, height: 30))
        XCTAssertEqual(barcode.boundingBoxInCameraPreview, CGRect(x: 55, y: 40, width: 20, height: 15))
        XCTAssertEqual(barcode.quadPoints, [CGPoint(x: 110, y: 80), CGPoint(x: 150, y: 80),
                                           CGPoint(x: 150, y: 110), CGPoint(x: 110, y: 110)])
        XCTAssertEqual(barcode.quadPointsInCameraPreview,
                       [CGPoint(x: 55, y: 40), CGPoint(x: 75, y: 40),
                        CGPoint(x: 75, y: 55), CGPoint(x: 55, y: 55)])
        XCTAssertEqual(barcode.symbologyIdentifier, "]Q3")
    }

    func testUncroppedImageDoesNotApplyComputedROIOrigin() throws {
        let decoder = makeDecoder(imageSize: CGSize(width: 640, height: 480),
                                  previewSize: CGSize(width: 320, height: 180))
        decoder.options.reticle = false
        // The default ROI can be nonzero even though the entire frame is decoded.
        decoder.roiRect = CGRect(x: 0, y: 60, width: 640, height: 360)
        XCTAssertNil(decoder.decodingCropRect(in: decoder.pixelBufferSize))

        let pixelBuffer = try makePixelBuffer(width: 640, height: 480)
        transformResult(using: decoder, pixelBuffer: pixelBuffer)

        let barcode = try XCTUnwrap(decoder.detectedBarcodes.first)
        XCTAssertEqual(barcode.quadPoints.first, CGPoint(x: 10, y: 20))
        XCTAssertEqual(barcode.boundingBoxInCameraPreview, CGRect(x: 5, y: -20, width: 20, height: 15))
        XCTAssertEqual(barcode.quadPointsInCameraPreview.first, CGPoint(x: 5, y: -20))
    }

    func testPortraitAspectFillUsesAlreadyOrientedBufferWithoutAnotherRotation() throws {
        let decoder = makeDecoder(imageSize: CGSize(width: 480, height: 640),
                                  previewSize: CGSize(width: 180, height: 320))
        let pixelBuffer = try makePixelBuffer(width: 480, height: 640)
        transformResult(using: decoder, pixelBuffer: pixelBuffer,
                        cropOrigin: CGPoint(x: 100, y: 60))

        let barcode = try XCTUnwrap(decoder.detectedBarcodes.first)
        XCTAssertEqual(barcode.boundingBoxInCameraPreview, CGRect(x: 25, y: 40, width: 20, height: 15))
        XCTAssertEqual(barcode.quadPointsInCameraPreview.first, CGPoint(x: 25, y: 40))
    }

    func testMirroredPreviewRectangleAndCornersUseSameTransform() throws {
        let decoder = makeDecoder(imageSize: CGSize(width: 640, height: 480),
                                  previewSize: CGSize(width: 320, height: 240))
        decoder.options.scanDirectionFront = true
        let pixelBuffer = try makePixelBuffer(width: 640, height: 480)
        transformResult(using: decoder, pixelBuffer: pixelBuffer,
                        cropOrigin: CGPoint(x: 100, y: 60))

        let barcode = try XCTUnwrap(decoder.detectedBarcodes.first)
        XCTAssertEqual(barcode.boundingBoxInCameraPreview, CGRect(x: 245, y: 40, width: 20, height: 15))
        XCTAssertEqual(barcode.quadPointsInCameraPreview,
                       [CGPoint(x: 265, y: 40), CGPoint(x: 245, y: 40),
                        CGPoint(x: 245, y: 55), CGPoint(x: 265, y: 55)])
        XCTAssertEqual(barcode.quadPoints.first, CGPoint(x: 110, y: 80))
    }

    func testQuadOptOutStillReturnsPreviewRectangle() throws {
        let decoder = makeDecoder(imageSize: CGSize(width: 640, height: 480),
                                  previewSize: CGSize(width: 320, height: 240))
        decoder.isQuadliteralEnabled = false
        let pixelBuffer = try makePixelBuffer(width: 640, height: 480)
        transformResult(using: decoder, pixelBuffer: pixelBuffer)

        let barcode = try XCTUnwrap(decoder.detectedBarcodes.first)
        XCTAssertEqual(barcode.boundingBoxInCameraPreview, CGRect(x: 5, y: 10, width: 20, height: 15))
        XCTAssertTrue(barcode.quadPoints.isEmpty)
        XCTAssertTrue(barcode.quadPointsInCameraPreview.isEmpty)
    }

    func testAppliedCropMatchesIntegralCPUCopyAndRejectsInvalidROI() {
        let decoder = makeDecoder(imageSize: CGSize(width: 640, height: 480),
                                  previewSize: CGSize(width: 320, height: 240))
        decoder.options.reticle = false
        decoder.setROI(CGRect(x: 10.9, y: 20.8, width: 30.7, height: 40.6))
        XCTAssertEqual(decoder.decodingCropRect(in: decoder.pixelBufferSize),
                       CGRect(x: 10, y: 20, width: 30, height: 40))

        for invalidROI in [CGRect(x: -1, y: 0, width: 20, height: 20),
                           CGRect(x: 620, y: 0, width: 30, height: 20),
                           CGRect(x: 30, y: 20, width: -10, height: 20),
                           CGRect(x: 10, y: 20, width: 0.5, height: 20),
                           CGRect.zero] {
            decoder.setROI(invalidROI)
            XCTAssertNil(decoder.decodingCropRect(in: decoder.pixelBufferSize))
        }
    }

    func testGPUCropMatchesCPUPixelsForOffCenterNonSquareROI() throws {
        let decoder = makeDecoder(imageSize: CGSize(width: 8, height: 6),
                                  previewSize: CGSize(width: 8, height: 6))
        let pixelBuffer = try makePixelBuffer(width: 8, height: 6)
        try fillCoordinates(in: pixelBuffer)

        let roi = CGRect(x: 1, y: 1, width: 4, height: 2)
        let cpuCrop = try XCTUnwrap(pixelBuffer.crop(toRect: roi))
        let gpuCrop = decoder.cropForDecoding(CIImage(cvPixelBuffer: pixelBuffer), to: roi)
        XCTAssertEqual(gpuCrop.extent, CGRect(x: 1, y: 3, width: 4, height: 2))
        XCTAssertEqual(rgbaPixels(of: gpuCrop), rgbaPixels(of: CIImage(cvPixelBuffer: cpuCrop)))
    }

    func testZeroSizedContainerProducesFiniteEmptyRectangle() {
        let decoder = makeDecoder(imageSize: .zero, previewSize: CGSize(width: 320, height: 240))
        XCTAssertEqual(decoder.transformRect(originalBounds: CGRect(x: 10, y: 20, width: 30, height: 40),
                                             from: .zero,
                                             to: decoder.options.previewSize,
                                             originOffset: .zero,
                                             sizeOffset: .zero), .zero)
    }

    private func fillCoordinates(in pixelBuffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            .assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<6 {
            for x in 0..<8 {
                let index = y * bytesPerRow + x * 4
                bytes[index] = UInt8(x * 20)
                bytes[index + 1] = UInt8(y * 30)
                bytes[index + 2] = UInt8((x + y) * 10)
                bytes[index + 3] = 255
            }
        }
    }

    private func makeDecoder(imageSize: CGSize, previewSize: CGSize) -> ZXingBarcodeDecoder {
        var options = BarcodeDecoderOptions(decoderType: .zxing)
        options.previewSize = previewSize
        options.formats = [.qrcode]
        let decoder = ZXingBarcodeDecoder(options: options)
        decoder.pixelBufferSize = imageSize
        decoder.isQuadliteralEnabled = true
        return decoder
    }

    private func transformResult(using decoder: ZXingBarcodeDecoder,
                                 pixelBuffer: CVPixelBuffer,
                                 cropOrigin: CGPoint = .zero) {
        let points = [ZXIPoint(x: 10, y: 20), ZXIPoint(x: 50, y: 20),
                      ZXIPoint(x: 50, y: 50), ZXIPoint(x: 10, y: 50)]
        // ZXIPosition does not retain its corner objects in the supplied binary.
        // Keep them alive until the decoder has copied their coordinates.
        withExtendedLifetime(points) {
            let position = ZXIPosition(topLeft: points[0], topRight: points[1],
                                       bottomRight: points[2], bottomLeft: points[3])
            let result = ZXIResult("GEOMETRY", format: .QR_CODE, bytes: Data(),
                                   position: position, symbologyIdentifier: "]Q3")
            decoder.transformBarcodes(results: [result], pixelBuffer: pixelBuffer,
                                      cropOrigin: cropOrigin)
        }
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pixelBuffer)
    }

    private func rgbaPixels(of image: CIImage) -> [UInt8] {
        let bytesPerRow = Int(image.extent.width) * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * Int(image.extent.height))
        pixels.withUnsafeMutableBytes { buffer in
            CIContext().render(image, toBitmap: buffer.baseAddress!, rowBytes: bytesPerRow,
                               bounds: image.extent, format: .RGBA8,
                               colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return pixels
    }
}
