import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreGraphics
#endif

/// A QR code as a square matrix of modules — what ``AtlasDeviceSignInView`` draws
/// for the device sign-in link, crisp at any size because it is drawn as vector
/// squares rather than a scaled bitmap.
///
/// ``init(_:errorCorrection:)`` uses Core Image's `CIQRCodeGenerator` on the
/// platforms that have it (iOS, macOS, tvOS, visionOS) and the SDK's own
/// ISO/IEC 18004 encoder (``encode(_:errorCorrection:)``) where Core Image does not
/// exist (watchOS). Both produce a standard byte-mode QR code.
public struct AtlasQRCode: Sendable, Equatable {
    /// Error-correction level: how much of the symbol can be damaged and still scan.
    public enum ErrorCorrection: Int, Sendable, CaseIterable {
        /// ~7% recovery.
        case low
        /// ~15% recovery (the default).
        case medium
        /// ~25% recovery.
        case quartile
        /// ~30% recovery.
        case high

        /// The 2-bit value in the format information.
        var formatBits: Int {
            switch self {
            case .low: return 1
            case .medium: return 0
            case .quartile: return 3
            case .high: return 2
            }
        }

        /// The `inputCorrectionLevel` letter Core Image takes.
        var letter: String {
            switch self {
            case .low: return "L"
            case .medium: return "M"
            case .quartile: return "Q"
            case .high: return "H"
            }
        }
    }

    /// Modules per side (21 for version 1, +4 per version).
    public let size: Int
    /// Row-major modules, `true` = dark. `modules.count == size * size`.
    public let modules: [Bool]

    public init(size: Int, modules: [Bool]) {
        precondition(modules.count == size * size, "modules must be size × size")
        self.size = size
        self.modules = modules
    }

    /// Whether the module at column `x`, row `y` is dark.
    public subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    /// The QR version (1–40) this symbol is.
    public var version: Int { (size - 17) / 4 }

    /// Encode `text` (UTF-8, byte mode). Core Image where the platform has it,
    /// the SDK's encoder otherwise. Returns nil only when the text is too long for
    /// a version-40 symbol.
    public init?(_ text: String, errorCorrection: ErrorCorrection = .medium) {
        #if canImport(CoreImage)
        if let code = AtlasQRCode.coreImage(text, errorCorrection: errorCorrection) {
            self = code
            return
        }
        #endif
        guard let code = AtlasQRCode.encode(text, errorCorrection: errorCorrection) else { return nil }
        self = code
    }
}

// MARK: - Core Image

#if canImport(CoreImage)
extension AtlasQRCode {
    /// Encode with `CIQRCodeGenerator` and read the modules back out of its
    /// one-pixel-per-module image (quiet zone stripped, orientation checked).
    static func coreImage(_ text: String, errorCorrection: ErrorCorrection) -> AtlasQRCode? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(errorCorrection.letter, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, width == height,
              let cgImage = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: extent),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height)

        func dark(_ x: Int, _ y: Int) -> Bool { pixels[y * width + x] < 128 }

        // The quiet zone: the first dark pixel on the diagonal is the top-left
        // finder pattern's corner.
        guard let margin = (0..<width).first(where: { dark($0, $0) }) else { return nil }
        let size = width - 2 * margin
        guard size >= 21, (size - 17) % 4 == 0 else { return nil }

        var modules = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size { modules[y * size + x] = dark(x + margin, y + margin) }
        }
        var code = AtlasQRCode(size: size, modules: modules)
        // A bitmap read bottom-up flips the symbol: the finder that belongs at the
        // top-right then sits at the bottom-right. Flip it back.
        if !code.hasFinder(x: size - 7, y: 0), code.hasFinder(x: size - 7, y: size - 7) {
            code = code.flippedVertically()
        }
        guard code.hasFinder(x: 0, y: 0), code.hasFinder(x: size - 7, y: 0), code.hasFinder(x: 0, y: size - 7) else {
            return nil
        }
        return code
    }

    func flippedVertically() -> AtlasQRCode {
        var flipped = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size { flipped[(size - 1 - y) * size + x] = self[x, y] }
        }
        return AtlasQRCode(size: size, modules: flipped)
    }
}
#endif

extension AtlasQRCode {
    /// Whether a 7×7 finder pattern has its top-left corner at (`x`, `y`).
    func hasFinder(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x + 7 <= size, y + 7 <= size else { return false }
        for dy in 0..<7 {
            for dx in 0..<7 {
                let ring = max(abs(dx - 3), abs(dy - 3))
                if self[x + dx, y + dy] != (ring != 2) { return false }
            }
        }
        return true
    }
}

// MARK: - the SDK's own encoder (ISO/IEC 18004, byte mode)

extension AtlasQRCode {
    /// Encode `text` as UTF-8 bytes in the smallest version (1–40) that fits at
    /// `errorCorrection`, raising the error-correction level when it fits in the
    /// same version for free, and picking the mask with the lowest penalty score.
    /// Pure Swift; used where Core Image is unavailable and testable everywhere.
    public static func encode(_ text: String, errorCorrection: ErrorCorrection = .medium) -> AtlasQRCode? {
        let data = Array(text.utf8)
        var ecl = errorCorrection

        // Smallest version whose data capacity holds the segment.
        var version = 1
        var usedBits = 0
        while true {
            usedBits = 4 + charCountBits(version) + data.count * 8
            if data.count < (1 << charCountBits(version)), usedBits <= dataCodewords(version, ecl) * 8 { break }
            if version >= 40 { return nil }
            version += 1
        }
        for better in [ErrorCorrection.medium, .quartile, .high] where better.rawValue > ecl.rawValue {
            if usedBits <= dataCodewords(version, better) * 8 { ecl = better }
        }

        // Data bits: mode (byte = 0100), character count, the bytes.
        var bits = QRBitBuffer()
        bits.append(0b0100, count: 4)
        bits.append(data.count, count: charCountBits(version))
        for byte in data { bits.append(Int(byte), count: 8) }

        // Terminator, byte alignment, then the alternating pad bytes.
        let capacity = dataCodewords(version, ecl) * 8
        bits.append(0, count: min(4, capacity - bits.count))
        bits.append(0, count: (8 - bits.count % 8) % 8)
        var pad = 0xEC
        while bits.count < capacity {
            bits.append(pad, count: 8)
            pad ^= 0xEC ^ 0x11
        }

        var codewords = [UInt8](repeating: 0, count: bits.count / 8)
        for i in 0..<bits.count where bits.bits[i] {
            codewords[i >> 3] |= UInt8(1 << (7 - (i & 7)))
        }

        var matrix = QRMatrix(version: version, ecl: ecl)
        matrix.drawFunctionPatterns()
        matrix.drawCodewords(addErrorCorrectionAndInterleave(codewords, version: version, ecl: ecl))

        // Choose the mask with the lowest penalty.
        var best = 0
        var bestPenalty = Int.max
        for mask in 0..<8 {
            matrix.applyMask(mask)
            matrix.drawFormatBits(mask: mask)
            let penalty = matrix.penaltyScore()
            if penalty < bestPenalty { best = mask; bestPenalty = penalty }
            matrix.applyMask(mask) // XOR again undoes it
        }
        matrix.applyMask(best)
        matrix.drawFormatBits(mask: best)
        return AtlasQRCode(size: matrix.size, modules: matrix.modules)
    }

    // MARK: tables

    /// Error-correction codewords per block, by level (L, M, Q, H) and version.
    static let eccCodewordsPerBlock: [[Int]] = [
        [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    ]

    /// Error-correction blocks, by level (L, M, Q, H) and version.
    static let errorCorrectionBlocks: [[Int]] = [
        [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
    ]

    /// Width of the byte-mode character-count field.
    static func charCountBits(_ version: Int) -> Int { version <= 9 ? 8 : 16 }

    /// Modules available for data + error correction (everything but function patterns).
    static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let align = version / 7 + 2
            result -= (25 * align - 10) * align - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    /// Data codewords a symbol of `version` at `ecl` holds.
    static func dataCodewords(_ version: Int, _ ecl: ErrorCorrection) -> Int {
        rawDataModules(version) / 8
            - eccCodewordsPerBlock[ecl.rawValue][version] * errorCorrectionBlocks[ecl.rawValue][version]
    }

    /// Split the data into blocks, append each block's Reed–Solomon codewords,
    /// and interleave them.
    static func addErrorCorrectionAndInterleave(_ data: [UInt8], version: Int, ecl: ErrorCorrection) -> [UInt8] {
        let blockCount = errorCorrectionBlocks[ecl.rawValue][version]
        let eccLength = eccCodewordsPerBlock[ecl.rawValue][version]
        let rawCodewords = rawDataModules(version) / 8
        let shortBlocks = blockCount - rawCodewords % blockCount
        let shortBlockLength = rawCodewords / blockCount
        let divisor = reedSolomonDivisor(degree: eccLength)

        var blocks: [[UInt8]] = []
        var offset = 0
        for i in 0..<blockCount {
            let length = shortBlockLength - eccLength + (i < shortBlocks ? 0 : 1)
            var block = Array(data[offset..<(offset + length)])
            offset += length
            let ecc = reedSolomonRemainder(block, divisor: divisor)
            if i < shortBlocks { block.append(0) } // placeholder, skipped below
            blocks.append(block + ecc)
        }

        var result: [UInt8] = []
        result.reserveCapacity(rawCodewords)
        for i in 0..<blocks[0].count {
            for (j, block) in blocks.enumerated() where i != shortBlockLength - eccLength || j >= shortBlocks {
                result.append(block[i])
            }
        }
        return result
    }

    static func reedSolomonDivisor(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = gfMultiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = gfMultiply(root, 0x02)
        }
        return result
    }

    static func reedSolomonRemainder(_ data: [UInt8], divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for i in 0..<result.count { result[i] ^= gfMultiply(divisor[i], factor) }
        }
        return result
    }

    /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    static func gfMultiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= ((Int(y) >> i) & 1) * Int(x)
        }
        return UInt8(z & 0xFF)
    }

    /// Centres of the alignment patterns along one axis.
    static func alignmentPositions(_ version: Int) -> [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let size = version * 4 + 17
        let step = (version * 8 + count * 3 + 5) / (count * 4 - 4) * 2
        var result = [6]
        var position = size - 7
        for _ in 0..<(count - 1) {
            result.insert(position, at: 1)
            position -= step
        }
        return result
    }
}

/// An append-only bit sequence.
struct QRBitBuffer {
    var bits: [Bool] = []
    var count: Int { bits.count }

    mutating func append(_ value: Int, count: Int) {
        guard count > 0 else { return }
        for i in stride(from: count - 1, through: 0, by: -1) { bits.append((value >> i) & 1 == 1) }
    }
}

/// The symbol under construction: modules plus which of them are function patterns.
struct QRMatrix {
    let version: Int
    let ecl: AtlasQRCode.ErrorCorrection
    let size: Int
    var modules: [Bool]
    var isFunction: [Bool]

    init(version: Int, ecl: AtlasQRCode.ErrorCorrection) {
        self.version = version
        self.ecl = ecl
        self.size = version * 4 + 17
        self.modules = [Bool](repeating: false, count: size * size)
        self.isFunction = [Bool](repeating: false, count: size * size)
    }

    subscript(x: Int, y: Int) -> Bool {
        get { modules[y * size + x] }
        set { modules[y * size + x] = newValue }
    }

    mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y * size + x] = dark
        isFunction[y * size + x] = true
    }

    mutating func drawFunctionPatterns() {
        // Timing patterns.
        for i in 0..<size {
            setFunction(6, i, i % 2 == 0)
            setFunction(i, 6, i % 2 == 0)
        }
        // Finder patterns (with separators) in three corners.
        drawFinder(3, 3)
        drawFinder(size - 4, 3)
        drawFinder(3, size - 4)
        // Alignment patterns, except where they would overlap a finder.
        let positions = AtlasQRCode.alignmentPositions(version)
        let n = positions.count
        for i in 0..<n {
            for j in 0..<n where !((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)) {
                drawAlignment(positions[i], positions[j])
            }
        }
        // Reserve the format area (overwritten once the mask is chosen), and the version.
        drawFormatBits(mask: 0)
        drawVersion()
    }

    mutating func drawFinder(_ cx: Int, _ cy: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < size, y >= 0, y < size else { continue }
                let distance = max(abs(dx), abs(dy))
                setFunction(x, y, distance != 2 && distance != 4)
            }
        }
    }

    mutating func drawAlignment(_ cx: Int, _ cy: Int) {
        for dy in -2...2 {
            for dx in -2...2 { setFunction(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1) }
        }
    }

    /// The 15-bit format information (level + mask, BCH-protected, masked with 0x5412).
    static func formatBits(ecl: AtlasQRCode.ErrorCorrection, mask: Int) -> Int {
        let data = ecl.formatBits << 3 | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        return (data << 10 | remainder) ^ 0x5412
    }

    mutating func drawFormatBits(mask: Int) {
        let bits = QRMatrix.formatBits(ecl: ecl, mask: mask)
        func bit(_ i: Int) -> Bool { (bits >> i) & 1 == 1 }
        // Around the top-left finder.
        for i in 0...5 { setFunction(8, i, bit(i)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for i in 9..<15 { setFunction(14 - i, 8, bit(i)) }
        // Split between the other two finders.
        for i in 0..<8 { setFunction(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { setFunction(8, size - 15 + i, bit(i)) }
        // The always-dark module.
        setFunction(8, size - 8, true)
    }

    mutating func drawVersion() {
        guard version >= 7 else { return }
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        let bits = version << 12 | remainder
        for i in 0..<18 {
            let dark = (bits >> i) & 1 == 1
            let a = size - 11 + i % 3, b = i / 3
            setFunction(a, b, dark)
            setFunction(b, a, dark)
        }
    }

    /// Place the codewords in the zig-zag column pairs, right to left.
    mutating func drawCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 } // skip the vertical timing column
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let upward = (right + 1) & 2 == 0
                    let y = upward ? size - 1 - vertical : vertical
                    if !isFunction[y * size + x] && i < data.count * 8 {
                        self[x, y] = (data[i >> 3] >> (7 - UInt8(i & 7))) & 1 == 1
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    /// XOR one of the eight mask patterns over the non-function modules.
    mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y * size + x] {
                let invert: Bool
                switch mask {
                case 0: invert = (x + y) % 2 == 0
                case 1: invert = y % 2 == 0
                case 2: invert = x % 3 == 0
                case 3: invert = (x + y) % 3 == 0
                case 4: invert = (x / 3 + y / 2) % 2 == 0
                case 5: invert = x * y % 2 + x * y % 3 == 0
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0
                default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert { self[x, y].toggle() }
            }
        }
    }

    /// The standard's penalty score: long runs, 2×2 blocks, finder look-alikes,
    /// and dark/light imbalance.
    func penaltyScore() -> Int {
        var result = 0
        for horizontal in [true, false] {
            for a in 0..<size {
                var runColor = false
                var run = 0
                var history = [Int](repeating: 0, count: 7)
                for b in 0..<size {
                    let color = horizontal ? self[b, a] : self[a, b]
                    if color == runColor {
                        run += 1
                        if run == 5 { result += 3 } else if run > 5 { result += 1 }
                    } else {
                        addHistory(run, &history)
                        if !runColor { result += countFinderPatterns(history) * 40 }
                        runColor = color
                        run = 1
                    }
                }
                result += terminateAndCount(runColor, run, &history) * 40
            }
        }
        for y in 0..<(size - 1) {
            for x in 0..<(size - 1) {
                let c = self[x, y]
                if c == self[x + 1, y] && c == self[x, y + 1] && c == self[x + 1, y + 1] { result += 3 }
            }
        }
        let dark = modules.reduce(0) { $0 + ($1 ? 1 : 0) }
        let total = size * size
        let k = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        result += k * 10
        return result
    }

    private func countFinderPatterns(_ history: [Int]) -> Int {
        let n = history[1]
        let core = n > 0 && history[2] == n && history[3] == n * 3 && history[4] == n && history[5] == n
        return (core && history[0] >= n * 4 && history[6] >= n ? 1 : 0)
            + (core && history[6] >= n * 4 && history[0] >= n ? 1 : 0)
    }

    private func terminateAndCount(_ runColor: Bool, _ run: Int, _ history: inout [Int]) -> Int {
        var length = run
        if runColor {
            addHistory(length, &history)
            length = 0
        }
        length += size // the light border past the edge
        addHistory(length, &history)
        return countFinderPatterns(history)
    }

    private func addHistory(_ run: Int, _ history: inout [Int]) {
        var length = run
        if history[0] == 0 { length += size } // the light border before the edge
        history.removeLast()
        history.insert(length, at: 0)
    }
}
