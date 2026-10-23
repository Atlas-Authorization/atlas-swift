import XCTest
@testable import Atlas
#if canImport(CoreImage)
import CoreImage
#endif

/// The QR encoder behind the device sign-in QR code: the SDK's own ISO/IEC 18004
/// encoder (the watchOS path, testable everywhere) against published vectors and
/// the symbol's structural rules, and — on macOS, where Core Image can read QR
/// codes — a full scan of what both the SDK encoder and the Core Image path draw.
final class QRCodeTests: XCTestCase {
    // MARK: published vectors

    func testReedSolomonMatchesTheHelloWorldVector() {
        // "HELLO WORLD", version 1-M (the widely published worked example).
        let data: [UInt8] = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        let ecc = AtlasQRCode.reedSolomonRemainder(data, divisor: AtlasQRCode.reedSolomonDivisor(degree: 10))
        XCTAssertEqual(ecc, [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
    }

    func testReedSolomonMatchesTheISOVector() {
        // ISO/IEC 18004 Annex I: "01234567", version 1-M.
        let data: [UInt8] = [0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11]
        let ecc = AtlasQRCode.reedSolomonRemainder(data, divisor: AtlasQRCode.reedSolomonDivisor(degree: 10))
        XCTAssertEqual(ecc, [0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55])
    }

    func testFormatAndVersionInformationMatchTheStandardTables() {
        XCTAssertEqual(QRMatrix.formatBits(ecl: .low, mask: 0), 0b111011111000100)
        XCTAssertEqual(QRMatrix.formatBits(ecl: .medium, mask: 0), 0b101010000010010)
        XCTAssertEqual(QRMatrix.formatBits(ecl: .quartile, mask: 0), 0b011010101011111)
        XCTAssertEqual(QRMatrix.formatBits(ecl: .high, mask: 0), 0b001011010001001)
        XCTAssertEqual(QRMatrix.formatBits(ecl: .medium, mask: 5), 0b100000011001110)
    }

    func testCapacityTablesMatchTheStandard() {
        // Data codewords per version / level from ISO/IEC 18004 Table 7.
        XCTAssertEqual(AtlasQRCode.dataCodewords(1, .low), 19)
        XCTAssertEqual(AtlasQRCode.dataCodewords(1, .medium), 16)
        XCTAssertEqual(AtlasQRCode.dataCodewords(1, .quartile), 13)
        XCTAssertEqual(AtlasQRCode.dataCodewords(1, .high), 9)
        XCTAssertEqual(AtlasQRCode.dataCodewords(10, .medium), 216)
        XCTAssertEqual(AtlasQRCode.dataCodewords(40, .low), 2956)
        XCTAssertEqual(AtlasQRCode.dataCodewords(40, .high), 1276)
        XCTAssertEqual(AtlasQRCode.alignmentPositions(2), [6, 18])
        XCTAssertEqual(AtlasQRCode.alignmentPositions(7), [6, 22, 38])
        XCTAssertEqual(AtlasQRCode.alignmentPositions(32), [6, 34, 60, 86, 112, 138])
    }

    // MARK: version selection

    func testPicksTheSmallestVersionThatFits() throws {
        XCTAssertEqual(try XCTUnwrap(AtlasQRCode.encode("HELLO")).version, 1)
        XCTAssertEqual(try XCTUnwrap(AtlasQRCode.encode(String(repeating: "a", count: 84))).version, 5)
        XCTAssertEqual(try XCTUnwrap(AtlasQRCode.encode(String(repeating: "a", count: 85))).version, 6)
        XCTAssertEqual(try XCTUnwrap(AtlasQRCode.encode(String(repeating: "a", count: 150))).version, 8)
        XCTAssertEqual(try XCTUnwrap(AtlasQRCode.encode(String(repeating: "a", count: 150))).size, 49)
        XCTAssertNil(AtlasQRCode.encode(String(repeating: "a", count: 3000)), "beyond version 40")
    }

    // MARK: structure

    func testSymbolsFollowTheStructuralRules() throws {
        for text in [
            "HELLO",
            "https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT",
            String(repeating: "https://atlasauth.net/", count: 7),
            String(repeating: "x", count: 400),
        ] {
            let code = try XCTUnwrap(AtlasQRCode.encode(text))
            let n = code.size
            XCTAssertEqual(code.modules.count, n * n)
            XCTAssertTrue(code.hasFinder(x: 0, y: 0), text)
            XCTAssertTrue(code.hasFinder(x: n - 7, y: 0), text)
            XCTAssertTrue(code.hasFinder(x: 0, y: n - 7), text)
            XCTAssertFalse(code.hasFinder(x: n - 7, y: n - 7), text)
            for i in 8..<(n - 8) {
                XCTAssertEqual(code[i, 6], i % 2 == 0, "horizontal timing")
                XCTAssertEqual(code[6, i], i % 2 == 0, "vertical timing")
            }
            XCTAssertTrue(code[8, n - 8], "the dark module")

            // Both copies of the format information agree and decode to a valid word.
            var first = 0, second = 0
            for i in 0...5 { first |= (code[8, i] ? 1 : 0) << i }
            first |= (code[8, 7] ? 1 : 0) << 6
            first |= (code[8, 8] ? 1 : 0) << 7
            first |= (code[7, 8] ? 1 : 0) << 8
            for i in 9..<15 { first |= (code[14 - i, 8] ? 1 : 0) << i }
            for i in 0..<8 { second |= (code[n - 1 - i, 8] ? 1 : 0) << i }
            for i in 8..<15 { second |= (code[8, n - 15 + i] ? 1 : 0) << i }
            XCTAssertEqual(first, second, "format copies agree")
            let valid = AtlasQRCode.ErrorCorrection.allCases.flatMap { ecl in
                (0..<8).map { QRMatrix.formatBits(ecl: ecl, mask: $0) }
            }
            XCTAssertTrue(valid.contains(first), "a valid format word")

            if code.version >= 7 {
                var bits = 0
                for i in 0..<18 { bits |= (code[n - 11 + i % 3, i / 3] ? 1 : 0) << i }
                XCTAssertEqual(bits >> 12, code.version, "version information")
            }
        }
    }

    func testTheVersionSevenWordMatchesTheTable() throws {
        let code = try XCTUnwrap(AtlasQRCode.encode(String(repeating: "a", count: 110)))
        XCTAssertEqual(code.version, 7)
        var bits = 0
        for i in 0..<18 { bits |= (code[code.size - 11 + i % 3, i / 3] ? 1 : 0) << i }
        XCTAssertEqual(bits, 0x07C94)
    }

    func testThePlatformInitialiserAlwaysProducesASymbol() throws {
        let code = try XCTUnwrap(AtlasQRCode("https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT"))
        XCTAssertTrue(code.hasFinder(x: 0, y: 0))
        XCTAssertTrue(code.hasFinder(x: code.size - 7, y: 0))
        XCTAssertTrue(code.hasFinder(x: 0, y: code.size - 7))
        XCTAssertGreaterThanOrEqual(code.version, 3)
    }

    #if canImport(CoreImage)
    func testCoreImagePathReadsBackAnUprightSymbol() throws {
        let text = "https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT"
        let code = try XCTUnwrap(AtlasQRCode.coreImage(text, errorCorrection: .medium))
        XCTAssertTrue(code.hasFinder(x: 0, y: 0))
        XCTAssertTrue(code.hasFinder(x: code.size - 7, y: 0))
        XCTAssertTrue(code.hasFinder(x: 0, y: code.size - 7))
        XCTAssertFalse(code.hasFinder(x: code.size - 7, y: code.size - 7))
        XCTAssertTrue(code[8, code.size - 8], "the dark module")
        // Same data at the same level needs the same version, whoever encodes it.
        XCTAssertEqual(code.size, try XCTUnwrap(AtlasQRCode.encode(text, errorCorrection: .medium)).size)
    }
    #endif

    // MARK: scanning (macOS: Core Image's QR detector)

    #if os(macOS)
    func testTheSDKEncoderScans() throws {
        for text in [
            "HELLO",
            "https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT",
            "otpauth://totp/Atlas:ada@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Atlas",
            String(repeating: "https://atlasauth.net/oauth2/device?user_code=ABCD-EFGH&x=", count: 4),
        ] {
            let code = try XCTUnwrap(AtlasQRCode.encode(text))
            XCTAssertEqual(try scan(code), text, "version \(code.version)")
        }
    }

    func testTheCoreImagePathScans() throws {
        let text = "https://clerk.example.com/oauth2/device?user_code=WDJB-MJHT"
        let code = try XCTUnwrap(AtlasQRCode.coreImage(text, errorCorrection: .medium))
        XCTAssertEqual(try scan(code), text)
    }

    /// Render the modules (4-module quiet zone, 8 px per module) and decode them.
    private func scan(_ code: AtlasQRCode) throws -> String? {
        let scale = 8, quiet = 4
        let side = (code.size + quiet * 2) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for y in 0..<code.size {
            for x in 0..<code.size where code[x, y] {
                for dy in 0..<scale {
                    for dx in 0..<scale {
                        pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0
                    }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let features = detector.features(in: CIImage(cgImage: image))
        return (features.first as? CIQRCodeFeature)?.messageString
    }
    #endif
}
