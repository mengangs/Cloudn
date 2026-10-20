import XCTest
@testable import CloudnKit

final class MSESegmentsTests: XCTestCase {
    /// 一个 MP4 盒子：4 字节大小 + 4 字节类型 + 内容
    func box(_ type: String, _ payload: [UInt8] = []) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        let sizeBytes: [UInt8] = [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
        return sizeBytes + Array(type.utf8) + payload
    }

    func testMP4InitOnly() {
        let initSeg = box("ftyp", [1, 2, 3, 4]) + box("moov", [UInt8](repeating: 7, count: 20))
        let data = Data(initSeg)
        XCTAssertTrue(MSESegments.startsWithInit(data))
        XCTAssertEqual(MSESegments.initLength(data), initSeg.count)
    }

    func testMP4InitFollowedByMedia() {
        let initSeg = box("ftyp", [1, 2, 3, 4]) + box("free") + box("moov", [9, 9])
        let media = box("moof", [1]) + box("mdat", [2, 2, 2])
        XCTAssertEqual(MSESegments.initLength(Data(initSeg + media)), initSeg.count)
    }

    func testMP4MediaSegmentIsNotInit() {
        let media = Data(box("moof", [1]) + box("mdat", [2]))
        XCTAssertFalse(MSESegments.startsWithInit(media))
        XCTAssertNil(MSESegments.initLength(media))
        let styp = Data(box("styp", [0, 0, 0, 0]) + box("moof"))
        XCTAssertFalse(MSESegments.startsWithInit(styp))
    }

    func testMP4TruncatedOrWithoutMoov() {
        XCTAssertNil(MSESegments.initLength(Data(box("ftyp", [1, 2, 3, 4]))))
        let truncated = box("ftyp", [1, 2, 3, 4]) + Array(box("moov", [UInt8](repeating: 1, count: 30)).prefix(20))
        XCTAssertNil(MSESegments.initLength(Data(truncated)))
    }

    func testWebMInitBeforeCluster() {
        // EBML 头（大小 3）+ Segment（未知大小）+ Info（大小 2）+ Tracks（大小 3）+ Cluster
        let ebml: [UInt8] = [0x1A, 0x45, 0xDF, 0xA3, 0x83, 0x42, 0x86, 0x81]
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let info: [UInt8] = [0x15, 0x49, 0xA9, 0x66, 0x82, 0x00, 0x00]
        let tracks: [UInt8] = [0x16, 0x54, 0xAE, 0x6B, 0x83, 0x01, 0x02, 0x03]
        let cluster: [UInt8] = [0x1F, 0x43, 0xB6, 0x75, 0xFF, 0xE7, 0x81, 0x00]
        let head = ebml + segment + info + tracks
        XCTAssertTrue(MSESegments.startsWithInit(Data(head)))
        XCTAssertEqual(MSESegments.initLength(Data(head + cluster)), head.count)
        // 没有 Cluster：整段都是初始化段
        XCTAssertEqual(MSESegments.initLength(Data(head)), head.count)
    }
}
