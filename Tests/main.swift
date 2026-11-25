//
//  ProtocolTest.swift
//  EvDash protocol self-test (pure Foundation, runs on Windows & macOS)
//
//  Covers:
//    1. 131B param frame / 67B realtime frame checksum & field decode
//    2. BLE 20-byte chunked reassembly
//    3. echo frame AA 13 00 01 vs. ambiguous real frame
//    4. garbage robustness
//    5. write frame assembly
//    6. ParamCodec round-trip
//

import Foundation

var pass = 0
var fail = 0

func ok(_ cond: Bool, _ name: String, _ extra: String = "") {
    if cond {
        pass += 1
        print("  PASS \(name)\(extra.isEmpty ? "" : "  \(extra)")")
    } else {
        fail += 1
        print("  FAIL \(name)\(extra.isEmpty ? "" : "  \(extra)")")
    }
}

// MARK: - frame builders

func buildParam(_ w: [Int]) -> [UInt8] {
    var s = 0
    for i in 0..<63 { s = (s + w[i]) & 0xFFFF }
    let ck = (0xFFFF - s) & 0xFFFF
    var f = [UInt8](repeating: 0, count: 131)
    f[0] = 0xAA; f[1] = 0x11; f[2] = 0x00
    for i in 0..<63 {
        f[3 + i * 2] = UInt8(w[i] & 0xFF)
        f[4 + i * 2] = UInt8((w[i] >> 8) & 0xFF)
    }
    f[129] = UInt8(ck & 0xFF)
    f[130] = UInt8((ck >> 8) & 0xFF)
    return f
}

func buildRealtime(_ w: [Int]) -> [UInt8] {
    var s = 0
    for i in 0..<31 { s = (s + w[i]) & 0xFFFF }
    let ck = (0xFFFF - s) & 0xFFFF
    var f = [UInt8](repeating: 0, count: 67)
    f[0] = 0xAA; f[1] = 0x13; f[2] = 0x00
    for i in 0..<31 {
        f[3 + i * 2] = UInt8(w[i] & 0xFF)
        f[4 + i * 2] = UInt8((w[i] >> 8) & 0xFF)
    }
    f[65] = UInt8(ck & 0xFF)
    f[66] = UInt8((ck >> 8) & 0xFF)
    return f
}

func feedChunked(_ d: FrameDecoder, _ stream: [UInt8], chunk: Int) -> [Frame] {
    var all: [Frame] = []
    var o = 0
    while o < stream.count {
        let end = min(stream.count, o + chunk)
        all.append(contentsOf: d.feed(Array(stream[o..<end])))
        o = end
    }
    return all
}

// MARK: - tests

print("[1] 131B param frame")
do {
    var w = [Int](repeating: 0, count: 63)
    w[0] = 45; w[1] = 200; w[34] = 27; w[60] = 8888
    let f = buildParam(w)
    ok(FrameDecoder.wordSum(f, from: 3, to: 131) == 0xFFFF, "64-word sum == 0xFFFF",
       "0x" + String(FrameDecoder.wordSum(f, from: 3, to: 131), radix: 16))
    ok((131 - 3) / 2 == 64, "(131-3)/2 == 64")
    ok(FrameDecoder.word(f, 0) == 45 && FrameDecoder.word(f, 1) == 200
       && FrameDecoder.word(f, 34) == 27 && FrameDecoder.word(f, 60) == 8888,
       "field decode", "\(FrameDecoder.word(f, 0))/\(FrameDecoder.word(f, 60))")
}

print("\n[2] 67B realtime frame")
do {
    var w = [Int](repeating: 0, count: 31)
    w[2] = Int((1.8 * 2450).rounded())
    w[6] = Int((1850 * 5.46).rounded())
    w[8] = Int((72.4 * 273.07).rounded())
    w[9] = 126
    w[18] = 4100
    w[22] = 0b1001
    w[29] = 5220
    let f = buildRealtime(w)
    ok(FrameDecoder.wordSum(f, from: 3, to: 67) == 0xFFFF, "32-word sum == 0xFFFF")
    ok((67 - 3) / 2 == 32, "(67-3)/2 == 32")
    let busV = Double(FrameDecoder.word(f, 8)) / 273.07
    ok(abs(busV - 72.4) < 0.05, "busVoltage ~72.4", String(format: "%.2f", busV))
    ok(FrameDecoder.s16(FrameDecoder.word(f, 9)) == 126, "busCurrent 126")
    ok(abs(FrameDecoder.s16(FrameDecoder.word(f, 18)) / 100.0 - 41.0) < 0.01, "temp 41.00")
}

print("\n[3] chunked reassembly (20B MTU)")
do {
    var w = [Int](repeating: 0, count: 63)
    w[0] = 45; w[60] = 8888
    let f = buildParam(w)
    let d = FrameDecoder()
    let got = feedChunked(d, f, chunk: 20)
    ok(got.count == 1, "one frame out", "n=\(got.count)")
    ok(got.count == 1 && got[0].cmd == 0x11, "cmd == 0x11")
    ok(got.count == 1 && got[0].data == f, "payload intact")
}

print("\n[4] echo frame AA 13 00 01")
do {
    let echo: [UInt8] = [0xAA, 0x13, 0x00, 0x01]
    var w = [Int](repeating: 0, count: 31)
    w[8] = Int((72.4 * 273.07).rounded())
    let rt = buildRealtime(w)
    let d = FrameDecoder()
    let r = feedChunked(d, echo + rt, chunk: 20)
    ok(r.count == 1 && r[0].cmd == 0x13, "echo dropped, real frame kept", "n=\(r.count)")
}

print("\n[5] ambiguous real frame (word0 low byte == 1)")
do {
    var w = [Int](repeating: 0, count: 31)
    w[0] = 1
    w[8] = Int((72.4 * 273.07).rounded())
    let rt = buildRealtime(w)
    ok(rt[2] == 0x00 && rt[3] == 0x01, "frame matches echo pattern")
    let d = FrameDecoder()
    let r = feedChunked(d, rt, chunk: 20)
    ok(r.count == 1 && r[0].data == rt, "checksum wins, not swallowed", "n=\(r.count)")
}

print("\n[6] echo then param frame")
do {
    let echo: [UInt8] = [0xAA, 0x13, 0x00, 0x01]
    var w = [Int](repeating: 0, count: 63)
    w[0] = 45
    let p = buildParam(w)
    let d = FrameDecoder()
    let r = feedChunked(d, echo + p, chunk: 20)
    ok(r.count == 1 && r[0].cmd == 0x11, "param parsed after echo", "n=\(r.count)")
}

print("\n[7] many echoes interleaved")
do {
    var stream: [UInt8] = []
    for i in 0..<5 {
        stream += [0xAA, 0x13, 0x00, 0x01]
        var w = [Int](repeating: 0, count: 31)
        w[0] = i
        w[8] = Int((72.4 * 273.07).rounded())
        stream += buildRealtime(w)
    }
    let d = FrameDecoder()
    let r = feedChunked(d, stream, chunk: 20)
    ok(r.count == 5, "5 real frames, 5 echoes dropped", "n=\(r.count)")
}

print("\n[8] garbage robustness")
do {
    let d = FrameDecoder()
    let junk: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0xAA, 0x99, 0x00, 0x01]
    let r = d.feed(junk)
    ok(r.isEmpty, "no false frames", "n=\(r.count)")
}

print("\n[9] write frame assembly")
do {
    var w = [Int](repeating: 0, count: 63)
    w[0] = 45; w[1] = 200; w[34] = 27; w[60] = 8888
    let frame = FrameDecoder.buildWriteFrame(words: w)
    ok(frame.count == 131, "131 bytes")
    ok(frame[1] == 0x12, "write cmd 0x12 (matches original j[1]=18)")
    ok(FrameDecoder.wordSum(frame, from: 3, to: 131) == 0xFFFF, "write frame checksum valid")
    ok(Int(ceil(131.0 / 20.0)) == 7, "7 chunks at 20B")
}

print("\n[10] real firmware frame checksum (from GEKOO 1.0.5)")
do {
    let hex = "AA1635008081C3000019000900403909004000C8000000404009405949004000E8010000400009094009090009492909694000000000000000000009000000090000F8000040E1"
    var f: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        f.append(UInt8(hex[i..<j], radix: 16) ?? 0)
        i = j
    }
    var s = 0
    for k in 3...69 { s = (s + Int(f[k])) & 0xFF }
    ok(((s + Int(f[70])) & 0xFF) == 0, "firmware frame byte-sum mod 256 == 0", "len=\(f.count)")
}

print("\n[11] ParamCodec round-trip")
do {
    // 母线电流 idx0 uint scale1
    var words = [Int](repeating: 0, count: 63)
    let p0 = Params.all.first { $0.name == "母线电流" }!
    ParamCodec.encode(p0, value: .number(45), into: &words)
    ok(words[0] == 45, "encode 母线电流=45 -> word0=45", "\(words[0])")
    let v0 = ParamCodec.decode(p0, words: words)
    ok(v0.numberValue == 45, "decode back 45", "\(v0.numberValue ?? -1)")

    // 极对数 idx34
    let p34 = Params.all.first { $0.name == "极对数" }!
    ParamCodec.encode(p34, value: .number(27), into: &words)
    ok(words[34] == 27, "encode 极对数=27 -> word34=27", "\(words[34])")

    // 电池串数 idx46 bit0..5, 电池容量 bit6..15
    let pSeries = Params.all.first { $0.name == "电池串数" }!
    let pCap = Params.all.first { $0.name == "电池容量" }!
    ParamCodec.encode(pSeries, value: .number(20), into: &words)
    ParamCodec.encode(pCap, value: .number(60), into: &words)
    ok((words[46] & 0x3F) == 20, "电池串数 20 in bits 0..5", "\(words[46] & 0x3F)")
    ok((words[46] >> 6) == 60, "电池容量 60 in bits 6..15", "\(words[46] >> 6)")
    ok(ParamCodec.decode(pSeries, words: words).numberValue == 20, "decode 电池串数 20")
    ok(ParamCodec.decode(pCap, words: words).numberValue == 60, "decode 电池容量 60")

    // bool: 防盗锁电机 bit1 of word29, reversed
    let pLock = Params.all.first { $0.name == "防盗锁电机" }!
    ParamCodec.encode(pLock, value: .boolean(true), into: &words)
    ok((words[29] >> 1) & 1 == 1, "防盗锁电机=true -> bit1 set")
    ok(ParamCodec.decode(pLock, words: words).boolValue == true, "decode true back")

    // list: 骑行模式 bit0 / bit14
    let pMode = Params.all.first { $0.name == "骑行模式" }!
    ParamCodec.encode(pMode, value: .list(2), into: &words)
    ok(ParamCodec.decode(pMode, words: words).listValue == 2, "骑行模式 round-trip = 2",
       "\(ParamCodec.decode(pMode, words: words).listValue ?? -1)")

    // float: 满转把电压 idx3 scale 2450
    let pVolt = Params.all.first { $0.name == "满转把电压" }!
    ParamCodec.encode(pVolt, value: .number(4.2), into: &words)
    let dv = ParamCodec.decode(pVolt, words: words).numberValue ?? 0
    ok(abs(dv - 4.2) < 0.01, "满转把电压 4.2V round-trip", String(format: "%.2f", dv))
}

print("\n[12] parameter table sanity")
do {
    ok(Params.all.count == 71, "71 params", "\(Params.all.count)")
    ok(Params.groups.count == 12, "12 groups", "\(Params.groups.count)")
    let badIdx = Params.all.filter { $0.index < 0 || $0.index > 62 }
    ok(badIdx.isEmpty, "all word indices in 0..62", badIdx.map { $0.name }.joined(separator: ","))
    let grouped = Params.grouped()
    ok(grouped.count == 12, "grouped() returns 12 sections", "\(grouped.count)")
    let total = grouped.reduce(0) { $0 + $1.1.count }
    ok(total == 71, "grouped() covers all 71", "\(total)")
}

print("\n===== \(pass) passed, \(fail) failed =====")
if fail > 0 { exit(1) }
