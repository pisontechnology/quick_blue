import CoreBluetooth

#if os(iOS)
    import Flutter
#elseif os(OSX)
    import FlutterMacOS
#endif

let GSS_SUFFIX = "0000-1000-8000-00805f9b34fb"

extension CBUUID {
    public var uuidStr: String {
        uuidString.lowercased()
    }
}

extension CBPeripheral {
    public func getCharacteristic(_ characteristic: String, of service: String)
        -> CBCharacteristic?
    {
        let s = self.services?.first {
            $0.uuid.uuidStr == service
                || "0000\($0.uuid.uuidStr)-\(GSS_SUFFIX)" == service
        }
        let c = s?.characteristics?.first {
            $0.uuid.uuidStr == characteristic
                || "0000\($0.uuid.uuidStr)-\(GSS_SUFFIX)" == characteristic
        }
        return c
    }

    func setNotifiable(
        _ bleInputProperty: PlatformBleInputProperty,
        for characteristic: String,
        of service: String
    ) {
        setNotifyValue(
            bleInputProperty != PlatformBleInputProperty.disabled,
            for: getCharacteristic(characteristic, of: service)!
        )
    }
}

public class QuickBlueDarwinPlugin: NSObject, FlutterPlugin, QuickBlueApi {
    func getConnectedPeripherals(serviceUuids: [String]) throws -> [Peripheral]
    {
        let peripherals = manager.retrieveConnectedPeripherals(
            withServices: serviceUuids.map { uuid in CBUUID(string: uuid) }
        )
        return peripherals.map { peripherals in
            Peripheral(
                id: peripherals.identifier.uuidString,
                name: peripherals.name ?? ""
            )
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
            let messenger = registrar.messenger()
        #elseif os(OSX)
            let messenger = registrar.messenger
        #endif

        let flutterApi = QuickBlueFlutterApi(binaryMessenger: messenger)
        let instance = QuickBlueDarwinPlugin(flutterApi: flutterApi)
        QuickBlueApiSetup.setUp(binaryMessenger: messenger, api: instance)
        ScanResultListener.register(
            with: messenger,
            streamHandler: instance.scanResultListener
        )
        L2CapSocketEventsListener.register(
            with: messenger,
            streamHandler: instance.l2CapSocketEventsListener
        )
    }

    private let stateQueue = DispatchQueue(label: "quick_blue.state.queue")

    private var flutterApi: QuickBlueFlutterApi
    private var scanResultListener: ScanResultListener
    private var l2CapSocketEventsListener: L2CapSocketEventsListener

    private var manager: CBCentralManager!
    private var discoveredPeripherals: [String: CBPeripheral]!
    private var streamDelegates: [String: L2CapStreamDelegate]!

    private var targetManufacturerData: Data?

    init(flutterApi: QuickBlueFlutterApi) {
        self.flutterApi = flutterApi
        self.scanResultListener = ScanResultListener()
        self.l2CapSocketEventsListener = L2CapSocketEventsListener()

        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
        discoveredPeripherals = Dictionary()
        streamDelegates = Dictionary()
    }

    func isBluetoothAvailable() throws -> Bool {
        return manager.state == .poweredOn
    }

    func startScan(
        serviceUuids: [String]?,
        manufacturerData: [Int64: FlutterStandardTypedData]?
    ) throws {
        let withServices = serviceUuids?.map { uuid in CBUUID(string: uuid) }
        // Handle manufacturer data if provided
        if let manufacturerId = manufacturerData?.keys.first,
            let data = manufacturerData?[manufacturerId]
        {
            var mByteArray = withUnsafeBytes(
                of: UInt16(manufacturerId).littleEndian
            ) { Array($0) }
            mByteArray.append(contentsOf: data.data)

            let givenManufacturerData = Data(_: mByteArray)
            targetManufacturerData = givenManufacturerData
        }

        manager.scanForPeripherals(
            withServices: withServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() throws {
        manager.stopScan()
    }

    func connect(deviceId: String) throws {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown deviceId:\(deviceId)",
                    details: nil
                )
            }
            // Prevent duplicate connects
            if peripheral.state == .connected || peripheral.state == .connecting {
                return
            }
            peripheral.delegate = self
            manager.connect(peripheral)
        }
    }

    func disconnect(deviceId: String) throws {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown deviceId:\(deviceId)",
                    details: nil
                )
            }
            cleanConnection(peripheral)
        }
    }

    func discoverServices(deviceId: String) throws {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown deviceId:\(deviceId)",
                    details: nil
                )
            }
            peripheral.discoverServices(nil)
        }
    }

    func setNotifiable(
        deviceId: String,
        service: String,
        characteristic: String,
        bleInputProperty: PlatformBleInputProperty
    ) throws {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown deviceId:\(deviceId)",
                    details: nil
                )
            }
            guard
                let cbCharacteristic = peripheral.getCharacteristic(
                    characteristic,
                    of: service
                )
            else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown characteristic:\(characteristic)",
                    details: nil
                )
            }
            peripheral.setNotifiable(
                bleInputProperty,
                for: characteristic,
                of: service
            )
        }
    }

    func readValue(deviceId: String, service: String, characteristic: String)
        throws
    {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown deviceId:\(deviceId)",
                    details: nil
                )
            }
            guard
                let cbCharacteristic = peripheral.getCharacteristic(
                    characteristic,
                    of: service
                )
            else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown characteristic:\(characteristic)",
                    details: nil
                )
            }
            peripheral.readValue(for: cbCharacteristic)
        }
    }

    func writeValue(
        deviceId: String,
        service: String,
        characteristic: String,
        value: FlutterStandardTypedData,
        bleOutputProperty: PlatformBleOutputProperty
    ) throws {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown deviceId:\(deviceId)",
                    details: nil
                )
            }
            guard
                let cbCharacteristic = peripheral.getCharacteristic(
                    characteristic,
                    of: service
                )
            else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "Unknown characteristic:\(characteristic)",
                    details: nil
                )
            }
            let type =
                bleOutputProperty == PlatformBleOutputProperty.withoutResponse
                ? CBCharacteristicWriteType.withoutResponse
                : CBCharacteristicWriteType.withResponse
            peripheral.writeValue(value.data, for: cbCharacteristic, type: type)
        }
    }

    func openL2cap(
        deviceId: String,
        psm: Int64
    ) throws {
        try stateQueue.sync {
            guard let peripheral = discoveredPeripherals[deviceId] else {
                throw
                    PigeonError(
                        code: "IllegalArgument",
                        message: "Unknown deviceId:\(deviceId)",
                        details: nil
                    )
            }
            peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
        }
    }

    func closeL2cap(deviceId: String) throws {
        try stateQueue.sync {
            guard let streamDelegate = streamDelegates[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "No stream delegate for deviceId:\(deviceId)",
                    details: nil
                )
            }
            streamDelegate.close()
            streamDelegates.removeValue(forKey: deviceId)
        }
    }

    func writeL2cap(deviceId: String, value: FlutterStandardTypedData) throws {
        try stateQueue.sync {
            guard let streamDelegate = streamDelegates[deviceId] else {
                throw PigeonError(
                    code: "IllegalArgument",
                    message: "No stream delegate for deviceId:\(deviceId)",
                    details: nil
                )
            }
            streamDelegate.write(data: value.data)
        }
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        // Stop scanning
        manager.stopScan()

        // Disconnect all active devices
        try stateQueue.sync {
            for (_, peripheral) in discoveredPeripherals {
                cleanConnection(peripheral)
            }
        }
    }

    private func cleanConnection(_ peripheral: CBPeripheral) {
        if let delegate = streamDelegates[peripheral.identifier.uuidString] {
            delegate.close()
            streamDelegates.removeValue(forKey: peripheral.identifier.uuidString)
        }
        manager.cancelPeripheralConnection(peripheral)
    }
}

extension QuickBlueDarwinPlugin: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        try stateQueue.sync {
            discoveredPeripherals[peripheral.identifier.uuidString] = peripheral

            let manufacturerData =
                advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            let serviceUuids =
                advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
                ?? []
            if targetManufacturerData != nil {
                if targetManufacturerData == manufacturerData {
                    scanResultListener.onEvent(
                        event: PlatformScanResult(
                            name: peripheral.name ?? "",
                            deviceId: peripheral.identifier.uuidString,
                            manufacturerDataHead: FlutterStandardTypedData(
                                bytes: manufacturerData ?? Data()
                            ),
                            manufacturerData: FlutterStandardTypedData(
                                bytes: Data()
                            ),
                            rssi: Int64(truncating: RSSI),
                            serviceUuids: serviceUuids.map { $0.uuidString }
                        )
                    )
                }
            } else {
                scanResultListener.onEvent(
                    event: PlatformScanResult(
                        name: peripheral.name ?? "",
                        deviceId: peripheral.identifier.uuidString,
                        manufacturerDataHead: FlutterStandardTypedData(
                            bytes: Data()
                        ),
                        manufacturerData: FlutterStandardTypedData(bytes: Data()),
                        rssi: Int64(truncating: RSSI),
                        serviceUuids: serviceUuids.map { $0.uuidString }
                    )
                )
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        flutterApi.onConnectionStateChange(
            stateChange: PlatformConnectionStateChange(
                deviceId: peripheral.identifier.uuidString,
                state: PlatformConnectionState.connected,
                gattStatus: PlatformGattStatus.success
            ),
            completion: { _ in }
        )

    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        try stateQueue.sync {
            if let error = error {
                central.cancelPeripheralConnection(peripheral)
                if let streamDelegate = streamDelegates[peripheral.identifier.uuidString]
                {
                    streamDelegate.close()
                }
            }
            flutterApi.onConnectionStateChange(
                stateChange: PlatformConnectionStateChange(
                    deviceId: peripheral.identifier.uuidString,
                    state: PlatformConnectionState.disconnected,
                    gattStatus: error == nil
                        ? PlatformGattStatus.success : PlatformGattStatus.failure
                ),
                completion: { _ in }
            )
        }
    }
}

extension QuickBlueDarwinPlugin: CBPeripheralDelegate {
    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        for service in peripheral.services! {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        flutterApi.onServiceDiscovered(
            serviceDiscovered: PlatformServiceDiscovered(
                deviceId: peripheral.identifier.uuidString,
                serviceUuid: service.uuid.uuidStr,
                characteristics: service.characteristics!.map {
                    $0.uuid.uuidStr
                }
            ),
            completion: { _ in }
        )

    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // TODO(cg): send this as a message
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let value = characteristic.value {
            flutterApi.onCharacteristicValueChanged(
                valueChanged: PlatformCharacteristicValueChanged(
                    deviceId: peripheral.identifier.uuidString,
                    characteristicId: characteristic.uuid.uuidStr,
                    value: FlutterStandardTypedData(bytes: value)
                ),
                completion: { _ in }
            )
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        try stateQueue.sync {
            guard let channel = channel else {
                return
            }

            let streamDelegate = L2CapStreamDelegate(
                channel: channel,
                onOpen: {
                    self.l2CapSocketEventsListener.onEvent(
                        event: PlatformL2CapSocketEvent(
                            deviceId: peripheral.identifier.uuidString,
                            opened: true
                        )
                    )
                },
                onData: {
                    data in
                    self.l2CapSocketEventsListener.onEvent(
                        event: PlatformL2CapSocketEvent(
                            deviceId: peripheral.identifier.uuidString,
                            data: FlutterStandardTypedData(bytes: data)
                        )
                    )
                },
                onClose: {
                    self.l2CapSocketEventsListener.onEvent(
                        event: PlatformL2CapSocketEvent(
                            deviceId: peripheral.identifier.uuidString,
                            closed: true
                        )
                    )
                },
                onError: { error in
                    self.l2CapSocketEventsListener.onEvent(
                        event: PlatformL2CapSocketEvent(
                            deviceId: peripheral.identifier.uuidString,
                            error: error?.localizedDescription
                        )
                    )

                }
            )
            streamDelegates[peripheral.identifier.uuidString] = streamDelegate
        }
    }
}

class L2CapStreamDelegate: NSObject, @preconcurrency StreamDelegate {
    // MARK: - Properties

    // Streams are non-optional and private for encapsulation.
    private let inputStream: InputStream
    private let outputStream: OutputStream

    // Keep a reference to the channel to manage its lifecycle.
    private var channel: CBL2CAPChannel?

    // Callbacks with clearer, more modern Swift naming.
    private let onOpen: () -> Void
    private let onData: (Data) -> Void
    private let onClose: () -> Void
    private let onError: (Error?) -> Void

    // MARK: - State
    private var openStreams = Set<Stream>()
    private var outgoingData = Data()
    private var hasNotifiedClose = false

    // MARK: - Performance Optimization
    // Allocate the read buffer once to avoid repeated memory allocation/deallocation.
    private let readBuffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 8192  // This can be tuned based on the L2CAP PSM's MTU.

    // MARK: - Initialization and Cleanup

    init(
        channel: CBL2CAPChannel,
        onOpen: @escaping () -> Void,
        onData: @escaping (Data) -> Void,
        onClose: @escaping () -> Void,
        onError: @escaping (Error?) -> Void
    ) {
        self.channel = channel
        self.inputStream = channel.inputStream
        self.outputStream = channel.outputStream

        self.onOpen = onOpen
        self.onData = onData
        self.onClose = onClose
        self.onError = onError

        self.readBuffer = .allocate(capacity: bufferSize)

        super.init()

        setupStream(inputStream)
        setupStream(outputStream)
    }

    deinit {
        // Ensure the buffer is deallocated when this object is destroyed.
        readBuffer.deallocate()
        // The public close() method handles the rest of the cleanup.
    }

    private func setupStream(_ stream: Stream) {
        stream.delegate = self
        // All stream events will be handled on the main thread.
        stream.schedule(in: .main, forMode: .default)
        stream.open()
    }

    // MARK: - Public API

    /// Enqueues data to be sent over the L2CAP channel.
    public func write(data: Data) {
        // Ensure this operation is thread-safe by dispatching to the main actor.
        DispatchQueue.main.async {
            self.outgoingData.append(data)
            self.sendData()
        }
    }

    /// Closes the connection and cleans up all resources.
    public func close() {
        // This method is now the single entry point for a "clean" shutdown.
        DispatchQueue.main.async {
            self.handleClose()
        }
    }

    // MARK: - Stream Event Handling

    @MainActor
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            openStreams.insert(aStream)
            // When both streams are open, the channel is ready.
            if openStreams.count == 2 {
                onOpen()
            }
        case .hasBytesAvailable:
            readAvailableBytes()

        case .hasSpaceAvailable:
            sendData()

        case .errorOccurred:
            onError(aStream.streamError)
            // An error is a terminal event; close everything.
            handleClose()

        case .endEncountered:
            // If one stream ends, the channel is no longer usable.
            handleClose()

        default:
            #if DEBUG
                print("L2CAP Stream: Unhandled event \(eventCode)")
            #endif
        }
    }

    // MARK: - Private Helpers

    @MainActor
    private func readAvailableBytes() {
        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(readBuffer, maxLength: bufferSize)

            if bytesRead > 0 {
                // Create a Data object by copying the read bytes.
                let data = Data(bytes: readBuffer, count: bytesRead)
                onData(data)
            } else if bytesRead < 0, let error = inputStream.streamError {
                // Error occurred during read.
                onError(error)
                handleClose()
                break
            } else {
                // bytesRead == 0 indicates end of stream.
                break
            }
        }
    }

    @MainActor
    private func sendData() {
        // Ensure there is data to send and space in the output buffer.
        guard !outgoingData.isEmpty, outputStream.hasSpaceAvailable else {
            return
        }

        let bytesWritten = outgoingData.withUnsafeBytes {
            outputStream.write($0.baseAddress!, maxLength: outgoingData.count)
        }

        if bytesWritten > 0 {
            // Efficiently remove the data that was sent.
            outgoingData.removeFirst(bytesWritten)
        } else if bytesWritten < 0, let error = outputStream.streamError {
            // Error occurred during write.
            onError(error)
            handleClose()
        }
    }

    /// The single, unified method for closing streams and notifying the delegate.
    @MainActor
    private func handleClose() {
        // Ensure cleanup and notification happens only once.
        guard !hasNotifiedClose else { return }
        hasNotifiedClose = true

        inputStream.close()
        outputStream.close()

        inputStream.remove(from: .main, forMode: .default)
        outputStream.remove(from: .main, forMode: .default)

        inputStream.delegate = nil
        outputStream.delegate = nil

        // Release the reference to the channel, allowing it to be deallocated.
        channel = nil
        outgoingData.removeAll()

        onClose()
    }
}

class ScanResultListener: ScanResultsStreamHandler {
    var eventSink: PigeonEventSink<PlatformScanResult>?

    override func onListen(
        withArguments arguments: Any?,
        sink: PigeonEventSink<PlatformScanResult>
    ) {
        eventSink = sink
    }

    func onEvent(event: PlatformScanResult) {
        if let eventSink = eventSink {
            eventSink.success(event)
        }
    }

    func onEventsDone() {
        eventSink?.endOfStream()
        eventSink = nil
    }
}

class L2CapSocketEventsListener: L2CapSocketEventsStreamHandler {
    var eventSink: PigeonEventSink<PlatformL2CapSocketEvent>?

    override func onListen(
        withArguments arguments: Any?,
        sink: PigeonEventSink<PlatformL2CapSocketEvent>
    ) {
        eventSink = sink
    }

    func onEvent(event: PlatformL2CapSocketEvent) {
        if let eventSink = eventSink {
            eventSink.success(event)
        }
    }

    func onEventsDone() {
        eventSink?.endOfStream()
        eventSink = nil
    }
}
