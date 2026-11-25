import XCTest
@testable import EvDashCore

/// 协议回归测试（XCTest 版，可在 macOS 上 `swift test` 运行）
///
/// 与 Tests/main.swift 覆盖同样的用例；main.swift 是给
/// Windows 上的纯可执行验证用的，两者内容需保持一致。
final class ProtocolTests: XCTestCase {

    // MARK: - 帧构造

    private func buildParam(_ w: [Int]) -> [UInt8] {
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

    private func buildRealtime(_ w: [Int]) -> [UInt8] {
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

    private func feedChunked(_ d: FrameDecoder, _ stream: [UInt8], chunk: Int) -> [Frame] {
        var all: [Frame] = []
        var o = 0
        while o < stream.count {
            let end = min(stream.count, o + chunk)
            all.append(contentsOf: d.feed(Array(stream[o..<end])))
            o = end
        }
        return all
    }

    // MARK: - 校验

    func testParamFrameChecksum() {
        var w = [Int](repeating: 0, count: 63)
        w[0] = 45; w[1] = 200; w[34] = 27; w[60] = 8888
        let f = buildParam(w)
        XCTAssertEqual(f.count, 131)
        XCTAssertEqual(FrameDecoder.wordSum(f, from: 3, to: 131), 0xFFFF)
        XCTAssertEqual(FrameDecoder.word(f, 0), 45)
        XCTAssertEqual(FrameDecoder.word(f, 60), 8888)
    }

    func testRealtimeFrameChecksum() {
        var w = [Int](repeating: 0, count: 31)
        w[8] = Int((72.4 * 273.07).rounded())
        w[9] = 126
        w[18] = 4100
        let f = buildRealtime(w)
        XCTAssertEqual(f.count, 67)
        XCTAssertEqual(FrameDecoder.wordSum(f, from: 3, to: 67), 0xFFFF)
        XCTAssertEqual(Double(FrameDecoder.word(f, 8)) / 273.07, 72.4, accuracy: 0.05)
        XCTAssertEqual(FrameDecoder.s16(FrameDecoder.word(f, 18)) / 100.0, 41.0, accuracy: 0.01)
    }

    // MARK: - 分包重组

    func testChunkedReassembly() {
        var w = [Int](repeating: 0, count: 63)
        w[0] = 45; w[60] = 8888
        let f = buildParam(w)
        let d = FrameDecoder()
        let got = feedChunked(d, f, chunk: 20)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].cmd, 0x11)
        XCTAssertEqual(got[0].data, f)
    }

    // MARK: - 回显帧

    func testEchoFrameDropped() {
        let echo: [UInt8] = [0xAA, 0x13, 0x00, 0x01]
        var w = [Int](repeating: 0, count: 31)
        w[8] = Int((72.4 * 273.07).rounded())
        let rt = buildRealtime(w)
        let d = FrameDecoder()
        let r = feedChunked(d, echo + rt, chunk: 20)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].cmd, 0x13)
    }

    func testAmbiguousRealFrameNotSwallowed() {
        // word0 低字节 == 1，恰好符合回显模式；校验通过必须当真帧
        var w = [Int](repeating: 0, count: 31)
        w[0] = 1
        w[8] = Int((72.4 * 273.07).rounded())
        let rt = buildRealtime(w)
        XCTAssertEqual(rt[2], 0x00)
        XCTAssertEqual(rt[3], 0x01)
        let d = FrameDecoder()
        let r = feedChunked(d, rt, chunk: 20)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].data, rt)
    }

    func testManyEchoesInterleaved() {
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
        XCTAssertEqual(r.count, 5)
    }

    func testGarbageRobustness() {
        let d = FrameDecoder()
        let junk: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0xAA, 0x99, 0x00, 0x01]
        XCTAssertTrue(d.feed(junk).isEmpty)
    }

    // MARK: - 写帧

    func testWriteFrameAssembly() {
        var w = [Int](repeating: 0, count: 63)
        w[0] = 45; w[1] = 200; w[34] = 27; w[60] = 8888
        let frame = FrameDecoder.buildWriteFrame(words: w)
        XCTAssertEqual(frame.count, 131)
        XCTAssertEqual(frame[1], 0x12)
        XCTAssertEqual(FrameDecoder.wordSum(frame, from: 3, to: 131), 0xFFFF)
    }

    // MARK: - 真实固件帧

    func testRealFirmwareFrameChecksum() {
        let hex = "AA1635008081C3000019000900403909004000C8000000404009405949004000E8010000400009094009090009492909694000000000000000000009000000090000F8000040E1"
        var f: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            f.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        XCTAssertEqual(f.count, 71)
        var s = 0
        for k in 3...69 { s = (s + Int(f[k])) & 0xFF }
        XCTAssertEqual((s + Int(f[70])) & 0xFF, 0)
    }

    // MARK: - 参数编解码

    func testParamCodecRoundTrip() {
        var words = [Int](repeating: 0, count: 63)

        let p0 = Params.all.first { $0.name == "母线电流" }!
        ParamCodec.encode(p0, value: .number(45), into: &words)
        XCTAssertEqual(words[0], 45)
        XCTAssertEqual(ParamCodec.decode(p0, words: words).numberValue, 45)

        let p34 = Params.all.first { $0.name == "极对数" }!
        ParamCodec.encode(p34, value: .number(27), into: &words)
        XCTAssertEqual(words[34], 27)

        let pSeries = Params.all.first { $0.name == "电池串数" }!
        let pCap = Params.all.first { $0.name == "电池容量" }!
        ParamCodec.encode(pSeries, value: .number(20), into: &words)
        ParamCodec.encode(pCap, value: .number(60), into: &words)
        XCTAssertEqual(words[46] & 0x3F, 20)
        XCTAssertEqual(words[46] >> 6, 60)
        XCTAssertEqual(ParamCodec.decode(pSeries, words: words).numberValue, 20)
        XCTAssertEqual(ParamCodec.decode(pCap, words: words).numberValue, 60)

        let pLock = Params.all.first { $0.name == "防盗锁电机" }!
        ParamCodec.encode(pLock, value: .boolean(true), into: &words)
        XCTAssertEqual((words[29] >> 1) & 1, 1)
        XCTAssertEqual(ParamCodec.decode(pLock, words: words).boolValue, true)

        let pMode = Params.all.first { $0.name == "骑行模式" }!
        ParamCodec.encode(pMode, value: .list(2), into: &words)
        XCTAssertEqual(ParamCodec.decode(pMode, words: words).listValue, 2)

        let pVolt = Params.all.first { $0.name == "满转把电压" }!
        ParamCodec.encode(pVolt, value: .number(4.2), into: &words)
        XCTAssertEqual(ParamCodec.decode(pVolt, words: words).numberValue ?? 0, 4.2, accuracy: 0.01)
    }

    func testParamTableSanity() {
        XCTAssertEqual(Params.all.count, 71)
        XCTAssertEqual(Params.groups.count, 12)
        XCTAssertTrue(Params.all.allSatisfy { $0.index >= 0 && $0.index <= 62 })
        let grouped = Params.grouped()
        XCTAssertEqual(grouped.count, 12)
        XCTAssertEqual(grouped.reduce(0) { $0 + $1.1.count }, 71)
    }
}
