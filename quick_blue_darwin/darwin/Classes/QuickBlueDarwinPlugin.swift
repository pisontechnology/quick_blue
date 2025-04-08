import CoreBluetooth

#if os(iOS)
import Flutter
#elseif os(OSX)
import FlutterMacOS
#endif

let GATT_HEADER_LENGTH = 3

let GSS_SUFFIX = "0000-1000-8000-00805f9b34fb"

private var targetManufacturerData: Data?

extension CBUUID {
    public var uuidStr: String {
        get {
            uuidString.lowercased()
        }
    }
}

extension CBPeripheral {
    // FIXME https://forums.developer.apple.com/thread/84375
    public var uuid: UUID {
        get {
            value(forKey: "identifier") as! NSUUID as UUID
        }
    }

    public func getCharacteristic(_ characteristic: String, of service: String) -> CBCharacteristic? {
        let s = self.services?.first {
            $0.uuid.uuidStr == service || "0000\($0.uuid.uuidStr)-\(GSS_SUFFIX)" == service
        }
        let c = s?.characteristics?.first {
            $0.uuid.uuidStr == characteristic || "0000\($0.uuid.uuidStr)-\(GSS_SUFFIX)" == characteristic
        }
        return c
    }
    
    public func setNotifiable(_ bleInputProperty: String, for characteristic: String, of service: String) {
        setNotifyValue(bleInputProperty != "disabled", for: getCharacteristic(characteristic, of: service)!)
    }
}

public class QuickBlueDarwinPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
        let messenger = registrar.messenger()
        #elseif os(OSX)
        let messenger = registrar.messenger
        #endif
        
        
        let method = FlutterMethodChannel(name: "quick_blue/method", binaryMessenger: messenger)
        let eventScanResult = FlutterEventChannel(name: "quick_blue/event.scanResult", binaryMessenger: messenger)
        let messageConnector = FlutterBasicMessageChannel(name: "quick_blue/message.connector", binaryMessenger: messenger)
        
        let instance = QuickBlueDarwinPlugin()
        registrar.addMethodCallDelegate(instance, channel: method)
        eventScanResult.setStreamHandler(instance)
        instance.messageConnector = messageConnector
    }
    
    private var manager: CBCentralManager!
    private var discoveredPeripherals: Dictionary<String, CBPeripheral>!
    private var streamDelegates: Dictionary<String, L2CapStreamDelegate>!
    
    private var scanResultSink: FlutterEventSink?
    private var messageConnector: FlutterBasicMessageChannel!
    
    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
        discoveredPeripherals = Dictionary()
        streamDelegates = Dictionary()
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        // Stop scanning
        manager.stopScan()

        // Disconnect all active devices
        for (_, peripheral) in discoveredPeripherals {
            cleanConnection(peripheral)
        }

        // Clean up resources
        scanResultSink = nil
        messageConnector.setMessageHandler(nil)
    }

    private func cleanConnection(_ peripheral: CBPeripheral) {
        if let delegate = streamDelegates[peripheral.uuid.uuidString] {
            delegate.close()
            streamDelegates.removeValue(forKey: peripheral.uuid.uuidString)
        }
        manager.cancelPeripheralConnection(peripheral)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isBluetoothAvailable":
            result(manager.state == .poweredOn)
        case "startScan":
            let arguments = call.arguments as! Dictionary<String, Any>
            let filterServiceUuids = arguments["serviceUuids"] as! Array<String>
            let withServices = filterServiceUuids.map { uuid in CBUUID(string: uuid) }
            // Handle manufacturer data if provided
            if let manufacturerDataDict = arguments["manufacturerData"] as? [Int: FlutterStandardTypedData] {
                if let manufacturerId = manufacturerDataDict.keys.first,
                   let manufacturerData = manufacturerDataDict[manufacturerId] {
                    
                    var mByteArray = withUnsafeBytes(of: UInt16(manufacturerId).littleEndian) { Array($0) }
                    mByteArray.append(contentsOf: manufacturerData.data)
                    
                    let givenManufacturerData = Data(_: mByteArray)
                    targetManufacturerData = givenManufacturerData
                }
            }
            manager.scanForPeripherals(withServices: withServices, options: [CBCentralManagerScanOptionAllowDuplicatesKey : true])
            result(nil)
        case "stopScan":
            manager.stopScan()
            result(nil)
        case "connect":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            peripheral.delegate = self
            manager.connect(peripheral)
            result(nil)
        case "disconnect":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            cleanConnection(peripheral)
            result(nil)
        case "discoverServices":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            peripheral.discoverServices(nil)
            result(nil)
        case "setNotifiable":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            let service = arguments["service"] as! String
            let characteristic = arguments["characteristic"] as! String
            let bleInputProperty = arguments["bleInputProperty"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            guard let cbCharacteristic = peripheral.getCharacteristic(characteristic, of: service) else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown characteristic:\(characteristic)", details: nil))
                return
            }
            peripheral.setNotifiable(bleInputProperty, for: characteristic, of: service)
            result(nil)
        case "requestMtu":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            result(nil)
            let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
            messageConnector.sendMessage(["mtuConfig": mtu + GATT_HEADER_LENGTH])
        case "readValue":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            let service = arguments["service"] as! String
            let characteristic = arguments["characteristic"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            guard let cbCharacteristic = peripheral.getCharacteristic(characteristic, of: service) else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown characteristic:\(characteristic)", details: nil))
                return
            }
            peripheral.readValue(for: cbCharacteristic)
            result(nil)
        case "writeValue":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            let service = arguments["service"] as! String
            let characteristic = arguments["characteristic"] as! String
            let value = arguments["value"] as! FlutterStandardTypedData
            let bleOutputProperty = arguments["bleOutputProperty"] as! String
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            guard let cbCharacteristic = peripheral.getCharacteristic(characteristic, of: service) else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown characteristic:\(characteristic)", details: nil))
                return
            }
            let type = bleOutputProperty == "withoutResponse" ? CBCharacteristicWriteType.withoutResponse : CBCharacteristicWriteType.withResponse
            peripheral.writeValue(value.data, for: cbCharacteristic, type: type)
            result(nil)
        case "openL2cap":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            let psm = arguments["psm"] as! CBL2CAPPSM
            guard let peripheral = discoveredPeripherals[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "Unknown deviceId:\(deviceId)", details: nil))
                return
            }
            peripheral.openL2CAPChannel(psm)
            result(nil)
        case "closeL2cap":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            guard let streamDelegate = streamDelegates[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "No stream delegate for deviceId:\(deviceId)", details: nil))
                return
            }
            streamDelegate.close()
            streamDelegates.removeValue(forKey: deviceId)
            result(nil)
        case "_l2cap_write":
            let arguments = call.arguments as! Dictionary<String, Any>
            let deviceId = arguments["deviceId"] as! String
            let data = arguments["data"] as! FlutterStandardTypedData
            guard let streamDelegate = streamDelegates[deviceId] else {
                result(FlutterError(code: "IllegalArgument", message: "No stream delegate for deviceId:\(deviceId)", details: nil))
                return
            }
            streamDelegate.write(data: data.data)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

extension QuickBlueDarwinPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discoveredPeripherals[peripheral.uuid.uuidString] = peripheral
        
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceUuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if (targetManufacturerData != nil) {
            if (targetManufacturerData == manufacturerData) {
                scanResultSink?([
                    "name": peripheral.name ?? "",
                    "deviceId": peripheral.uuid.uuidString,
                    "manufacturerData": FlutterStandardTypedData(bytes: manufacturerData ?? Data()),
                    "rssi": RSSI,
                    "serviceUuids": serviceUuids.map { $0.uuidString }
                ])
            }
        } else {
            scanResultSink?([
                "name": peripheral.name ?? "",
                "deviceId": peripheral.uuid.uuidString,
                "manufacturerData": FlutterStandardTypedData(bytes: manufacturerData ?? Data()),
                "rssi": RSSI,
                "serviceUuids": serviceUuids.map { $0.uuidString }
            ])
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        messageConnector.sendMessage([
            "deviceId": peripheral.uuid.uuidString,
            "ConnectionState": "connected",
            "status": "success",
        ])
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            central.cancelPeripheralConnection(peripheral)
            if let streamDelegate = streamDelegates[peripheral.uuid.uuidString] {
                streamDelegate.close()
            }
        }
        messageConnector.sendMessage([
            "deviceId": peripheral.uuid.uuidString,
            "ConnectionState": "disconnected",
            "status": error == nil ? "success" : "failure",
        ])
    }
}

extension QuickBlueDarwinPlugin: FlutterStreamHandler {
    open func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        guard let args = arguments as? Dictionary<String, Any>, let name = args["name"] as? String else {
            return nil
        }
        if name == "scanResult" {
            scanResultSink = events
        }
        return nil
    }
    
    open func onCancel(withArguments arguments: Any?) -> FlutterError? {
        guard let args = arguments as? Dictionary<String, Any>, let name = args["name"] as? String else {
            return nil
        }
        if name == "scanResult" {
            scanResultSink = nil
        }
        return nil
    }
}

extension QuickBlueDarwinPlugin: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services! {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        self.messageConnector.sendMessage([
            "deviceId": peripheral.uuid.uuidString,
            "ServiceState": "discovered",
            "service": service.uuid.uuidStr,
            "characteristics": service.characteristics!.map { $0.uuid.uuidStr }
        ])
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // TODO(cg): send this as a message
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        self.messageConnector.sendMessage([
            "deviceId": peripheral.uuid.uuidString,
            "characteristicValue": [
                "characteristic": characteristic.uuid.uuidStr,
                "value": FlutterStandardTypedData(bytes: characteristic.value!)
            ]
        ])
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel = channel else {
            return
        }
        
        let streamDelegate = L2CapStreamDelegate(channel: channel, openedCallback: {
            self.messageConnector.sendMessage([
                "deviceId": peripheral.uuid.uuidString,
                "l2capStatus": "opened",
            ])
        }, streamCallback: {
            data in
            self.messageConnector.sendMessage([
                "deviceId": peripheral.uuid.uuidString,
                "l2capStatus": "stream",
                "data": data,
            ])
        }, closedCallback: {
            self.messageConnector.sendMessage([
                "deviceId": peripheral.uuid.uuidString,
                "l2capStatus": "closed",
            ])
        }, errorCallback: { error in
            self.messageConnector.sendMessage([
                "deviceId": peripheral.uuid.uuidString,
                "l2capStatus": "error",
                "error": error?.localizedDescription
            ])
        })
        streamDelegates[peripheral.uuid.uuidString] = streamDelegate
    }
}

class L2CapStreamDelegate: NSObject, StreamDelegate {
    var channel: CBL2CAPChannel?
    var inputStream: InputStream?
    var outputStream: OutputStream?
    
    var openedCallback: () -> ()?
    var streamCallback: (Data) -> ()?
    var closedCallback: () -> ()?
    var errorCallback: (Error?) -> ()?
    
    var streamOpenCount = 0
    var dataToSend = Data()
    
    init(channel: CBL2CAPChannel, openedCallback: @escaping () -> (), streamCallback: @escaping (Data) -> (), closedCallback: @escaping () -> (), errorCallback: @escaping (Error?) -> ()) {
        self.channel = channel
        self.openedCallback = openedCallback
        self.streamCallback = streamCallback
        self.closedCallback = closedCallback
        self.errorCallback = errorCallback
        
        super.init()
        
        self.inputStream = channel.inputStream
        self.inputStream!.delegate = self
        self.inputStream!.schedule(in: .main, forMode: .default)
        self.inputStream!.open()
        
        self.outputStream = channel.outputStream
        self.outputStream!.delegate = self
        self.outputStream!.schedule(in: .main, forMode: .default)
        self.outputStream!.open()
    }
    
    func close() {
        self.inputStream?.close()
        self.outputStream?.close()
        
        self.inputStream?.remove(from: .main, forMode: .default)
        self.outputStream?.remove(from: .main, forMode: .default)
        
        self.inputStream?.delegate = nil
        self.outputStream?.delegate = nil
        
        self.channel = nil
    }
    
    func checkSend() {
        while dataToSend.count > 0 {
            if !outputStream!.hasSpaceAvailable {
                break;
            }
            let n = dataToSend.withUnsafeBytes { outputStream!.write(($0.baseAddress?.assumingMemoryBound(to: UInt8.self))!, maxLength: dataToSend.count) }
            if n > 0 {
                dataToSend.removeSubrange(0 ..< n)
            }
        }
    }
    
    func write(data: Data) {
        dataToSend.append(data)
        checkSend()
    }
    
    @MainActor
    func streamOpenCompleted() {
        self.openedCallback()
    }
    
    @MainActor
    func streamEndEncountered() {
        self.closedCallback()
    }
    
    @MainActor
    func streamRecevied(data: Data) {
        self.streamCallback(data)
    }
    
    @MainActor
    func streamHasSpaceAvailable() {
        self.checkSend()
    }
    
    @MainActor
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch (eventCode) {
        case .openCompleted:
            self.streamOpenCount += 1
            if self.streamOpenCount == 2 {
                self.streamOpenCompleted()
            }
        case .hasBytesAvailable:
            let bufferSize = 8192
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            while (self.inputStream!.hasBytesAvailable) {
                let n = self.inputStream!.read(buffer, maxLength: bufferSize)
                if n == 0 {
                    break
                }
                let data = Data(bytes: buffer, count: n)
                self.streamRecevied(data: data)
            }
            buffer.deallocate()
        case .hasSpaceAvailable:
            self.streamHasSpaceAvailable()
        case .errorOccurred:
            self.errorCallback(aStream.streamError)
        case .endEncountered:
            self.streamEndEncountered()
        default:
            NSLog("unknown stream event")
        }
    }
}
