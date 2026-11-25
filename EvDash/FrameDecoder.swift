//
//  FrameDecoder.swift
//  EvDash
//
//  GEKOO 控制器帧解码器
//
//  协议逆向自 GEKOO 1.0.5（uni-app 包，包名 uni.UNIEF9C31D）：
//
//    Service 0000FFE0-0000-1000-8000-00805F9B34FB
//    写/通知 FFE1，bootloader 裸通道 FFE2
//    设备名过滤：前缀 "GEKOO-BLE" 或 "ZX-D30"
//
//  帧格式： AA | CMD | ... | CHECK
//
//    手机 → 控制器
//      AA 11 00 01                     读全部参数
//      AA 21 00 01                     进入写参数模式
//      AA 21 01 01                     恢复出厂设置
//      AA 17 00 01                     读蓝牙密码
//      AA 14 06 00 00 00 00 00 00      启动电机自学习
//      AA 13 FF 01 AA 13 00 01         实时数据轮询（100ms 一次）
//
//    控制器 → 手机
//      AA 11 00 <63×word LE> <cksum>   参数应答，131 字节
//      AA 13 00 <31×word LE> <cksum>   实时应答，67 字节
//      AA 21 00 xx                     写参数就绪
//      AA 12 00 AA                     写参数成功 / 其它值失败
//      AA 17 00 lo hi                  蓝牙密码
//
//  校验：参数/实时帧内所有 16 位小端字之和 == 0xFFFF
//

import Foundation

/// 命令字
enum FrameCmd: UInt8 {
    case param      = 0x11   // 参数应答
    case realtime   = 0x13   // 实时应答
    case writeAck   = 0x12   // 写参数结果
    case writeReady = 0x21   // 写参数就绪
    case bleKey     = 0x17   // 蓝牙密码
}

/// 解出的一帧
struct Frame {
    let cmd: UInt8
    let data: [UInt8]
}

/// 帧解码器 —— 含跨包重组与回显过滤
///
/// BLE 单包通常只有 20 字节，131 字节的参数帧必然跨包，必须自行重组。
final class FrameDecoder {

    static let lenParam: Int      = 131
    static let lenRealtime: Int   = 67
    static let lenAck: Int        = 4
    static let lenKey: Int        = 5

    private var rx: [UInt8] = []

    func clear() {
        rx.removeAll()
    }

    var pending: Int { rx.count }

    /// 喂入一段通知数据，返回本次能完整解出的所有帧
    func feed(_ chunk: [UInt8]) -> [Frame] {
        rx.append(contentsOf: chunk)
        var out: [Frame] = []
        var guardCount = 0
        while guardCount < 64 {
            guardCount += 1

            // 1. 找帧头 0xAA
            guard let idx = rx.firstIndex(of: 0xAA) else {
                rx.removeAll()
                break
            }
            if idx > 0 { rx.removeFirst(idx) }
            guard rx.count >= 2 else { break }

            let cmd = rx[1]

            // 2. 回显特例：控制器把轮询命令 AA 13 00 01 原样回显（4 字节）。
            //    原厂 App 见到 b[2]==0 && b[3]==1 就丢 4 字节，但真帧
            //    AA 13 00 <word0lo> <word0hi> 在 word0 低字节为 1 时同样符合
            //    该模式，会被误吞。这里必须攒够 67 字节，用校验区分。
            if cmd == FrameCmd.realtime.rawValue, rx.count >= 4,
               rx[2] == 0x00, rx[3] == 0x01 {
                if rx.count < FrameDecoder.lenRealtime { break }  // 还不够判断
                if FrameDecoder.wordSum(rx, from: 3, to: FrameDecoder.lenRealtime) != 0xFFFF {
                    rx.removeFirst(4)                             // 是回显，丢掉
                    continue
                }
                // 校验通过 → 真帧，走下面正常流程
            }

            // 3. 按命令字取帧长
            guard let need = FrameDecoder.frameLen(cmd) else {
                rx.removeFirst(2)                                 // 未知命令，跳过
                continue
            }
            guard rx.count >= need else { break }                 // 帧未收全

            // 4. 切帧
            let frame = Array(rx.prefix(need))
            rx.removeFirst(need)
            out.append(Frame(cmd: cmd, data: frame))
        }
        return out
    }

    static func frameLen(_ cmd: UInt8) -> Int? {
        switch cmd {
        case FrameCmd.param.rawValue:      return lenParam
        case FrameCmd.realtime.rawValue:   return lenRealtime
        case FrameCmd.writeAck.rawValue:   return lenAck
        case FrameCmd.writeReady.rawValue: return lenAck
        case FrameCmd.bleKey.rawValue:     return lenKey
        default: return nil
        }
    }

    /// 小端 16 位字累加
    static func wordSum(_ buf: [UInt8], from: Int, to: Int) -> Int {
        var s = 0
        var i = from
        while i + 1 < to {
            s = (s + (Int(buf[i]) | (Int(buf[i + 1]) << 8))) & 0xFFFF
            i += 2
        }
        return s
    }

    /// 取第 i 个小端 16 位字（数据区从第 3 字节开始）
    static func word(_ buf: [UInt8], _ i: Int) -> Int {
        let p = 3 + i * 2
        guard p + 1 < buf.count else { return 0 }
        return Int(buf[p]) | (Int(buf[p + 1]) << 8)
    }

    /// 有符号 16 位
    static func s16(_ v: Int) -> Double {
        return v > 32767 ? Double(v - 65536) : Double(v)
    }

    // MARK: - 组帧（手机 → 控制器）

    static let readParamsCmd:    [UInt8] = [0xAA, 0x11, 0x00, 0x01]
    static let writeEnterCmd:    [UInt8] = [0xAA, 0x21, 0x00, 0x01]
    static let factoryResetCmd:  [UInt8] = [0xAA, 0x21, 0x01, 0x01]
    static let readKeyCmd:       [UInt8] = [0xAA, 0x17, 0x00, 0x01]
    static let startLearnCmd:    [UInt8] = [0xAA, 0x14, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    static let pollCmd:          [UInt8] = [0xAA, 0x13, 0xFF, 0x01, 0xAA, 0x13, 0x00, 0x01]

    /// 把 63 个参数字组装成 131 字节写参数帧
    /// 帧结构：AA 12 00 + 126 字节 + 校验字
    static func buildWriteFrame(words: [Int]) -> [UInt8] {
        var payload = [UInt8]()
        payload.reserveCapacity(126)
        for i in 0..<63 {
            let w = i < words.count ? words[i] : 0
            payload.append(UInt8(w & 0xFF))
            payload.append(UInt8((w >> 8) & 0xFF))
        }
        var sum = 0
        var i = 0
        while i + 1 < payload.count {
            sum = (sum + (Int(payload[i]) | (Int(payload[i + 1]) << 8))) & 0xFFFF
            i += 2
        }
        let cksum = (0xFFFF - sum) & 0xFFFF

        var frame = [UInt8](repeating: 0, count: 131)
        frame[0] = 0xAA
        frame[1] = 0x12
        frame[2] = 0x00
        for (k, b) in payload.enumerated() { frame[3 + k] = b }
        frame[129] = UInt8(cksum & 0xFF)
        frame[130] = UInt8((cksum >> 8) & 0xFF)
        return frame
    }
}
