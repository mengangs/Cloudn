import XCTest
@testable import CloudnKit

/// 多清晰度 m3u8 主列表拆成清晰度组（离线）
final class HLSVariantsTests: XCTestCase {
    private let media = VideoMedia(url: "https://cdn.example.com/v/master.m3u8", kind: .video, fileName: "作品.mp4", isHLS: true,
                                   headers: ["Referer": "https://example.com/"])

    func testSplitsMuxedMaster() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
        720b/index.m3u8
        """
        let list = try XCTUnwrap(HLSVariants.options(for: media, playlist: M3U8.parse(text, baseURL: media.url), group: "hls0"))
        XCTAssertEqual(list.map(\.quality), ["1080P", "720P", "360P"])
        // 默认项仍是原主列表：下载时自动取最高码率
        XCTAssertEqual(list[0].url, media.url)
        XCTAssertEqual(list[0].fileName, "作品.mp4")
        XCTAssertEqual(list[1].url, "https://cdn.example.com/v/720/index.m3u8")
        XCTAssertEqual(list[1].fileName, "作品_720P.mp4")
        XCTAssertEqual(Set(list.map(\.fileName)).count, 3)
        XCTAssertTrue(list.allSatisfy { $0.isHLS && $0.variantGroup == "hls0" && $0.headers == media.headers })
    }

    func testKeepsMasterWithSeparateAudioOrSingleVariant() {
        let withAudio = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",URI="audio.m3u8",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,AUDIO="aud"
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO="aud"
        1080.m3u8
        """
        XCTAssertNil(HLSVariants.options(for: media, playlist: M3U8.parse(withAudio, baseURL: media.url), group: "g"))
        let single = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow.m3u8\n"
        XCTAssertNil(HLSVariants.options(for: media, playlist: M3U8.parse(single, baseURL: media.url), group: "g"))
        let mediaPlaylist = "#EXTM3U\n#EXTINF:4.0,\na.ts\n#EXT-X-ENDLIST\n"
        XCTAssertNil(HLSVariants.options(for: media, playlist: M3U8.parse(mediaPlaylist, baseURL: media.url), group: "g"))
    }

    func testBandwidthLabelWithoutResolution() {
        XCTAssertEqual(HLSVariants.label(height: 0, bandwidth: 2_100_000), "2.1 Mbps")
        XCTAssertEqual(HLSVariants.label(height: 720, bandwidth: 0), "720P")
    }
}
