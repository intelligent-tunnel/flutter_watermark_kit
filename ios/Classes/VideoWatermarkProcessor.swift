import Foundation
import AVFoundation
import CoreImage
import UIKit
import ImageIO

final class VideoWatermarkProcessor {
  private let queue = DispatchQueue(label: "wm.video", qos: .userInitiated)

  private final class TaskState {
    var cancelled = false
    let request: ComposeVideoRequest
    let outputURL: URL
    init(request: ComposeVideoRequest, outputURL: URL) {
      self.request = request
      self.outputURL = outputURL
    }
  }

  private var tasks: [String: TaskState] = [:]

  func start(plugin: WatermarkKitPlugin,
             request: ComposeVideoRequest,
             callbacks: WatermarkCallbacks,
             taskId: String,
             onComplete: @escaping (ComposeVideoResult) -> Void,
             onError: @escaping (_ code: String, _ message: String) -> Void) {
    let outputPath: String
    if let out = request.outputVideoPath, !out.isEmpty {
      outputPath = out
    } else {
      let tmp = NSTemporaryDirectory()
      outputPath = (tmp as NSString).appendingPathComponent("wm_\(taskId).mp4")
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    // Remove existing
    try? FileManager.default.removeItem(at: outputURL)

    let state = TaskState(request: request, outputURL: outputURL)
    tasks[taskId] = state

    queue.async { [weak self] in
      guard let self else { return }
      do {
        try self.process(plugin: plugin, state: state, callbacks: callbacks, taskId: taskId, onComplete: onComplete, onError: onError)
      } catch let err {
        callbacks.onVideoError(taskId: taskId, code: "compose_failed", message: err.localizedDescription) { _ in }
        onError("compose_failed", err.localizedDescription)
        self.tasks[taskId] = nil
      }
    }
  }

  func cancel(taskId: String) {
    if let st = tasks[taskId] {
      st.cancelled = true
    }
  }

  private func process(plugin: WatermarkKitPlugin,
                       state: TaskState,
                       callbacks: WatermarkCallbacks,
                       taskId: String,
                       onComplete: @escaping (ComposeVideoResult) -> Void,
                       onError: @escaping (_ code: String, _ message: String) -> Void) throws {
    let request = state.request
    let asset = AVURLAsset(url: URL(fileURLWithPath: request.inputVideoPath))
    let duration = CMTimeGetSeconds(asset.duration)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
      throw NSError(domain: "wm", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track"])
    }

    let natural = videoTrack.naturalSize
    let preferredTransform = videoTrack.preferredTransform
    let orientedRect = CGRect(origin: .zero, size: natural).applying(preferredTransform)
    let display = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))

    // Prepare overlay CIImage once
    let overlayCI: CIImage? = try Self.prepareOverlayCI(request: request, plugin: plugin, baseWidth: display.width, baseHeight: display.height)

    let reader = try AVAssetReader(asset: asset)
    let fps: Float = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30.0
    let videoComposition = AVMutableVideoComposition()
    videoComposition.renderSize = display
    videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(fps))
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    layerInstruction.setTransform(preferredTransform, at: .zero)
    instruction.layerInstructions = [layerInstruction]
    videoComposition.instructions = [instruction]

    let videoReaderOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    videoReaderOutput.videoComposition = videoComposition
    videoReaderOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoReaderOutput) else { throw NSError(domain: "wm", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output"]) }
    reader.add(videoReaderOutput)

    let writer = try AVAssetWriter(outputURL: state.outputURL, fileType: .mp4)
    // Video writer input
    let codec: AVVideoCodecType = (request.codec == .hevc) ? .hevc : .h264
    let defaultBitrate = Int64(Self.estimateBitrate(width: Int(display.width), height: Int(display.height), fps: Float(videoTrack.nominalFrameRate)))
    let bitrate64: Int64 = request.bitrateBps ?? defaultBitrate
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: NSNumber(value: bitrate64),
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: Int(display.width),
      AVVideoHeightKey: Int(display.height),
      AVVideoCompressionPropertiesKey: compression,
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    // Frames are rotated into display orientation; keep output transform identity.
    videoInput.transform = .identity
    guard writer.canAdd(videoInput) else { throw NSError(domain: "wm", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"]) }
    writer.add(videoInput)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(display.width),
      kCVPixelBufferHeightKey as String: Int(display.height),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ])

    // 音频：强制重编码 AAC，避免直通不兼容导致静音
    let audioTrack = asset.tracks(withMediaType: .audio).first
    var audioReaderOutput: AVAssetReaderOutput? = nil
    var audioInput: AVAssetWriterInput? = nil
    if let a = audioTrack {
      let (sampleRate, channels) = Self.audioFormatInfo(from: a)
      let audioReaderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false
      ]
      let out = AVAssetReaderAudioMixOutput(audioTracks: [a], audioSettings: audioReaderSettings)
      out.alwaysCopiesSampleData = false
      guard reader.canAdd(out) else { throw NSError(domain: "wm", code: -20, userInfo: [NSLocalizedDescriptionKey: "无法添加音频读取器"]) }
      reader.add(out)
      audioReaderOutput = out

      let audioWriterSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: Self.estimateAudioBitrate(sampleRate: sampleRate, channels: channels)
      ]
      let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriterSettings)
      ain.expectsMediaDataInRealTime = false
      guard writer.canAdd(ain) else { throw NSError(domain: "wm", code: -21, userInfo: [NSLocalizedDescriptionKey: "无法添加音频写入器"]) }
      writer.add(ain)
      audioInput = ain
    }

    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "wm", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"]) }
    let startTime = CMTime.zero
    writer.startSession(atSourceTime: startTime)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "wm", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"]) }

    let ciContext = plugin.sharedCIContext

    // Precompute overlay with opacity and translation in display coordinates
    let preparedOverlay: CIImage? = {
      guard let ov = overlayCI else { return nil }
      // Apply opacity
      let alphaVec = CIVector(x: 0, y: 0, z: 0, w: CGFloat(request.opacity))
      let withOpacity = ov.applyingFilter("CIColorMatrix", parameters: ["inputAVector": alphaVec])
      // Compute position
      let baseRect = CGRect(x: 0, y: 0, width: display.width, height: display.height)
      let wmRect = withOpacity.extent
      let marginX = (request.marginUnit == .percent) ? CGFloat(request.margin) * display.width : CGFloat(request.margin)
      let marginY = (request.marginUnit == .percent) ? CGFloat(request.margin) * display.height : CGFloat(request.margin)
      var pos = Self.positionRect(base: baseRect, overlay: wmRect, anchor: request.anchor, marginX: marginX, marginY: marginY)
      let dx = (request.offsetUnit == .percent) ? CGFloat(request.offsetX) * display.width : CGFloat(request.offsetX)
      let dy = (request.offsetUnit == .percent) ? CGFloat(request.offsetY) * display.height : CGFloat(request.offsetY)
      pos.x += dx
      pos.y += dy
      return withOpacity.transformed(by: CGAffineTransform(translationX: floor(pos.x), y: floor(pos.y)))
    }()

    // Processing loop
    var lastPTS = CMTime.zero
    var videoDrained = false
    var audioFinished = audioInput == nil
    while reader.status == .reading && !state.cancelled && !videoDrained {
      try autoreleasepool {
        if videoInput.isReadyForMoreMediaData, let sample = videoReaderOutput.copyNextSampleBuffer() {
          let pts = CMSampleBufferGetPresentationTimeStamp(sample)
          lastPTS = pts
          guard let pool = adaptor.pixelBufferPool else {
            throw NSError(domain: "wm", code: -10, userInfo: [NSLocalizedDescriptionKey: "Pixel buffer pool unavailable"])
          }
          var pb: CVPixelBuffer? = nil
          let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
          guard status == kCVReturnSuccess, let dst = pb else {
            throw NSError(domain: "wm", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Failed to allocate pixel buffer: \(status)"])
          }

          // Create base CIImage from sample
          if let srcPB = CMSampleBufferGetImageBuffer(sample) {
            let base = CIImage(cvPixelBuffer: srcPB)
            let output: CIImage
            if let overlay = preparedOverlay {
              // Source-over
              let filter = CIFilter(name: "CISourceOverCompositing")!
              filter.setValue(overlay, forKey: kCIInputImageKey)
              filter.setValue(base, forKey: kCIInputBackgroundImageKey)
              output = filter.outputImage ?? base
            } else {
              output = base
            }
            ciContext.render(output, to: dst, bounds: CGRect(x: 0, y: 0, width: display.width, height: display.height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            _ = adaptor.append(dst, withPresentationTime: pts)
          }

          // Progress
          let p = max(0.0, min(1.0, CMTimeGetSeconds(pts) / max(0.001, duration)))
          callbacks.onVideoProgress(taskId: taskId, progress: p, etaSec: max(0.0, duration - CMTimeGetSeconds(pts))) { _ in }
        } else if videoInput.isReadyForMoreMediaData {
          // 无更多样本时跳出循环，避免 reader/status 长期停留在 reading
          videoDrained = true
        } else {
          // Back off a little
          usleep(2000)
        }

        // 音频同步拉取，确保音轨完整写入
        if let aout = audioReaderOutput, let ain = audioInput, !audioFinished {
          while ain.isReadyForMoreMediaData {
            guard let asample = aout.copyNextSampleBuffer() else {
              ain.markAsFinished()
              audioFinished = true
              break
            }
            if !ain.append(asample) {
              let msg = writer.error?.localizedDescription ?? "音频写入失败"
              throw NSError(domain: "wm", code: -22, userInfo: [NSLocalizedDescriptionKey: msg])
            }
          }
        }
      }
    }

    if state.cancelled {
      reader.cancelReading()
      videoInput.markAsFinished()
      audioInput?.markAsFinished()
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: state.outputURL)
      callbacks.onVideoError(taskId: taskId, code: "cancelled", message: "Cancelled") { _ in }
      onError("cancelled", "Cancelled")
      tasks[taskId] = nil
      return
    }

    // 补齐剩余音频，避免尾部被截断
    if let aout = audioReaderOutput, let ain = audioInput, !audioFinished {
      var drainingAudio = true
      while drainingAudio {
        while ain.isReadyForMoreMediaData {
          guard let asample = aout.copyNextSampleBuffer() else {
            ain.markAsFinished()
            audioFinished = true
            drainingAudio = false
            break
          }
          if !ain.append(asample) {
            let msg = writer.error?.localizedDescription ?? "音频写入失败"
            throw NSError(domain: "wm", code: -23, userInfo: [NSLocalizedDescriptionKey: msg])
          }
        }
        if !drainingAudio { break }
        usleep(2000)
      }
    }

    videoInput.markAsFinished()
    audioInput?.markAsFinished()
    reader.cancelReading()
    writer.finishWriting { [weak self] in
      guard let self else { return }
      if writer.status == .completed {
        let res = ComposeVideoResult(taskId: taskId,
                                     outputVideoPath: state.outputURL.path,
                                     width: Int64(display.width),
                                     height: Int64(display.height),
                                     durationMs: Int64(duration * 1000.0),
                                     codec: request.codec)
        callbacks.onVideoCompleted(result: res) { _ in }
        onComplete(res)
      } else {
        let msg = writer.error?.localizedDescription ?? "Unknown writer error"
        callbacks.onVideoError(taskId: taskId, code: "encode_failed", message: msg) { _ in }
        onError("encode_failed", msg)
      }
      self.tasks[taskId] = nil
    }
  }

  private static func estimateBitrate(width: Int, height: Int, fps: Float) -> Int {
    let bpp: Float = 0.08 // reasonable default for H.264 1080p
    let f = max(24.0, fps > 0 ? fps : 30.0)
    let br = bpp * Float(width * height) * f
    return max(500_000, Int(br))
  }

  // 获取音频轨基础信息（采样率/声道），为 AAC 重编码提供参数
  private static func audioFormatInfo(from track: AVAssetTrack) -> (Double, Int) {
    guard let anyDesc = track.formatDescriptions.first else { return (44_100.0, 2) }
    let desc = anyDesc as! CMFormatDescription
    guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Audio,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
      return (44_100.0, 2)
    }
    let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100.0
    let ch = Int(max(1, asbd.mChannelsPerFrame))
    return (rate, ch)
  }

  // 估算 AAC 比特率，保证常见音频具备足够质量
  private static func estimateAudioBitrate(sampleRate: Double, channels: Int) -> Int {
    let base = Int(sampleRate * Double(channels) * 2.0)
    return max(96_000, min(320_000, base))
  }

  private static func prepareOverlayCI(request: ComposeVideoRequest, plugin: WatermarkKitPlugin, baseWidth: CGFloat, baseHeight: CGFloat) throws -> CIImage? {
    // Prefer watermarkImage; fallback to text
    if let data = request.watermarkImage?.data, !data.isEmpty {
      guard let src = decodeCIImage(from: data) else { return nil }
      // Scale by widthPercent of base width using high-quality Lanczos
      let targetW = max(1.0, baseWidth * CGFloat(request.widthPercent))
      let extent = src.extent
      let scale = targetW / max(1.0, extent.width)
      return scaleCIImageHighQuality(src, scale: scale)
    }
    if let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let fontFamily = ".SFUI"
      let fontSizePt = 24.0
      let fontWeight = 600
      let colorArgb: UInt32 = 0xFFFFFFFF
      guard let cg = try WatermarkKitPlugin.renderTextCGImage(text: text, fontFamily: fontFamily, fontSizePt: fontSizePt, fontWeight: fontWeight, colorArgb: colorArgb) else {
        return nil
      }
      let png = WatermarkKitPlugin.encodePNG(cgImage: cg) ?? Data()
      guard let src = decodeCIImage(from: png) else { return nil }
      let targetW = max(1.0, baseWidth * CGFloat(request.widthPercent))
      let extent = src.extent
      let scale = targetW / max(1.0, extent.width)
      return scaleCIImageHighQuality(src, scale: scale)
    }
    return nil
  }

  private static func scaleCIImageHighQuality(_ image: CIImage, scale: CGFloat) -> CIImage {
    // Use CILanczosScaleTransform for superior quality scaling
    if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
      lanczos.setValue(image, forKey: kCIInputImageKey)
      lanczos.setValue(scale, forKey: kCIInputScaleKey)
      lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
      return lanczos.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    } else {
      // Fallback to simple transform
      return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
  }

  private static func decodeCIImage(from data: Data) -> CIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
      return nil
    }
    return CIImage(cgImage: cg, options: [.applyOrientationProperty: true])
  }

  private static func positionRect(base: CGRect, overlay: CGRect, anchor: Anchor, marginX: CGFloat, marginY: CGFloat) -> CGPoint {
    let w = overlay.width
    let h = overlay.height
    switch anchor {
    case .topLeft:
      return CGPoint(x: base.minX + marginX, y: base.maxY - marginY - h)
    case .topRight:
      return CGPoint(x: base.maxX - marginX - w, y: base.maxY - marginY - h)
    case .bottomLeft:
      return CGPoint(x: base.minX + marginX, y: base.minY + marginY)
    case .center:
      return CGPoint(x: base.midX - w * 0.5, y: base.midY - h * 0.5)
    default: // bottomRight
      return CGPoint(x: base.maxX - marginX - w, y: base.minY + marginY)
    }
  }
}
