import XCTest
@testable import EquilMTMKit

final class EquilMTMKitTests: XCTestCase {

    func testCRC16MatchesLibrary() {
        // 与 libjni_interface.so 内的 CRC-16/MODBUS 查表结果一致
        let crc = CRC.crc16(Data([0x11, 0x22]))
        var c = CRC.crc16(Data([0x00, 0x33]), init: crc)
        c = CRC.crc16(Data([0xAA, 0xBB, 0xCC, 0xDD]), init: c)
        XCTAssertEqual(c, 0x6942)
    }

    func testFrameEncodingMatchesEmulatedLibraryOutput() {
        let message = PumpMessage(address: 0x01, sourcePort: 0x11, targetPort: 0x22,
                                  mode: .ack, operation: .write, parameter: 0x00,
                                  data: Data([0xAA, 0xBB, 0xCC, 0xDD]))
        let frames = FrameEncoder.frames(for: message, chunkSize: 238)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].encoded().hexString,
                       "0100120080441122576100030300aabbccdd")
    }

    func testRoundTripThroughDecoder() {
        let message = PumpMessage(address: 0x01, sourcePort: 0x11, targetPort: 0x22,
                                  mode: .ack, operation: .set, parameter: 0x07,
                                  data: Data(repeating: 0x55, count: 400))
        let frames = FrameEncoder.frames(for: message, chunkSize: 20)
        XCTAssertEqual(frames.count, 21)

        var decoder = FrameDecoder()
        var assembler = MessageAssembler()
        var decoded: PumpMessage?
        for frame in frames {
            for parsed in decoder.feed(frame.encoded()) {
                XCTAssertTrue(parsed.isCRCOK)
                if let m = assembler.accept(parsed) { decoded = m }
            }
        }
        XCTAssertEqual(decoded?.parameter, 0x07)
        XCTAssertEqual(decoded?.data, message.data)
    }

    func testBasalProfileEncoding() {
        var rates = [Double](repeating: 0, count: 48)
        rates[0] = 1.0
        rates[1] = 0.05
        let data = EntityCodec.basalProfile(rates)
        XCTAssertEqual(data.count, 96)
        XCTAssertEqual([UInt8](data.prefix(4)), [0xE8, 0x03, 0x32, 0x00])   // 1000, 50 小端
    }

    func testTemporaryProfilePercentTag() {
        let abs = EntityCodec.temporaryProfile(rate: 1.5, minutes: 30, percent: false)
        let pct = EntityCodec.temporaryProfile(rate: 120, minutes: 30, percent: true)
        XCTAssertEqual([UInt8](abs.prefix(4)), [0xDC, 0x05, 0x00, 0x00])
        XCTAssertEqual([UInt8](pct.prefix(4)), [0x78, 0x00, 0x00, 0x80])
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
