//
//  BleManager.swift
//  EvDash
//
//  GEKOO 控制器 BLE 连接管理（iOS / CoreBluetooth）
//
//  与原厂 App 保持一致的行为：
//    - 只认名字前缀 "GEKOO-BLE" 或 "ZX-D30"
//    - 连上后枚举 FFE0 服务，找到 notify 特征与 FFE1 写特征
//    - 首次写入前先往 FFE2 发 0102 握手
//    - 实时数据 100ms 轮询
//    - 连上后自动读一次参数
//

import Foundation
import CoreBluetooth
import Combine

/// 扫描到的设备
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID            // peripheral.identifier
    let name: String
    var rssi: Int
    var peripheral: CBPeripheral

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

/// 连接状态
enum BleState: Equatable {
    case idle
    case scanning
    case connecting(String)
    case connected
    case failed(String)

    var text: String {
        switch self {
        case .idle:            return "未连接"
        case .scanning:        return "扫描中…"
        case .connecting(let n): return "连接 \(n)"
        case .connected:       return "实时数据采集中"
        case .failed(let m):   return m
        }
    }
}

@MainActor
final class BleManager: NSObject, ObservableObject {

    // MARK: - 对外状态

    @Published private(set) var state: BleState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var realtime: RealtimeData?
    @Published private(set) var paramWords: [Int]?
    @Published private(set) var bleKey: Int?
    @Published private(set) var lastMessage: String = ""

    // MARK: - UUID

    private static let serviceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    private static let chFFE1      = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    private static let chFFE2      = CBUUID(string: "0000FFE2-0000-1000-8000-00805F9B34FB")

    private static let namePrefixes = ["GEKOO-BLE", "ZX-D30"]

    // MARK: - CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var notifyCh: CBCharacteristic?
    private var writeCh: CBCharacteristic?
    private var bootCh: CBCharacteristic?

    private let decoder = FrameDecoder()

    /// 待写入的 126 字节载荷（收到 AA 21 00 xx 后才真正发）
    private var pendingPayload: [UInt8]?
    private var pendingAt: Date?

    /// 待发送队列（CoreBluetooth 同一时刻只能有一个未完成的写）
    private var txQueue: [[UInt8]] = []
    private var txBusy = false
    private var writeWatchdog: Task<Void, Never>?

    // 轮询
    private var pollTask: Task<Void, Never>?
    private var autoReadParams = true

    // 自动连接
    private var scanStartedAt: Date?
    private var autoConnectFired = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 权限 / 状态

    var isPoweredOn: Bool { central.state == .poweredOn }

    var bluetoothStateText: String {
        switch central.state {
        case .poweredOn:   return "蓝牙已就绪"
        case .poweredOff:  return "蓝牙未打开，请在设置中开启"
        case .unauthorized: return "未授权蓝牙，请在设置 → EvDash 中允许"
        case .unsupported: return "此设备不支持蓝牙"
        case .resetting:   return "蓝牙正在重置"
        default:           return "蓝牙状态未知"
        }
    }

    // MARK: - 扫描

    func startScan() {
        guard central.state == .poweredOn else {
            state = .failed(bluetoothStateText)
            return
        }
        devices.removeAll()
        autoConnectFired = false
        scanStartedAt = Date()
        state = .scanning
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // 12 秒后自动停
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            if case .scanning = self.state { self.stopScan() }
        }
        // 3 秒后若只有一台，自动连（与原厂一致）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.autoConnectFired else { return }
            self.autoConnectFired = true
            if self.devices.count == 1, let only = self.devices.first {
                self.lastMessage = "自动连接唯一设备"
                self.connect(only)
            } else if self.devices.count > 1 {
                self.lastMessage = "发现 \(self.devices.count) 台设备，请手动选择"
            }
        }
    }

    func stopScan() {
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    // MARK: - 连接

    func connect(_ dev: DiscoveredDevice) {
        central.stopScan()
        if let old = peripheral {
            central.cancelPeripheralConnection(old)
        }
        decoder.clear()
        txQueue.removeAll()
        txBusy = false
        peripheral = dev.peripheral
        dev.peripheral.delegate = self
        state = .connecting(dev.name)
        central.connect(dev.peripheral, options: nil)
    }

    func disconnect() {
        stopPolling()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        cleanup()
        state = .idle
    }
    private func cleanup() {
        stopPolling()
        decoder.clear()
        txQueue.removeAll()
        txBusy = false
        writeWatchdog?.cancel()
        writeWatchdog = nil
        pendingPayload = nil
        pendingAt = nil
        notifyCh = nil
        writeCh = nil
        bootCh = nil
        peripheral = nil
    }

    // MARK: - 参数读写

    func readParams() {
        guard state == .connected else {
            lastMessage = "未连接"
            return
        }
        // 读参数期间暂停轮询，避免 0x11 / 0x13 帧交错
        let wasPolling = pollTask != nil
        stopPolling()
        enqueue(FrameDecoder.readParamsCmd)
        if wasPolling {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.state == .connected else { return }
                self.startPolling()
            }
        }
    }

    func writeParams(words: [Int]) {
        guard state == .connected else {
            lastMessage = "未连接"
            return
        }
        var payload: [UInt8] = []
        payload.reserveCapacity(126)
        for i in 0..<63 {
            let w = i < words.count ? words[i] : 0
            payload.append(UInt8(w & 0xFF))
            payload.append(UInt8((w >> 8) & 0xFF))
        }
        pendingPayload = payload
        pendingAt = Date()
        enqueue(FrameDecoder.writeEnterCmd)
    }

    func factoryReset() {
        guard state == .connected else { return }
        enqueue(FrameDecoder.factoryResetCmd)
    }

    func readBleKey() {
        guard state == .connected else { return }
        enqueue(FrameDecoder.readKeyCmd)
    }

    func startLearn() {
        guard state == .connected else { return }
        enqueue(FrameDecoder.startLearnCmd)
    }

    // MARK: - 轮询

    /// 用 Task + Task.sleep 而不是 Timer：
    /// Timer 依赖 runloop，在 @MainActor 的 async 上下文里容易被悬挂，
    /// 而 Task.sleep 一定会在指定时间后恢复。
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state == .connected else { break }
                self.enqueue(FrameDecoder.pollCmd)
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - 发送

    /// 入队一帧。
    /// 轮询帧在忙时直接丢弃（避免积压），命令帧一定入队。
    private func enqueue(_ bytes: [UInt8]) {
        if bytes == FrameDecoder.pollCmd && txBusy { return }
        txQueue.append(bytes)
        pump()
    }

    private func pump() {
        guard !txBusy, let ch = writeCh, let p = peripheral else { return }
        guard !txQueue.isEmpty else { return }
        let bytes = txQueue.removeFirst()
        txBusy = true
        p.writeValue(Data(bytes), for: ch, type: .withResponse)

        // 看门狗：CoreBluetooth 在极端情况下可能不回 didWriteValueFor，
        // 若不设兜底，txBusy 会永久为 true，之后所有写操作全部卡死。
        writeWatchdog?.cancel()
        writeWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            guard let self, !Task.isCancelled else { return }
            if self.txBusy {
                self.txBusy = false
                self.pump()
            }
        }
    }

    private func pumpBoot() {
        guard let ch = bootCh, let p = peripheral else { return }
        p.writeValue(Data([0x01, 0x02]), for: ch, type: .withResponse)
    }

    // MARK: - 收帧

    private func onNotify(_ data: [UInt8]) {
        let frames = decoder.feed(data)
        for f in frames { handle(f) }
    }

    private func handle(_ f: Frame) {
        switch f.cmd {
        case FrameCmd.realtime.rawValue:
            parseRealtime(f.data)
        case FrameCmd.param.rawValue:
            parseParams(f.data)
        case FrameCmd.writeAck.rawValue:
            onWriteAck(f.data)
        case FrameCmd.writeReady.rawValue:
            onWriteReady(f.data)
        case FrameCmd.bleKey.rawValue:
            onKey(f.data)
        default:
            break
        }
    }

    private func parseRealtime(_ f: [UInt8]) {
        guard FrameDecoder.wordSum(f, from: 3, to: f.count) == 0xFFFF else {
            return
        }
        let throttleV = Double(FrameDecoder.word(f, 2)) / 2450.0
        let rpm       = Double(FrameDecoder.word(f, 6)) / 5.46
        let busV      = Double(FrameDecoder.word(f, 8)) / 273.07
        let busA      = FrameDecoder.s16(FrameDecoder.word(f, 9))
        let tempC     = FrameDecoder.s16(FrameDecoder.word(f, 18)) / 100.0
        let fault     = FrameDecoder.word(f, 22)
        let model     = FrameDecoder.word(f, 29)
        let power     = busV > 0 ? busV * busA / 1000.0 : 0

        realtime = RealtimeData(
            rpm: rpm,
            busVoltage: busV,
            busCurrent: busA,
            power: power,
            ctrlTemp: tempC,
            throttleVolt: throttleV,
            faultCode: fault,
            modelRaw: model
        )
    }

    private func parseParams(_ f: [UInt8]) {
        guard FrameDecoder.wordSum(f, from: 3, to: f.count) == 0xFFFF else {
            lastMessage = "参数校验失败，请重读"
            return
        }
        var words: [Int] = []
        words.reserveCapacity(63)
        for i in 0..<63 { words.append(FrameDecoder.word(f, i)) }
        paramWords = words
        lastMessage = "参数读取成功"
    }

    private func onWriteReady(_ f: [UInt8]) {
        guard f.count >= 3, f[2] == 0x00 else { return }
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        if let t = pendingAt, Date().timeIntervalSince(t) > 5 { return }

        let frame = FrameDecoder.buildWriteFrame(
            words: stride(from: 0, to: 126, by: 2).map { i in
                Int(payload[i]) | (Int(payload[i + 1]) << 8)
            }
        )
        // 按 20 字节分包（iOS 会自动协商 MTU，但保守分包最稳）
        var off = 0
        while off < frame.count {
            let end = min(frame.count, off + 20)
            enqueue(Array(frame[off..<end]))
            off = end
        }
        lastMessage = "参数写入中"
    }

    private func onWriteAck(_ f: [UInt8]) {
        guard f.count >= 4 else { return }
        let ok = f[3] == 0xAA
        lastMessage = ok ? "参数写入成功" : "参数写入失败"
        if ok {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.readParams()
            }
        }
    }

    private func onKey(_ f: [UInt8]) {
        guard f.count >= 5 else { return }
        let key = (Int(f[4]) << 8) | Int(f[3])
        bleKey = key
        lastMessage = "蓝牙密码 \(key)"
    }
}

// MARK: - CBCentralManagerDelegate

extension BleManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state != .poweredOn {
                self.state = .failed(self.bluetoothStateText)
            } else if case .failed = self.state {
                self.state = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        guard !name.isEmpty else { return }
        guard BleManager.namePrefixes.contains(where: { name.hasPrefix($0) }) else { return }

        let rssi = RSSI.intValue
        Task { @MainActor in
            if let idx = self.devices.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.devices[idx].rssi = rssi
            } else {
                self.devices.append(DiscoveredDevice(
                    id: peripheral.identifier,
                    name: name,
                    rssi: rssi,
                    peripheral: peripheral
                ))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.state = .connected
            self.lastMessage = "已连接，枚举服务"
            // 与原厂一致：稍等再枚举，给控制器一点时间
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                peripheral.discoverServices([BleManager.serviceUUID])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.state = .failed("连接失败")
            self.cleanup()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.cleanup()
            self.state = .idle
            self.lastMessage = "已断开"
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BleManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let svc = peripheral.services?.first(where: { $0.uuid == BleManager.serviceUUID }) else {
                self.state = .failed("未找到 FFE0 服务")
                return
            }
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            var notify: CBCharacteristic?
            var write: CBCharacteristic?
            for c in service.characteristics ?? [] {
                if notify == nil, c.properties.contains(.notify) { notify = c }
                if c.uuid == BleManager.chFFE1 { write = c }
                if c.uuid == BleManager.chFFE2 { self.bootCh = c }
            }
            if write == nil { write = notify }
            guard let n = notify else {
                self.state = .failed("未找到通知通道")
                return
            }
            self.notifyCh = n
            self.writeCh = write
            peripheral.setNotifyValue(true, for: n)

            // FFE2 握手 0102（与原厂一致）
            self.pumpBoot()

            self.state = .connected
            self.lastMessage = "实时数据采集中"
            self.startPolling()

            if self.autoReadParams {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    self.readParams()
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let d = characteristic.value else { return }
        let bytes = [UInt8](d)
        Task { @MainActor in
            self.onNotify(bytes)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            self.writeWatchdog?.cancel()
            self.writeWatchdog = nil
            self.txBusy = false
            if let error {
                self.lastMessage = "写入失败：\(error.localizedDescription)"
            }
            self.pump()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        // 通知开关结果，出错时给出提示
        if let error {
            Task { @MainActor in
                self.lastMessage = "开启通知失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 实时数据模型

struct RealtimeData {
    let rpm: Double
    let busVoltage: Double
    let busCurrent: Double
    let power: Double
    let ctrlTemp: Double
    let throttleVolt: Double
    let faultCode: Int
    let modelRaw: Int

    /// 故障位表 —— 逆向自原厂 realtimedata 索引 22
    static let faultNames: [String] = [
        "过流保护", "母线过压", "母线欠压", "过温", "保留",
        "12V欠压", "12V过压", "传感器故障1", "传感器故障2", "霍尔故障",
        "电流过大", "堵转保护", "5V欠压", "5V过压", "保留", "转把故障"
    ]

    var faultText: String {
        if faultCode == 0 { return "正常" }
        var hit: [String] = []
        for i in 0..<16 where (faultCode & (1 << i)) != 0 {
            hit.append(i < RealtimeData.faultNames.count ? RealtimeData.faultNames[i] : "位\(i)")
        }
        return hit.isEmpty ? "正常" : hit.joined(separator: " / ")
    }

    /// 硬件型号 —— 千位=系列，十位=电流档，个位=子型
    static let seriesNames: [Int: String] = [
        0: "GK", 1: "GK", 2: "GK", 3: "AE", 4: "XM",
        5: "UB", 6: "PD", 7: "CP", 8: "ND"
    ]

    static let subModels: [Int: [Int: String]] = [
        1: [3: "7235"],
        2: [1: "72240", 2: "72220", 3: "72260"],
        3: [3: "72350"],
        4: [3: "72450"],
        5: [3: "72550"],
        7: [2: "72550P"],
        8: [3: "72850"],
        9: [1: "721200", 2: "721600", 3: "722000"]
    ]

    var modelText: String {
        let series = modelRaw / 1000
        let sub = (modelRaw / 10) % 10
        let subIdx = modelRaw % 10
        let s = RealtimeData.seriesNames[series] ?? "?"
        if let t = RealtimeData.subModels[sub]?[subIdx] { return s + t }
        return String(modelRaw)
    }
}
