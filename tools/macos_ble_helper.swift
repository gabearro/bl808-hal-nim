import CoreBluetooth
import Foundation
import AppKit

struct ParsedArgs {
    let command: String
    private let values: [String: String]
    private let flags: Set<String>

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw UsageError("missing command: advertise or connect")
        }
        self.command = command
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            guard arg.hasPrefix("--") else {
                throw UsageError("unexpected argument: \(arg)")
            }
            let key = String(arg.dropFirst(2))
            if index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") {
                values[key] = arguments[index + 1]
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
        self.values = values
        self.flags = flags
    }

    func string(_ key: String, default defaultValue: String) -> String {
        values[key] ?? defaultValue
    }

    func optionalString(_ key: String) -> String? {
        values[key]
    }

    func double(_ key: String, default defaultValue: Double) -> Double {
        guard let raw = values[key], let value = Double(raw) else {
            return defaultValue
        }
        return value
    }

    func int(_ key: String, default defaultValue: Int) -> Int {
        guard let raw = values[key], let value = Int(raw) else {
            return defaultValue
        }
        return value
    }

    func flag(_ key: String) -> Bool {
        flags.contains(key)
    }
}

struct UsageError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

var mirroredLogHandle: FileHandle?
var privacyPromptWindow: NSWindow?

func log(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else {
        return
    }
    FileHandle.standardOutput.write(data)
    mirroredLogHandle?.write(data)
}

func configureGlobalOptions(_ arguments: [String]) throws -> [String] {
    var remaining: [String] = []
    var index = 0
    while index < arguments.count {
        if arguments[index] == "--log-file" {
            guard index + 1 < arguments.count else {
                throw UsageError("missing value for --log-file")
            }
            let path = arguments[index + 1]
            FileManager.default.createFile(atPath: path, contents: nil)
            mirroredLogHandle = FileHandle(forWritingAtPath: path)
            mirroredLogHandle?.seekToEndOfFile()
            index += 2
        } else {
            remaining.append(arguments[index])
            index += 1
        }
    }
    return remaining
}

func showPrivacyPromptWindow() {
    if privacyPromptWindow == nil {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacOSBLEHelper"
        window.isReleasedWhenClosed = false

        let label = NSTextField(
            wrappingLabelWithString: """
            BL808 BLE validation needs Bluetooth access.

            Allow Bluetooth for MacOSBLEHelper when macOS asks. If the prompt is not visible, open Privacy & Security > Bluetooth and enable MacOSBLEHelper.
            """
        )
        label.alignment = .center
        label.frame = NSRect(x: 28, y: 42, width: 404, height: 96)
        window.contentView?.addSubview(label)

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        privacyPromptWindow = window
    }
}

func uuidOrNil(_ value: String) -> CBUUID? {
    value.isEmpty ? nil : CBUUID(string: value)
}

func stateName(_ state: CBManagerState) -> String {
    switch state {
    case .unknown:
        return "unknown"
    case .resetting:
        return "resetting"
    case .unsupported:
        return "unsupported"
    case .unauthorized:
        return "unauthorized"
    case .poweredOff:
        return "poweredOff"
    case .poweredOn:
        return "poweredOn"
    @unknown default:
        return "unknown(\(state.rawValue))"
    }
}

func authorizationName(_ authorization: CBManagerAuthorization) -> String {
    switch authorization {
    case .notDetermined:
        return "notDetermined"
    case .restricted:
        return "restricted"
    case .denied:
        return "denied"
    case .allowedAlways:
        return "allowedAlways"
    @unknown default:
        return "unknown(\(authorization.rawValue))"
    }
}

func bluetoothPermissionHint() -> String {
    "Open System Settings > Privacy & Security > Bluetooth and enable MacOSBLEHelper."
}

func openBluetoothPrivacySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else {
        return
    }
    NSWorkspace.shared.open(url)
}

func parsePayloadHex(_ value: String?) -> [UInt8]? {
    guard let value, !value.isEmpty else {
        return nil
    }
    let compact = value.filter { !$0.isWhitespace && $0 != ":" }
    guard compact.count % 2 == 0 else {
        return nil
    }
    var bytes: [UInt8] = []
    var index = compact.startIndex
    while index < compact.endIndex {
        let next = compact.index(index, offsetBy: 2)
        guard let byte = UInt8(compact[index..<next], radix: 16) else {
            return nil
        }
        bytes.append(byte)
        index = next
    }
    return bytes
}

func dataContains(_ data: Data, _ needle: [UInt8]) -> Bool {
    if needle.isEmpty {
        return true
    }
    let bytes = [UInt8](data)
    if needle.count > bytes.count {
        return false
    }
    for offset in 0...(bytes.count - needle.count) {
        if Array(bytes[offset..<(offset + needle.count)]) == needle {
            return true
        }
    }
    return false
}

func hexBytes(_ data: Data, limit: Int = 16) -> String {
    let bytes = [UInt8](data.prefix(limit))
    let body = bytes.map { String(format: "%02x", $0) }.joined()
    return data.count > limit ? "\(body)..." : body
}

protocol RunnableTask: AnyObject {
    var exitCode: Int? { get }
    func start()
    func tick(now: Date)
}

final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private let command: String
    private let task: RunnableTask
    private var timer: Timer?

    init(command: String, task: RunnableTask) {
        self.command = command
        self.task = task
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        showPrivacyPromptWindow()
        app.unhide(nil)
        app.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        log("[INFO] BLE helper runloop ready command=\(command) appActive=\(app.isActive) authorization=\(authorizationName(CBManager.authorization))")
        task.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.task.tick(now: Date())
            if self.task.exitCode != nil {
                timer.invalidate()
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

final class PermissionTask: NSObject, RunnableTask, CBCentralManagerDelegate {
    private var deadline = Date.distantFuture
    private let timeoutSeconds: Double
    private let debug: Bool
    private var manager: CBCentralManager?
    private var stateSeen = false
    private var centralState = "not-created"

    private(set) var exitCode: Int?

    init(args: ParsedArgs) {
        let timeout = args.double("timeout", default: 20.0)
        timeoutSeconds = timeout
        debug = args.flag("debug")
        super.init()
        log("[INFO] BLE permission config timeout=\(timeoutSeconds) authorization=\(authorizationName(CBManager.authorization))")
    }

    func start() {
        deadline = Date().addingTimeInterval(timeoutSeconds)
        if CBManager.authorization != .allowedAlways {
            openBluetoothPrivacySettings()
        }
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateSeen = true
        centralState = stateName(central.state)
        log("[INFO] BLE permission state=\(centralState) authorization=\(authorizationName(CBManager.authorization))")
        switch central.state {
        case .poweredOn:
            log("[PASS] BLE permission ready")
            exitCode = 0
        case .unauthorized:
            fail("[FAIL] BLE permission unauthorized authorization=\(authorizationName(CBManager.authorization)). \(bluetoothPermissionHint())")
        case .unsupported:
            fail("[FAIL] BLE permission unsupported")
        case .poweredOff:
            fail("[FAIL] BLE permission poweredOff")
        default:
            if debug {
                log("[INFO] BLE permission waiting state=\(centralState)")
            }
        }
    }

    func tick(now: Date) {
        guard exitCode == nil else {
            return
        }
        if now >= deadline {
            let stateText = stateSeen ? centralState : "unavailable"
            fail("[FAIL] BLE permission state \(stateText) after \(timeoutSeconds)s authorization=\(authorizationName(CBManager.authorization)). \(bluetoothPermissionHint())")
        }
    }

    private func fail(_ message: String) {
        guard exitCode == nil else {
            return
        }
        log(message)
        exitCode = 1
    }
}

final class AdvertiseTask: NSObject, RunnableTask, CBPeripheralManagerDelegate {
    private let name: String
    private let advertisedServiceUUID: CBUUID?
    private let gattServiceUUID: CBUUID?
    private let characteristicUUID: CBUUID?
    private let noGattService: Bool
    private let duration: Double
    private var startupDeadline = Date.distantFuture
    private let startupTimeout: Double
    private let restartInterval: Double
    private let restartCountLimit: Int
    private let debug: Bool

    private var manager: CBPeripheralManager?
    private var lastState = "not-created"
    private var poweredOn = false
    private var serviceAddRequested = false
    private var serviceAdded = false
    private var advertisingRequested = false
    private var started = false
    private var stopDeadline: Date?
    private var nextRestart: Date?
    private var restartCount = 0

    private(set) var exitCode: Int?

    init(args: ParsedArgs) {
        name = args.string("name", default: "bl808-host")
        advertisedServiceUUID = uuidOrNil(args.string("service-uuid", default: "12345678-1234-5678-1234-56789abcdef0"))
        gattServiceUUID = uuidOrNil(args.string("gatt-service-uuid", default: "12345678-1234-5678-1234-56789abcdef0"))
        characteristicUUID = uuidOrNil(args.string("characteristic-uuid", default: "12345678-1234-5678-1234-56789abcdef1"))
        noGattService = args.flag("no-gatt-service")
        duration = args.double("duration", default: 20.0)
        startupTimeout = args.double("startup-timeout", default: 8.0)
        restartInterval = args.double("restart-interval", default: 0.0)
        restartCountLimit = args.int("restart-count", default: -1)
        debug = args.flag("debug")
        serviceAdded = noGattService || gattServiceUUID == nil
        super.init()
        if debug {
            log("[INFO] BLE advertising config name=\(name) advertisedService=\(advertisedServiceUUID?.uuidString ?? "<none>") gattService=\(gattServiceUUID?.uuidString ?? "<none>") duration=\(duration) startupTimeout=\(startupTimeout) authorization=\(authorizationName(CBManager.authorization))")
        }
    }

    func start() {
        startupDeadline = Date().addingTimeInterval(startupTimeout)
        manager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
        )
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        lastState = stateName(peripheral.state)
        if debug {
            log("[INFO] BLE peripheral state=\(lastState)")
        }
        switch peripheral.state {
        case .poweredOn:
            poweredOn = true
            maybeRegisterService(peripheral)
            maybeStartAdvertising(peripheral)
        case .unauthorized, .unsupported:
            fail("[FAIL] BLE advertising \(stateName(peripheral.state))")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            fail("[FAIL] BLE advertising service add: \(error.localizedDescription)")
            return
        }
        serviceAdded = true
        maybeStartAdvertising(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            advertisingRequested = false
            fail("[FAIL] BLE advertising start: \(error.localizedDescription)")
            return
        }
        started = true
        if stopDeadline == nil {
            stopDeadline = Date().addingTimeInterval(duration)
        }
        log("[PASS] BLE advertising started")
    }

    func tick(now: Date) {
        guard exitCode == nil else {
            return
        }
        if !started && stopDeadline == nil && now >= startupDeadline {
            fail("[FAIL] BLE advertising did not start state=\(lastState) poweredOn=\(poweredOn) serviceAddRequested=\(serviceAddRequested) serviceAdded=\(serviceAdded) advertisingRequested=\(advertisingRequested) authorization=\(authorizationName(CBManager.authorization)). \(bluetoothPermissionHint())")
            return
        }
        if started, let nextRestart, now >= nextRestart {
            manager?.stopAdvertising()
            started = false
            advertisingRequested = false
            self.nextRestart = nil
            restartCount += 1
            if restartCountLimit < 0 || restartCount < restartCountLimit {
                self.nextRestart = now.addingTimeInterval(restartInterval)
            }
            if let manager {
                maybeStartAdvertising(manager)
            }
        }
        if let stopDeadline, now >= stopDeadline {
            if let manager {
                DispatchQueue.main.async {
                    manager.stopAdvertising()
                }
            }
            log("[PASS] BLE advertising stopped")
            exitCode = 0
        }
    }

    private func maybeRegisterService(_ peripheral: CBPeripheralManager) {
        guard poweredOn, !serviceAdded, !serviceAddRequested, let gattServiceUUID else {
            return
        }
        let service = CBMutableService(type: gattServiceUUID, primary: true)
        if let characteristicUUID {
            let value = Data("bl808-hal".utf8)
            let characteristic = CBMutableCharacteristic(
                type: characteristicUUID,
                properties: [.read],
                value: value,
                permissions: [.readable]
            )
            service.characteristics = [characteristic]
        }
        serviceAddRequested = true
        if debug {
            log("[INFO] BLE advertising service add requested uuid=\(gattServiceUUID.uuidString)")
        }
        peripheral.add(service)
    }

    private func maybeStartAdvertising(_ peripheral: CBPeripheralManager) {
        guard poweredOn, serviceAdded, !started, !advertisingRequested else {
            return
        }
        var advertisement: [String: Any] = [:]
        if !name.isEmpty {
            advertisement[CBAdvertisementDataLocalNameKey] = name
        }
        if let advertisedServiceUUID {
            advertisement[CBAdvertisementDataServiceUUIDsKey] = [advertisedServiceUUID]
        }
        advertisingRequested = true
        if debug {
            log("[INFO] BLE advertising start requested localName=\(name.isEmpty ? "<none>" : name) serviceUUID=\(advertisedServiceUUID?.uuidString ?? "<none>")")
        }
        peripheral.startAdvertising(advertisement)
        if restartInterval > 0.0 {
            nextRestart = Date().addingTimeInterval(restartInterval)
        }
    }

    private func fail(_ message: String) {
        guard exitCode == nil else {
            return
        }
        log(message)
        exitCode = 1
    }
}

struct SeenPeripheral {
    let identifier: String
    let name: String
    let localName: String
    let rssi: Int
    let manufacturerData: Data?
    let serviceData: [CBUUID: Data]
    let serviceUUIDs: [CBUUID]
    let txPower: Int?
    let isConnectable: Bool?
}

final class ConnectTask: NSObject, RunnableTask, CBCentralManagerDelegate {
    private let name: String
    private let address: String?
    private var startupDeadline = Date.distantFuture
    private let startupTimeout: Double
    private var timeoutDeadline = Date.distantFuture
    private let timeoutSeconds: Double
    private let holdSeconds: Double
    private let payloadNeedle: [UInt8]?
    private let dumpLimit: Int
    private let debug: Bool

    private var manager: CBCentralManager?
    private var centralState = "not-created"
    private var stateSeen = false
    private var poweredOn = false
    private var scanRequested = false
    private var seen: [String: SeenPeripheral] = [:]
    private var target: CBPeripheral?
    private var targetSeen: SeenPeripheral?
    private var connected = false
    private var disconnectRequested = false
    private var disconnectAt: Date?

    private(set) var exitCode: Int?

    init(args: ParsedArgs) {
        let timeout = args.double("timeout", default: 20.0)
        let startup = args.double("startup-timeout", default: min(8.0, timeout))
        name = args.string("name", default: "bl808-hal")
        address = args.optionalString("address")
        startupTimeout = startup
        timeoutSeconds = timeout
        holdSeconds = args.double("hold-seconds", default: 0.2)
        payloadNeedle = parsePayloadHex(args.optionalString("payload-hex"))
        dumpLimit = args.int("dump-limit", default: 40)
        debug = args.flag("debug")
        super.init()
        if debug {
            log("[INFO] BLE connect config name=\(name) address=\(address ?? "<none>") timeout=\(timeoutSeconds) startupTimeout=\(startupTimeout) holdSeconds=\(holdSeconds) authorization=\(authorizationName(CBManager.authorization))")
        }
    }

    func start() {
        let now = Date()
        startupDeadline = now.addingTimeInterval(startupTimeout)
        timeoutDeadline = now.addingTimeInterval(timeoutSeconds)
        manager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        stateSeen = true
        centralState = stateName(central.state)
        if debug {
            log("[INFO] BLE central state=\(centralState) authorization=\(authorizationName(CBManager.authorization))")
        }
        switch central.state {
        case .poweredOn:
            poweredOn = true
            scanRequested = true
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .unauthorized, .unsupported:
            fail("[FAIL] BLE host validation \(centralState) authorization=\(authorizationName(CBManager.authorization))")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard target == nil else {
            return
        }
        let item = seenPeripheral(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
        seen[item.identifier] = item
        guard matches(item) else {
            return
        }
        target = peripheral
        targetSeen = item
        central.stopScan()
        log("[PASS] BLE device discovered: \(item.identifier)")
        if debug {
            log("[INFO] BLE connect target \(describe(item))")
            log("[INFO] BLE connect requested")
        }
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        log("[PASS] BLE connected")
        if debug {
            log("[INFO] BLE connected peripheral=\(peripheral.identifier.uuidString)")
        }
        disconnectAt = Date().addingTimeInterval(max(0.0, holdSeconds))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if debug, let targetSeen {
            log("[INFO] BLE failed target \(describe(targetSeen))")
        }
        fail("[FAIL] BLE connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if disconnectRequested || connected {
            log("[PASS] BLE disconnected")
            exitCode = 0
        } else {
            fail("[FAIL] BLE disconnected before connect: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    func tick(now: Date) {
        guard exitCode == nil else {
            return
        }
        if !stateSeen && now >= startupDeadline {
            fail("[FAIL] BLE central state unavailable after \(startupTimeout)s authorization=\(authorizationName(CBManager.authorization)). \(bluetoothPermissionHint())")
            return
        }
        if stateSeen && !poweredOn && now >= startupDeadline {
            fail("[FAIL] BLE central not ready state=\(centralState) authorization=\(authorizationName(CBManager.authorization))")
            return
        }
        if let disconnectAt, now >= disconnectAt, let target, let manager {
            self.disconnectAt = nil
            disconnectRequested = true
            DispatchQueue.main.async {
                manager.cancelPeripheralConnection(target)
            }
            return
        }
        if now >= timeoutDeadline {
            if target == nil {
                log("[FAIL] BLE device not found: \(address ?? name) state=\(centralState) scanRequested=\(scanRequested) authorization=\(authorizationName(CBManager.authorization))")
                printSeenPeripherals()
            } else {
                if debug, let targetSeen {
                    log("[INFO] BLE connect timed out target \(describe(targetSeen))")
                }
                log("[FAIL] BLE connect")
            }
            exitCode = 1
        }
    }

    private func seenPeripheral(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: Int
    ) -> SeenPeripheral {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? Int
        let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
        return SeenPeripheral(
            identifier: peripheral.identifier.uuidString,
            name: peripheral.name ?? "",
            localName: localName,
            rssi: rssi,
            manufacturerData: manufacturerData,
            serviceData: serviceData,
            serviceUUIDs: serviceUUIDs,
            txPower: txPower,
            isConnectable: isConnectable
        )
    }

    private func matches(_ item: SeenPeripheral) -> Bool {
        if let address, item.identifier.lowercased() == address.lowercased() {
            return true
        }
        if address == nil {
            if item.name == name || item.localName == name || item.localName.contains(name) {
                return true
            }
            if let payloadNeedle {
                if let manufacturerData = item.manufacturerData, dataContains(manufacturerData, payloadNeedle) {
                    return true
                }
                for data in item.serviceData.values where dataContains(data, payloadNeedle) {
                    return true
                }
            }
        }
        return false
    }

    private func printSeenPeripherals() {
        if seen.isEmpty {
            log("[BLE] no advertisements observed")
            return
        }
        log("[BLE] observed advertisements:")
        let sorted = seen.values.sorted { lhs, rhs in
            if lhs.rssi == rhs.rssi {
                return lhs.identifier < rhs.identifier
            }
            return lhs.rssi > rhs.rssi
        }
        let limited = dumpLimit > 0 ? Array(sorted.prefix(dumpLimit)) : sorted
        for item in limited {
            log("[BLE]   \(describe(item))")
        }
    }

    private func describe(_ item: SeenPeripheral) -> String {
        let label = item.localName.isEmpty ? (item.name.isEmpty ? "<unnamed>" : item.name) : item.localName
        var details: [String] = []
        if let manufacturerData = item.manufacturerData {
            details.append("mfg=\(hexBytes(manufacturerData))")
        }
        for (uuid, data) in item.serviceData {
            details.append("svcdata=\(uuid.uuidString):\(hexBytes(data))")
        }
        if !item.serviceUUIDs.isEmpty {
            details.append("svcs=" + item.serviceUUIDs.prefix(4).map(\.uuidString).joined(separator: ","))
        }
        if let txPower = item.txPower {
            details.append("tx=\(txPower)")
        }
        if let isConnectable = item.isConnectable {
            details.append("connectable=\(isConnectable ? "true" : "false")")
        }
        let suffix = details.isEmpty ? "" : " " + details.joined(separator: " ")
        return "\(item.identifier) name=\(label) rssi=\(item.rssi)\(suffix)"
    }

    private func fail(_ message: String) {
        guard exitCode == nil else {
            return
        }
        log(message)
        exitCode = 1
    }
}

func printUsage() {
    log("""
    usage:
      macos_ble_helper advertise [--name NAME] [--service-uuid UUID] [--duration SECONDS]
      macos_ble_helper connect [--name NAME] [--address UUID] [--timeout SECONDS] [--hold-seconds SECONDS]
      macos_ble_helper permission [--timeout SECONDS]
    """)
}

do {
    let rawArgs = try configureGlobalOptions(Array(CommandLine.arguments.dropFirst()))
    let args = try ParsedArgs(rawArgs)
    let task: RunnableTask
    switch args.command {
    case "permission":
        task = PermissionTask(args: args)
    case "advertise":
        task = AdvertiseTask(args: args)
    case "connect":
        task = ConnectTask(args: args)
    default:
        throw UsageError("unknown command: \(args.command)")
    }

    let app = NSApplication.shared
    let appDelegate = HelperAppDelegate(command: args.command, task: task)
    app.setActivationPolicy(.regular)
    app.delegate = appDelegate
    log("[INFO] BLE helper launch command=\(args.command) appActive=\(app.isActive) authorization=\(authorizationName(CBManager.authorization))")
    app.run()
    Foundation.exit(Int32(task.exitCode ?? 1))
} catch {
    log("[FAIL] BLE helper argument error: \(error)")
    printUsage()
    Foundation.exit(2)
}
