// encode.swift <framesdir> <out.mp4> <hevc|h264> <bitsPerSecond> <fps> [width height]
import AVFoundation
import AppKit
let a = CommandLine.arguments
let dir = a[1], outURL = URL(fileURLWithPath: a[2]), hevc = a[3] == "hevc"
let bps = Int(a[4])!, fps = Int32(a[5])!
let W = a.count > 7 ? Int(a[6])! : 2560, H = a.count > 7 ? Int(a[7])! : 1440
let files = try! FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpg") }.sorted()
try? FileManager.default.removeItem(at: outURL)
let w = try! AVAssetWriter(outputURL: outURL, fileType: .mp4)
w.shouldOptimizeForNetworkUse = true
var comp: [String: Any] = [AVVideoAverageBitRateKey: bps, AVVideoMaxKeyFrameIntervalKey: Int(fps) * 10, AVVideoExpectedSourceFrameRateKey: Int(fps), AVVideoAllowFrameReorderingKey: true]
if !hevc { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
let settings: [String: Any] = [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
  AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
  AVVideoCompressionPropertiesKey: comp]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H])
w.add(input)
w.startWriting(); w.startSession(atSourceTime: .zero)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
for (i, f) in files.enumerated() {
  autoreleasepool {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    let img = NSImage(contentsOfFile: "\(dir)/\(f)")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: W, height: H, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    CVBufferSetAttachment(pb!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    ad.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: fps))
  }
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
w.finishWriting { sem.signal() }
sem.wait()
print(w.status == .completed ? "ok" : "fail \(String(describing: w.error))", files.count)
