import AVFoundation
import CoreVideo
import FlutterMacOS
import Foundation

/// 영상 프레임을 Flutter 텍스처로 올린다.
///
/// SIP 스택(baresip, dart:ffi)은 이 플러그인을 모른다. Dart 가 `attach` 로
/// 텍스처 두 개(내 카메라·상대)와 C 싱크 함수의 주소를 받아 `bs_set_video_sink`
/// 로 스택에 넘긴다. 싱크는 baresip 의 영상 스레드에서 불린다.
///
/// 텍스처는 앱이 떠 있는 동안 두 개만 만들어 계속 쓴다 — 통화마다 만들고
/// 지우면 영상 스레드가 사라진 텍스처를 건드릴 틈이 생긴다.
public class FlutterBaresipPlugin: NSObject, FlutterPlugin {
  private let registry: FlutterTextureRegistry
  private var textures: [VideoTexture] = []

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "flutter_baresip/video", binaryMessenger: registrar.messenger)
    let instance = FlutterBaresipPlugin(registry: registrar.textures)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "attach":
      if textures.isEmpty {
        textures = [VideoTexture(registry: registry), VideoTexture(registry: registry)]
      }
      let context = Unmanaged.passUnretained(self).toOpaque()
      result([
        "localTextureId": textures[0].id,
        "remoteTextureId": textures[1].id,
        "sink": Int(bitPattern: unsafeBitCast(videoSink, to: UnsafeRawPointer.self)),
        "context": Int(bitPattern: context),
      ])
    case "cameraAccess":
      // 카메라는 baresip(avcapture)이 여는데, 권한을 묻지 않은 채 열면 프레임이
      // 오지 않는다. 영상 통화 전에 여기서 묻고 결과를 돌려준다.
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized:
        result("authorized")
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async { result(granted ? "authorized" : "denied") }
        }
      case .denied:
        result("denied")
      case .restricted:
        result("restricted")
      @unknown default:
        result("unknown")
      }
    case "clear":
      // 통화가 끝나면 지난 그림이 다음 통화 첫 화면에 비치지 않게 비운다.
      textures.forEach { $0.clear() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  fileprivate func deliver(
    which: Int32, bgra: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int
  ) {
    guard which >= 0, Int(which) < textures.count else { return }
    textures[Int(which)].push(bgra: bgra, width: width, height: height, stride: stride)
  }
}

/// C 에서 부르는 싱크. `bs_video_sink` 와 모양이 같아야 한다.
private let videoSink:
  @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<UInt8>?, Int32, Int32, Int32
  ) -> Void = { context, which, bgra, width, height, stride in
    guard let context, let bgra, width > 0, height > 0 else { return }
    let plugin = Unmanaged<FlutterBaresipPlugin>.fromOpaque(context).takeUnretainedValue()
    plugin.deliver(
      which: which, bgra: bgra, width: Int(width), height: Int(height), stride: Int(stride))
  }

/// 마지막 프레임 하나를 들고 있는 텍스처.
final class VideoTexture: NSObject, FlutterTexture {
  private weak var registry: FlutterTextureRegistry?
  private(set) var id: Int64 = 0
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var pool: CVPixelBufferPool?
  private var poolSize = (0, 0)

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
    id = registry.register(self)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  func clear() {
    lock.lock()
    latest = nil
    lock.unlock()
    registry?.textureFrameAvailable(id)
  }

  func push(bgra: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
    guard let buffer = makeBuffer(width: width, height: height) else { return }

    CVPixelBufferLockBaseAddress(buffer, [])
    if let dst = CVPixelBufferGetBaseAddress(buffer) {
      let dstStride = CVPixelBufferGetBytesPerRow(buffer)
      let rowBytes = min(width * 4, stride, dstStride)
      for row in 0..<height {
        memcpy(dst + row * dstStride, bgra + row * stride, rowBytes)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    lock.lock()
    latest = buffer
    lock.unlock()
    registry?.textureFrameAvailable(id)
  }

  private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    if pool == nil || poolSize != (width, height) {
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      var newPool: CVPixelBufferPool?
      CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &newPool)
      pool = newPool
      poolSize = (width, height)
    }
    guard let pool else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    return buffer
  }
}
