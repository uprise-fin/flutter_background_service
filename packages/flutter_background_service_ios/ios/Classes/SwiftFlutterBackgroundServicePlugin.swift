import Flutter
import UIKit
import AVKit
import BackgroundTasks

public class SwiftFlutterBackgroundServicePlugin: FlutterPluginAppLifeCycleDelegate, FlutterPlugin  {
    static var taskIndentifier = "dev.flutter.background.refresh"
    // For testing, run app, bring app to background to schedule the task
    // Pause debug in XCODE, then execute:
    // e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"dev.flutter.background.refresh"]
    // in Outputs log after (lldb)
    // Resume debugger
    
    var mainChannel: FlutterMethodChannel? = nil
    
    public override func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        // execute callback handle
        
        let worker = FlutterBackgroundFetchWorker(task: completionHandler)
        worker.onCompleted = {
            print("Background Fetch Completed")
        }
        worker.run()
        return true
    }
        
    public override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
        UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        if #available(iOS 13.0, *) {
            registerBackgroundTasks()
        }
        
        return true
    }
    
    public func applicationDidEnterBackground(_ application: UIApplication) {
        if #available(iOS 13.0, *){
            self.scheduleAppRefresh()
        }
    }
    
    @available(iOS 13.0, *)
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SwiftFlutterBackgroundServicePlugin.taskIndentifier, using: DispatchQueue.main) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    @available(iOS 13.0, *)
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: SwiftFlutterBackgroundServicePlugin.taskIndentifier)
       request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            
       do {
          try BGTaskScheduler.shared.submit(request)
       } catch {
          print("Could not schedule app refresh: \(error)")
       }
    }
    
    @available(iOS 13.0, *)
    func handleAppRefresh(task: BGAppRefreshTask) {
        let worker = FlutterBackgroundRefreshAppWorker(task: task)
        worker.onCompleted = {
            print("COMPLETED")
            self.scheduleAppRefresh()
        }
        
        task.expirationHandler = {
            worker.cancel()
        }
        
        worker.run()
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "id.flutter/background_service_ios",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec())
        
        let instance = SwiftFlutterBackgroundServicePlugin()
        instance.mainChannel = channel
        
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    private func autoStart(isForeground: Bool) {
        let defaults = UserDefaults.standard
        let autoStart = defaults.bool(forKey: "auto_start")
        if (autoStart) {
            self.runForegroundWorker()
        }
    }
    
    fileprivate var foregroundWorker: FlutterForegroundWorker? = nil
    private func runForegroundWorker(){
        if (foregroundWorker != nil){
            return
        }
        
        foregroundWorker = FlutterForegroundWorker(mainChannel: self.mainChannel!)
        foregroundWorker?.onTerminated = {
            self.foregroundWorker = nil
        }
        foregroundWorker?.run()
    }
    
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "configure") {
            let args = call.arguments as? Dictionary<String, Any>
            let foregroundCallbackHandleID = args?["foreground_handle"] as? NSNumber
            let backgroundCallbackHandleID = args?["background_handle"] as? NSNumber
            let autoStart = args?["auto_start"] as? Bool
            
            let defaults = UserDefaults.standard
            defaults.set(foregroundCallbackHandleID?.int64Value, forKey: "foreground_callback_handle")
            defaults.set(backgroundCallbackHandleID?.int64Value, forKey: "background_callback_handle")
            defaults.set(autoStart, forKey: "auto_start")
            
            self.autoStart(isForeground: true)
            
            result(true)
            return
        }
        
        if (call.method == "start") {
            runForegroundWorker()
            result(true)
        }
        
        if (call.method == "sendData") {
            self.foregroundWorker?.onReceivedData(data: call.arguments)
            result(true);
        }
                
        if (call.method == "isServiceRunning") {
            let value = self.foregroundWorker != nil;
            result(value);
            return;
        }
    }
}

typealias VoidInputVoidReturnBlock = () -> Void

@available(iOS 13, *)
private class FlutterBackgroundRefreshAppWorker {
    let entrypointName = "backgroundEntrypoint"
    let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
    let engine = FlutterEngine(name: "BackgroundHandleFlutterEngine")
    
    var onCompleted: VoidInputVoidReturnBlock?
    var task: BGAppRefreshTask
    var channel: FlutterMethodChannel?
    
    init(task: BGAppRefreshTask){
        self.task = task
    }
    
    public func run() {
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("No callback handle for background")
            return
        }
        
        let isRunning = engine.run(withEntrypoint: entrypointName, libraryURI: uri, initialRoute: nil, entrypointArgs: [String(callbackHandle!)])
        
        if (isRunning){
            FlutterBackgroundServicePlugin.register(engine)
            
            let binaryMessenger = engine.binaryMessenger
            channel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            channel?.setMethodCallHandler(handleMethodCall)
        }
    }
    
    public func cancel(){
        self.engine.destroyContext()
        self.task.setTaskCompleted(success: false)
        self.onCompleted?()
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "setBackgroundFetchResult") {
            let result = call.arguments as? Bool ?? false
            
            if (result) {
                self.task.setTaskCompleted(success: true)
            } else {
                self.task.setTaskCompleted(success: false)
            }
            
            self.engine.destroyContext()
            self.onCompleted?()
            print("Flutter Background Service Completed")
        }
    }
}

private class FlutterBackgroundFetchWorker {
    let entrypointName = "backgroundEntrypoint"
    let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
    let engine = FlutterEngine(name: "BackgroundHandleFlutterEngine")
    
    var onCompleted: VoidInputVoidReturnBlock?
    var task: ((UIBackgroundFetchResult) -> Void)
    var channel: FlutterMethodChannel?
    
    init(task: @escaping (UIBackgroundFetchResult) -> Void){
        self.task = task
    }
    
    public func run() {
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("No callback handle for background")
            return
        }
        
        let isRunning = engine.run(withEntrypoint: entrypointName, libraryURI: uri, initialRoute: nil, entrypointArgs: [String(callbackHandle!)])
        
        if (isRunning){
            FlutterBackgroundServicePlugin.register(engine)
            
            let binaryMessenger = engine.binaryMessenger
            channel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            channel?.setMethodCallHandler(handleMethodCall)
        }
    }
    
    public func cancel(){
        self.engine.destroyContext()
        self.task(.failed)
        self.onCompleted?()
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "setBackgroundFetchResult") {
            let result = call.arguments as? Bool ?? false
            
            if (result) {
                self.task(.newData)
            } else {
                self.task(.noData)
            }
            
            self.engine.destroyContext()
            self.onCompleted?()
            print("Flutter Background Service Completed")
        }
    }
}

private class FlutterForegroundWorker {
    let entrypointName = "foregroundEntrypoint"
    let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
    let engine = FlutterEngine(name: "ForegroundHandleFlutterEngine")
    
    var channel: FlutterMethodChannel?
    var mainChannel: FlutterMethodChannel
    var onTerminated: VoidInputVoidReturnBlock?
    
    init(mainChannel: FlutterMethodChannel){
        self.mainChannel = mainChannel
    }
    
    public func run() {
        let defaults = UserDefaults.standard
        let callbackHandle = defaults.object(forKey: "foreground_callback_handle") as? Int64
        if (callbackHandle == nil){
            print("No callback handle for foreground")
            return
        }
        
        let isRunning = engine.run(withEntrypoint: entrypointName, libraryURI: uri, initialRoute: nil, entrypointArgs: [String(callbackHandle!)])
        
        if (isRunning){
            FlutterBackgroundServicePlugin.register(engine)
            
            let binaryMessenger = engine.binaryMessenger
            channel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            channel?.setMethodCallHandler(handleMethodCall)
        }
    }
    
    public func onReceivedData(data: Any?) {
        self.channel?.invokeMethod("onReceiveData", arguments: data)
    }
    
    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "sendData") {
            self.mainChannel.invokeMethod("onReceiveData", arguments: call.arguments)
            result(true);
            return;
        }
        
        if (call.method == "stopService") {
            self.engine.destroyContext()
            result(true)
            self.onTerminated?()
            return;
        }
    }
}
