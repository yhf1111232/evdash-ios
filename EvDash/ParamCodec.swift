//
//  ParamCodec.swift
//  EvDash
//
//  参数字 ↔ 物理值 的双向换算
//
//  原厂 App 的解码逻辑（utils/parameter_list.js 的 parameter_process_data）：
//    uint  : round(raw / scale)
//    int   : 先按位宽取补码，再 round(raw / scale)
//    float : (raw / scale) 保留 2 位
//    bool  : raw & 1
//    list  : 连续位直接取值，否则按 bit0/bit1/bit2 拼 3 位，再查 mapping
//  编码是其逆过程。
//

import Foundation

enum ParamCodec {

    /// 解码：把 63 个字里的某一项解成物理值
    static func decode(_ p: ParamDef, words: [Int]) -> ParamValue {
        guard p.index < words.count else { return .none }
        var raw = words[p.index]

        // 先抠出位区间
        if let bs = p.bitStart, let be = p.bitEnd {
            let width = be - bs + 1
            guard width > 0, width <= 32 else { return .none }
            let mask = ((1 << width) - 1) << bs
            raw = (raw & mask) >> bs
        }

        switch p.type {
        case .uint:
            return .number(clamp(round(Double(raw) / p.scale), p))
        case .int:
            let width = (p.bitEnd ?? 15) - (p.bitStart ?? 0) + 1
            var v = raw
            if width > 0, width <= 32, (v & (1 << (width - 1))) != 0 {
                v -= (1 << width)
            }
            return .number(clamp(round(Double(v) / p.scale), p))
        case .float:
            let v = (Double(raw) / p.scale * 100).rounded() / 100
            return .number(clamp(v, p))
        case .bool:
            return .boolean((raw & 1) != 0)
        case .list:
            var idx = 0
            if p.continuous {
                idx = raw
            } else {
                let bits = [p.bit0, p.bit1, p.bit2]
                for k in 0..<3 {
                    guard let b = bits[k], b >= 0 else { break }
                    if ((raw >> b) & 1) != 0 { idx |= (1 << k) }
                }
            }
            if let m = p.mapping, let mapped = m[idx] { idx = mapped }
            return .list(idx)
        case .text:
            return .number(clamp(Double(raw), p))
        }
    }

    /// 编码：把物理值写回 63 个字
    static func encode(_ p: ParamDef, value: ParamValue, into words: inout [Int]) {
        guard p.index < words.count else { return }
        var word = words[p.index]

        switch p.type {
        case .uint, .float, .text:
            let phys = value.numberValue ?? 0
            var raw = Int((phys * p.scale).rounded())
            if let bs = p.bitStart, let be = p.bitEnd {
                let width = be - bs + 1
                let mask = ((1 << width) - 1) << bs
                raw = max(0, min((1 << width) - 1, raw))
                word = (word & ~mask) | (raw << bs)
            } else {
                word = raw & 0xFFFF
            }
        case .int:
            let phys = value.numberValue ?? 0
            var raw = Int((phys * p.scale).rounded())
            let width = (p.bitEnd ?? 15) - (p.bitStart ?? 0) + 1
            if raw < 0 { raw += (1 << width) }
            let bs = p.bitStart ?? 0
            let mask = ((1 << width) - 1) << bs
            word = (word & ~mask) | ((raw << bs) & mask)
        case .bool:
            let on = value.boolValue ?? false
            let bit = (p.bitStart ?? 0)
            if on { word |= (1 << bit) } else { word &= ~(1 << bit) }
        case .list:
            var idx = value.listValue ?? 0
            // 反向查 mapping
            if let m = p.mapping {
                for (k, v) in m where v == idx { idx = k; break }
            }
            if p.continuous {
                let bs = p.bitStart ?? 0
                let be = p.bitEnd ?? 15
                let width = be - bs + 1
                let mask = ((1 << width) - 1) << bs
                word = (word & ~mask) | ((idx << bs) & mask)
            } else {
                let bits = [p.bit0, p.bit1, p.bit2]
                var clear = 0
                var set = 0
                for k in 0..<3 {
                    guard let b = bits[k], b >= 0 else { break }
                    clear |= (1 << b)
                    if ((idx >> k) & 1) != 0 { set |= (1 << b) }
                }
                word = (word & ~clear) | set
            }
        }
        words[p.index] = word & 0xFFFF
    }

    private static func clamp(_ v: Double, _ p: ParamDef) -> Double {
        var r = v
        if let lo = p.minValue { r = max(lo, r) }
        if let hi = p.maxValue { r = min(hi, r) }
        return r
    }

    private static func round(_ v: Double) -> Double {
        return v.rounded()
    }

    /// 显示文本
    static func display(_ p: ParamDef, _ v: ParamValue) -> String {
        switch v {
        case .boolean(let on):
            let text = on ? (p.onText ?? "开") : (p.offText ?? "关")
            return text
        case .list(let idx):
            if let opts = p.options, idx < opts.count { return opts[idx] }
            return String(idx)
        case .number(let n):
            if p.type == .float { return String(format: "%.2f", n) }
            return String(Int(n.rounded()))
        case .none:
            return "--"
        }
    }

    /// 单位后缀（bool/list 无单位）
    static func unitSuffix(_ p: ParamDef) -> String {
        if p.type == .bool || p.type == .list { return "" }
        return p.unit
    }
}

/// 参数值的三种形态
enum ParamValue {
    case number(Double)
    case boolean(Bool)
    case list(Int)
    case none

    var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    var boolValue: Bool? { if case .boolean(let b) = self { return b }; return nil }
    var listValue: Int? { if case .list(let i) = self { return i }; return nil }
}
