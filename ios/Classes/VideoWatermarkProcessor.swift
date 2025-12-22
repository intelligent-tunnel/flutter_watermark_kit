import Foundation
import AVFoundation
import CoreImage
import UIKit
import ImageIO

final class VideoWatermarkProcessor {
  private let queue = DispatchQueue(label: "wm.video", qos: .userInitiated)
  /// 视频合成专用 CIContext，关闭颜色管理以避免曝光/伽马偏移。
  private let videoCIContext: CIContext = {
    let options: [CIContextOption: Any] = [
      .workingColorSpace: NSNull(),
      .outputColorSpace: NSNull(),
      .highQualityDownsample: true,
      .cacheIntermediates: false
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: options)
  }()

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

  /// 处理视频水印合成主流程，保证竖拍视频按可见方向输出。
  /// - Parameters:
  ///   - plugin: 复用的 CIContext 提供方，用于渲染与编码。
  ///   - state: 任务上下文，包含请求与输出路径。
  ///   - callbacks: Flutter 侧进度/完成/错误回调。
  ///   - taskId: 任务唯一标识，用于回调与取消。
  ///   - onComplete: 成功回调，返回合成后的输出信息。
  ///   - onError: 失败回调，返回错误码与错误说明。
  /// - Throws: 读写/渲染失败时抛出异常，由调用方统一上报。
  /// - Note: 输出帧已按 preferredTransform 纠正方向，不再依赖写入时 transform。
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

    // 计算输出渲染尺寸与帧方向变换，统一以“可见方向”作为坐标系。
    let renderInfo = Self.buildRenderInfo(for: videoTrack)
    // 输出帧尺寸，单位为像素，保证与可见方向一致。
    let renderSize = renderInfo.renderSize
    // 应用于原始帧的变换，负责把像素帧旋转/平移到可见方向。
    let renderTransform = renderInfo.renderTransform

    // Prepare overlay CIImage once
    let overlayCI: CIImage? = try Self.prepareOverlayCI(
      request: request,
      plugin: plugin,
      baseWidth: renderSize.width,
      baseHeight: renderSize.height
    )

    let reader = try AVAssetReader(asset: asset)
    let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    videoReaderOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoReaderOutput) else { throw NSError(domain: "wm", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output"]) }
    reader.add(videoReaderOutput)

    let writer = try AVAssetWriter(outputURL: state.outputURL, fileType: .mp4)
    // Video writer input
    let codec: AVVideoCodecType = (request.codec == .hevc) ? .hevc : .h264
    let defaultBitrate = Int64(
      Self.estimateBitrate(
        width: Int(renderSize.width),
        height: Int(renderSize.height),
        fps: Float(videoTrack.nominalFrameRate)
      )
    )
    let bitrate64: Int64 = request.bitrateBps ?? defaultBitrate
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: NSNumber(value: bitrate64),
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: Int(renderSize.width),
      AVVideoHeightKey: Int(renderSize.height),
      AVVideoCompressionPropertiesKey: compression,
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = false
    // 已在渲染阶段完成方向纠正，这里保持输出为直立方向。
    videoInput.transform = .identity
    guard writer.canAdd(videoInput) else { throw NSError(domain: "wm", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"]) }
    writer.add(videoInput)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(renderSize.width),
      kCVPixelBufferHeightKey as String: Int(renderSize.height),
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

    // 使用关闭颜色管理的 CIContext，避免视频亮度被提升。
    let ciContext = videoCIContext

    // Precompute overlay with opacity and translation in display coordinates
    let preparedOverlay: CIImage? = {
      guard let ov = overlayCI else { return nil }
      // Apply opacity
      let alphaVec = CIVector(x: 0, y: 0, z: 0, w: CGFloat(request.opacity))
      let withOpacity = ov.applyingFilter("CIColorMatrix", parameters: ["inputAVector": alphaVec])
      // Compute position
      let baseRect = CGRect(x: 0, y: 0, width: renderSize.width, height: renderSize.height)
      let wmRect = withOpacity.extent
      let marginX = (request.marginUnit == .percent) ? CGFloat(request.margin) * renderSize.width : CGFloat(request.margin)
      let marginY = (request.marginUnit == .percent) ? CGFloat(request.margin) * renderSize.height : CGFloat(request.margin)
      var pos = Self.positionRect(base: baseRect, overlay: wmRect, anchor: request.anchor, marginX: marginX, marginY: marginY)
      let dx = (request.offsetUnit == .percent) ? CGFloat(request.offsetX) * renderSize.width : CGFloat(request.offsetX)
      let dy = (request.offsetUnit == .percent) ? CGFloat(request.offsetY) * renderSize.height : CGFloat(request.offsetY)
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
            // 把原始像素帧旋转/平移到可见方向，避免竖拍横放。
            let orientedBase = CIImage(cvPixelBuffer: srcPB).transformed(by: renderTransform)
            let output: CIImage
            if let overlay = preparedOverlay {
              // Source-over
              let filter = CIFilter(name: "CISourceOverCompositing")!
              filter.setValue(overlay, forKey: kCIInputImageKey)
              filter.setValue(orientedBase, forKey: kCIInputBackgroundImageKey)
              output = (filter.outputImage ?? orientedBase)
                .cropped(to: CGRect(origin: .zero, size: renderSize))
            } else {
              output = orientedBase.cropped(to: CGRect(origin: .zero, size: renderSize))
            }
            ciContext.render(
              output,
              to: dst,
              bounds: CGRect(x: 0, y: 0, width: renderSize.width, height: renderSize.height),
              colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
            )
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
        let res = ComposeVideoResult(
          taskId: taskId,
          outputVideoPath: state.outputURL.path,
          width: Int64(renderSize.width),
          height: Int64(renderSize.height),
          durationMs: Int64(duration * 1000.0),
          codec: request.codec
        )
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

  /// 计算视频渲染尺寸与旋转变换，统一输出为可见方向并修正坐标系。
  /// - Parameter track: 原始视频轨道，用于读取像素尺寸与 preferredTransform。
  /// - Returns: 渲染尺寸与变换，变换已兼容 Core Image 坐标系并保证左下为原点。
  /// - Note: 调用方需在渲染阶段应用该变换，并将写入端 transform 置为 identity。
  private static func buildRenderInfo(for track: AVAssetTrack) -> (renderSize: CGSize, renderTransform: CGAffineTransform) {
    // 视频真实像素尺寸，保证与像素缓冲区宽高一致。
    let pixelSize = Self.videoPixelSize(from: track)
    // 原始像素矩形（未旋转的像素尺寸）。
    let pixelRect = CGRect(origin: .zero, size: pixelSize)
    // 应用轨道方向后的矩形，用于计算偏移与可见尺寸。
    let transformedRect = pixelRect.applying(track.preferredTransform)
    // 输出帧目标尺寸，单位为像素，方向为可见方向。
    let renderSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    // 输入坐标系翻转：把 Core Image 的 y 轴向上转换为 AVFoundation 的 y 轴向下。
    let inputFlip = Self.buildYAxisFlipTransform(height: pixelSize.height)
    // 输出坐标系翻转：把 AVFoundation 结果再转换回 Core Image 坐标。
    let outputFlip = Self.buildYAxisFlipTransform(height: renderSize.height)
    // 纠正方向并统一坐标系，避免竖拍视频出现 180° 翻转。
    let renderTransform = inputFlip
      .concatenating(track.preferredTransform)
      .concatenating(outputFlip)
    // 变换后的画面矩形，用于计算原点偏移。
    let transformedByRender = pixelRect.applying(renderTransform)
    // 规范化后的渲染变换，确保画面落在可视区域内。
    let normalizedTransform = renderTransform.translatedBy(
      x: -transformedByRender.origin.x,
      y: -transformedByRender.origin.y
    )
    return (renderSize, normalizedTransform)
  }

  /// 获取视频真实像素尺寸，避免 naturalSize 与像素缓冲区不一致导致黑屏。
  /// - Parameter track: 视频轨道对象。
  /// - Returns: 像素尺寸，读取失败时回退到 naturalSize。
  private static func videoPixelSize(from track: AVAssetTrack) -> CGSize {
    // 格式描述原始对象，用于获取视频像素维度。
    guard let formatDescAny = track.formatDescriptions.first else {
      return track.naturalSize
    }
    // 强制转换为视频格式描述，CoreFoundation 类型在此处必定可用。
    let formatDesc = formatDescAny as! CMFormatDescription
    // 像素维度信息，用于判定真实像素宽高。
    let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
    if dims.width <= 0 || dims.height <= 0 {
      return track.naturalSize
    }
    return CGSize(width: Int(dims.width), height: Int(dims.height))
  }

  /// 构建 Y 轴翻转变换，用于在 Core Image 与 AVFoundation 坐标系间切换。
  /// - Parameter height: 目标坐标系高度，用于把原点从底部翻到顶部。
  /// - Returns: 含平移与翻转的仿射变换。
  private static func buildYAxisFlipTransform(height: CGFloat) -> CGAffineTransform {
    // 先平移再翻转，保证 y 轴方向与 AVFoundation 对齐。
    return CGAffineTransform(translationX: 0, y: height).scaledBy(x: 1, y: -1)
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
