import Flutter
import UIKit
import UniformTypeIdentifiers
import QuickLook

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SharedFolderPlugin") {
      SharedFolderPlugin.register(with: registrar)
    }
  }
}

/// [iOS SHARED FOLDER]: lets the app use a folder picked in the Files
/// app - the doit-files share connected there with "Connect to Server" - and
/// keeps using it after a restart.
///
/// iOS only lets an app into a folder the user picked, and only for as long as
/// the app holds a security-scoped bookmark for it. The bookmark is kept in
/// UserDefaults; access is started on pick and on restore and held for the
/// life of the app, so Dart's own file APIs can read and write under the path.
///
/// Channel "rcb/shared_folder" (lib/services/ios_share.dart):
///   pick    -> the picked folder's path, or nil when cancelled
///   restore -> the remembered folder's path, or nil (none, or it is gone)
///   clear   -> forgets the folder
class SharedFolderPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate,
  QLPreviewControllerDataSource {
  private static let bookmarkKey = "rcbSharedFolderBookmark"
  private var pendingResult: FlutterResult?
  private var activeURL: URL?
  private var previewURL: URL?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "rcb/shared_folder", binaryMessenger: registrar.messenger())
    let instance = SharedFolderPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pick": pick(result)
    case "restore":
      // Off the main thread: resolving a bookmark to an SMB share can wait on
      // the network, and the main thread draws the app.
      DispatchQueue.global(qos: .userInitiated).async {
        let path = self.restore()
        DispatchQueue.main.async { result(path) }
      }
    case "deviceName":
      // [iOS TEAM NAME]: iOS reports "localhost" as the host name, so team
      // presence (login@machine) needs a name of its own: "iPad-1A2B" - the
      // model and the start of this app's per-device id, stable across runs.
      let id = UIDevice.current.identifierForVendor?.uuidString ?? "0000"
      result("\(UIDevice.current.model)-\(id.prefix(4))")
    case "preview":
      // iOS has no "open with the default program": a PDF, a photo or an
      // Office file goes to Quick Look, which shows it and offers Share / Open
      // In from its own toolbar. Files under the picked share stay readable
      // while it is shown - the folder's access is held for the whole run.
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String
      else {
        result(FlutterError(code: "args", message: "No file given", details: nil))
        return
      }
      preview(path, result)
    case "clear":
      stopAccess()
      UserDefaults.standard.removeObject(forKey: SharedFolderPlugin.bookmarkKey)
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "busy", message: "A folder picker is already open", details: nil))
      return
    }
    guard let presenter = SharedFolderPlugin.topViewController() else {
      result(FlutterError(code: "no_view", message: "Nothing to show the picker from", details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pendingResult = result
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingResult else { return }
    pendingResult = nil
    guard let url = urls.first else { result(nil); return }
    stopAccess()
    guard url.startAccessingSecurityScopedResource() else {
      result(FlutterError(code: "denied", message: "iOS did not allow access to that folder", details: nil))
      return
    }
    activeURL = url
    do {
      let bookmark = try url.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: SharedFolderPlugin.bookmarkKey)
    } catch {
      // Still usable for this run; it just won't be remembered.
      NSLog("SharedFolderPlugin: bookmark not saved: \(error)")
    }
    result(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingResult?(nil)
    pendingResult = nil
  }

  private func restore() -> String? {
    if let url = activeURL { return url.path }
    guard let data = UserDefaults.standard.data(forKey: SharedFolderPlugin.bookmarkKey) else {
      return nil
    }
    var stale = false
    // withoutMounting: don't block reconnecting the share here; the Dart side
    // checks whether it answers, with a time limit.
    guard let url = try? URL(
      resolvingBookmarkData: data, options: [.withoutMounting], relativeTo: nil,
      bookmarkDataIsStale: &stale),
      url.startAccessingSecurityScopedResource()
    else { return nil }
    activeURL = url
    if stale, let fresh = try? url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      UserDefaults.standard.set(fresh, forKey: SharedFolderPlugin.bookmarkKey)
    }
    return url.path
  }

  private func preview(_ path: String, _ result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: path) else {
      result("No longer there: \(path)")
      return
    }
    guard QLPreviewController.canPreview(url as QLPreviewItem) else {
      result("iOS cannot show this kind of file: \(url.lastPathComponent)")
      return
    }
    guard let presenter = SharedFolderPlugin.topViewController() else {
      result("Nothing to show the file from")
      return
    }
    previewURL = url
    let controller = QLPreviewController()
    controller.dataSource = self
    presenter.present(controller, animated: true)
    result(nil)
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewURL == nil ? 0 : 1
  }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
    -> QLPreviewItem
  {
    (previewURL ?? URL(fileURLWithPath: "/")) as QLPreviewItem
  }

  private func stopAccess() {
    activeURL?.stopAccessingSecurityScopedResource()
    activeURL = nil
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
