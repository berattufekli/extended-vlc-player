import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Bridges UIImage snapshots (from VLC) to a stream of CMSampleBuffers
/// that are enqueued onto an `AVSampleBufferDisplayLayer`.
///
/// MobileVLCKit does not expose decoded frames as `CVPixelBufferRef`. The
/// only public way to get a rendered frame is the snapshot API, which
/// returns a `UIImage`. This bridge converts that UIImage into a pooled
/// `CVPixelBuffer` and a `CMSampleBuffer`, then enqueues it. The
/// `AVSampleBufferDisplayLayer` is then used as the source for
/// `AVPictureInPictureController.ContentSource` (set up by the
/// `PlayerSession`).
final class PipBridge {
  private let displayLayer: AVSampleBufferDisplayLayer
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var pixelBufferPool: CVPixelBufferPool?
  private let poolAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: 640,
    kCVPixelBufferHeightKey as String: 360,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
  ]
  private let bufferAttributes: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
  ]

  /// Tracks the most recent enqueue's host time so we can compute the
  /// presentation timestamp of the next sample buffer.
  private var lastEnqueueTime: CFTimeInterval = 0
  /// Frame counter used to make the format description identifier stable
  /// across re-enqueues; AVPictureInPictureContentSource complains if the
  /// format description changes between enqueues.
  private var formatDescription: CMFormatDescription?
  private var formatDescriptionWidth: Int = 0
  private var formatDescriptionHeight: Int = 0

  init(displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer = displayLayer
  }

  /// Call with a fresh UIImage from VLC. Performs all conversion on the
  /// caller's queue (expected: main thread, since UIImage decoding on
  /// other queues is expensive and can produce memory pressure spikes).
  func feed(image: UIImage) {
    guard let cgImage = image.cgImage else { return }
    let width = cgImage.width
    let height = cgImage.height
    if width <= 0 || height <= 0 { return }

    if pixelBufferPool == nil {
      pixelBufferPool = makePool(width: width, height: height)
    }
    guard let pool = pixelBufferPool else { return }

    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    guard status == kCVReturnSuccess, let pb = pixelBuffer else { return }

    // Lock + draw the image into the pixel buffer using Core Graphics.
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let baseAddress = CVPixelBufferGetBaseAddress(pb)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
      data: baseAddress,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return }
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Build / update the format description if dimensions changed.
    if formatDescription == nil || width != formatDescriptionWidth || height != formatDescriptionHeight {
      var desc: CMFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescriptionOut: &desc
      )
      formatDescription = desc
      formatDescriptionWidth = width
      formatDescriptionHeight = height
    }
    guard let desc = formatDescription else { return }

    // Build a CMSampleBuffer that wraps the pixel buffer.
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
      decodeTimeStamp: .invalid
    )
    var sample: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pb,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: desc,
      sampleTiming: &timing,
      sampleBufferOut: &sample
    )
    guard createStatus == kCVReturnSuccess, let sb = sample else { return }

    // Force the display layer to render this sample immediately, so the
    // PiP overlay never shows a stale frame.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
       let dict = CFArrayGetValueAtIndex(attachments, 0) {
      let dict = unsafeBitCast(dict, to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    displayLayer.enqueue(sb)
  }

  private func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
    var attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ]
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(
      kCFAllocatorDefault,
      nil,
      attrs as CFDictionary,
      &pool
    )
    return status == kCVReturnSuccess ? pool : nil
  }
}
