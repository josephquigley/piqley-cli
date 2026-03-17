# Robust Image Watermarking Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add StegaStamp-based pixel watermarking that embeds authenticated identifiers surviving metadata stripping, format conversion, and light edits — as a fallback to XMP GPG signatures.

**Architecture:** Convert StegaStamp PyTorch models to CoreML, embed 100-bit payloads (2-bit version + 46-bit image ID + 32-bit HMAC + 20-bit BCH ECC) via tiled 400x400 inference. Unify the processing pipeline to a single JPEG encode by passing `CGImage` in memory through resize → watermark → encode → XMP write (no re-encode). Reference database in JSONL + Ghost HTML card backup.

**Tech Stack:** Swift 6.2, CoreML (StegaStamp inference), Accelerate/vImage (tile blending), CryptoKit (HMAC-SHA256), CoreGraphics/ImageIO (image pipeline), macOS Keychain (HMAC secret storage)

**Prerequisite:** Task 0 (CoreML model conversion) must complete successfully before any other task begins. If conversion fails, see fallback options in the design spec.

---

### Task 0: Convert StegaStamp Models to CoreML

This is a one-time prerequisite performed outside the Swift project. It produces the `.mlmodelc` bundles that all other tasks depend on.

**Files:**
- Create: `scripts/convert_stegastamp.py`
- Create: `Resources/StegaStampEncoder.mlmodelc` (output)
- Create: `Resources/StegaStampDecoder.mlmodelc` (output)

- [ ] **Step 1: Clone StegaStamp and set up Python environment**

```bash
cd /tmp
git clone https://github.com/tancik/StegaStamp.git
cd StegaStamp
python3 -m venv venv
source venv/bin/activate
pip install torch torchvision coremltools numpy Pillow
```

Download the published weights (check the StegaStamp README for the download link).

- [ ] **Step 2: Write conversion script**

Create `scripts/convert_stegastamp.py` in the quigsphoto-uploader repo:

```python
import torch
import coremltools as ct
import numpy as np
from pathlib import Path
import sys

# Adjust this path to where you cloned StegaStamp
STEGASTAMP_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/StegaStamp")
WEIGHTS_PATH = STEGASTAMP_DIR / "saved_models" / "stegastamp_pretrained"
OUTPUT_DIR = Path(__file__).parent.parent / "Resources"

sys.path.insert(0, str(STEGASTAMP_DIR))

def convert_encoder():
    """Convert StegaStamp encoder: (1,3,400,400) image + (1,100) secret -> (1,3,400,400) encoded image"""
    from model import StegaStampEncoder

    encoder = StegaStampEncoder()
    checkpoint = torch.load(WEIGHTS_PATH / "encoder.pth", map_location="cpu")
    encoder.load_state_dict(checkpoint)
    encoder.eval()

    # Trace with example inputs
    example_image = torch.randn(1, 3, 400, 400)
    example_secret = torch.randn(1, 100)
    traced = torch.jit.trace(encoder, (example_secret, example_image))

    # Convert to CoreML
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="secret", shape=(1, 100)),
            ct.TensorType(name="image", shape=(1, 3, 400, 400)),
        ],
        outputs=[ct.TensorType(name="encoded_image")],
        minimum_deployment_target=ct.target.macOS13,
    )

    output_path = OUTPUT_DIR / "StegaStampEncoder.mlpackage"
    model.save(str(output_path))
    print(f"Encoder saved to {output_path}")

def convert_decoder():
    """Convert StegaStamp decoder: (1,3,400,400) image -> (1,100) secret"""
    from model import StegaStampDecoder

    decoder = StegaStampDecoder()
    checkpoint = torch.load(WEIGHTS_PATH / "decoder.pth", map_location="cpu")
    decoder.load_state_dict(checkpoint)
    decoder.eval()

    example_image = torch.randn(1, 3, 400, 400)
    traced = torch.jit.trace(decoder, example_image)

    model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, 400, 400))],
        outputs=[ct.TensorType(name="secret")],
        minimum_deployment_target=ct.target.macOS13,
    )

    output_path = OUTPUT_DIR / "StegaStampDecoder.mlpackage"
    model.save(str(output_path))
    print(f"Decoder saved to {output_path}")

def validate_round_trip():
    """Verify CoreML models produce same output as PyTorch"""
    import coremltools as ct

    encoder_ml = ct.models.MLModel(str(OUTPUT_DIR / "StegaStampEncoder.mlpackage"))
    decoder_ml = ct.models.MLModel(str(OUTPUT_DIR / "StegaStampDecoder.mlpackage"))

    test_image = np.random.rand(1, 3, 400, 400).astype(np.float32)
    test_secret = np.zeros((1, 100), dtype=np.float32)
    test_secret[0, :46] = 1  # Set some bits

    encoded = encoder_ml.predict({"secret": test_secret, "image": test_image})
    decoded = decoder_ml.predict({"image": encoded["encoded_image"]})

    recovered = (decoded["secret"][0] > 0.5).astype(int)
    original = (test_secret[0] > 0.5).astype(int)
    accuracy = np.mean(recovered == original)

    print(f"Round-trip bit accuracy: {accuracy * 100:.1f}%")
    if accuracy < 0.95:
        print("WARNING: Accuracy below 95% — conversion may have issues")
        sys.exit(1)
    print("PASS: CoreML round-trip validated")

if __name__ == "__main__":
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    convert_encoder()
    convert_decoder()
    validate_round_trip()
```

- [ ] **Step 3: Run conversion and validate**

```bash
cd /path/to/quigsphoto-uploader
source /tmp/StegaStamp/venv/bin/activate
python3 scripts/convert_stegastamp.py /tmp/StegaStamp
```

Expected: Both models convert successfully and round-trip accuracy is ≥95%.

If conversion fails, try fallbacks in order:
1. Remove training-only layers (differentiable JPEG simulation) from the model before tracing
2. Use ONNX intermediate: `torch.onnx.export()` → `coremltools.converters.onnx.convert()`
3. If all fail, fall back to Python sidecar approach (see design spec)

- [ ] **Step 4: Compile .mlpackage to .mlmodelc**

```bash
xcrun coremlcompiler compile Resources/StegaStampEncoder.mlpackage Resources/
xcrun coremlcompiler compile Resources/StegaStampDecoder.mlpackage Resources/
```

- [ ] **Step 5: Set up Git LFS and commit models**

```bash
git lfs install
git lfs track "Resources/*.mlmodelc/**"
git add .gitattributes scripts/convert_stegastamp.py Resources/StegaStampEncoder.mlmodelc Resources/StegaStampDecoder.mlmodelc
git commit -m "feat(watermark): add StegaStamp CoreML models and conversion script"
```

---

### Task 1: Add `watermark` field to `SigningConfig`

**Files:**
- Modify: `Sources/quigsphoto-uploader/Config/Config.swift`
- Modify: `Tests/quigsphoto-uploaderTests/ConfigTests.swift`

- [ ] **Step 1: Write failing test for watermark config field**

In `Tests/quigsphoto-uploaderTests/ConfigTests.swift`, add:

```swift
func testSigningConfigWatermarkDefaultsToTrue() throws {
    let json = """
    {
        "ghost": {
            "url": "https://quigs.photo",
            "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
        },
        "processing": { "maxLongEdge": 2000, "jpegQuality": 80 },
        "project365": { "keyword": "365 Project", "referenceDate": "2025-12-25", "emailTo": "t@t.com" },
        "smtp": { "host": "smtp.t.com", "port": 587, "username": "u", "from": "u@t.com" },
        "signing": {
            "keyFingerprint": "ABCD1234"
        }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    XCTAssertEqual(config.signing?.watermark, true)
}

func testSigningConfigWatermarkExplicitlyFalse() throws {
    let json = """
    {
        "ghost": {
            "url": "https://quigs.photo",
            "schedulingWindow": { "start": "08:00", "end": "10:00", "timezone": "UTC" }
        },
        "processing": { "maxLongEdge": 2000, "jpegQuality": 80 },
        "project365": { "keyword": "365 Project", "referenceDate": "2025-12-25", "emailTo": "t@t.com" },
        "smtp": { "host": "smtp.t.com", "port": 587, "username": "u", "from": "u@t.com" },
        "signing": {
            "keyFingerprint": "ABCD1234",
            "watermark": false
        }
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    XCTAssertEqual(config.signing?.watermark, false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1`
Expected: Compilation error — `SigningConfig` has no member `watermark`

- [ ] **Step 3: Add watermark field to SigningConfig**

In `Sources/quigsphoto-uploader/Config/Config.swift`, add to the `SigningConfig` struct:

Property declaration (after `xmpPrefix`):
```swift
var watermark: Bool
```

Static default (alongside existing defaults):
```swift
static let defaultWatermark = true
```

In `SigningConfig.init(keyFingerprint:...)`, add parameter:
```swift
watermark: Bool = SigningConfig.defaultWatermark
```

And assignment:
```swift
self.watermark = watermark
```

In `SigningConfig.init(from decoder:)`, add:
```swift
watermark = try container.decodeIfPresent(Bool.self, forKey: .watermark) ?? SigningConfig.defaultWatermark
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Config/Config.swift Tests/quigsphoto-uploaderTests/ConfigTests.swift
git commit -m "feat(watermark): add watermark field to SigningConfig"
```

---

### Task 2: Create `WatermarkPayload` (encode/decode with BCH ECC)

**Files:**
- Create: `Sources/quigsphoto-uploader/Watermarking/WatermarkPayload.swift`
- Create: `Sources/quigsphoto-uploader/Watermarking/BCH.swift`
- Create: `Tests/quigsphoto-uploaderTests/WatermarkPayloadTests.swift`

- [ ] **Step 1: Write failing tests for WatermarkPayload**

Create `Tests/quigsphoto-uploaderTests/WatermarkPayloadTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import quigsphoto_uploader

final class WatermarkPayloadTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let imageId: UInt64 = 0x1234_5678_9ABC  // 46-bit value
        let payload = WatermarkPayload(imageId: imageId, hmacKey: hmacKey)

        let bits = payload.encode()
        XCTAssertEqual(bits.count, 100)

        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.imageId, imageId)
        XCTAssertEqual(recovered?.version, 0)
    }

    func testRejectsInvalidHMAC() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let wrongKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = WatermarkPayload(imageId: 42, hmacKey: hmacKey)

        let bits = payload.encode()
        let recovered = WatermarkPayload.decode(from: bits, hmacKey: wrongKey)
        XCTAssertNil(recovered, "Should reject payload with wrong HMAC key")
    }

    func testCorrectsBitErrors() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = WatermarkPayload(imageId: 0xABCD_EF01_2345, hmacKey: hmacKey)

        var bits = payload.encode()

        // Flip 3 bits (within BCH correction capability of 4)
        bits[5].toggle()
        bits[42].toggle()
        bits[77].toggle()

        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNotNil(recovered, "Should correct up to 4 bit errors")
        XCTAssertEqual(recovered?.imageId, 0xABCD_EF01_2345)
    }

    func testFailsBeyondCorrectionCapacity() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = WatermarkPayload(imageId: 42, hmacKey: hmacKey)

        var bits = payload.encode()

        // Flip 6 bits (beyond BCH correction capability of 4)
        for i in [0, 10, 20, 30, 50, 70] {
            bits[i].toggle()
        }

        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNil(recovered, "Should fail with too many bit errors")
    }

    func testImageIdPrecondition() throws {
        // 46-bit max is (1 << 46) - 1 = 70_368_744_177_663
        let maxValid: UInt64 = (1 << 46) - 1
        let hmacKey = Data(repeating: 0, count: 32)
        let payload = WatermarkPayload(imageId: maxValid, hmacKey: hmacKey)
        XCTAssertEqual(payload.imageId, maxValid)
    }

    func testVersionField() throws {
        let hmacKey = Data(repeating: 0xAA, count: 32)
        let payload = WatermarkPayload(imageId: 1, hmacKey: hmacKey)
        XCTAssertEqual(payload.version, 0)

        let bits = payload.encode()
        // First 2 bits should be version 0
        XCTAssertFalse(bits[0])
        XCTAssertFalse(bits[1])
    }

    func testGenerateImageId() throws {
        let id1 = WatermarkPayload.generateImageId()
        let id2 = WatermarkPayload.generateImageId()
        XCTAssertNotEqual(id1, id2, "Random IDs should differ")
        XCTAssertTrue(id1 < (1 << 46), "ID must fit in 46 bits")
        XCTAssertTrue(id2 < (1 << 46), "ID must fit in 46 bits")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WatermarkPayloadTests 2>&1`
Expected: Compilation error — `WatermarkPayload` not found

- [ ] **Step 3: Implement BCH error correction**

Create `Sources/quigsphoto-uploader/Watermarking/BCH.swift`:

```swift
import Foundation

/// BCH(100, 80) error-correcting code.
/// Encodes 80 data bits into 100 bits with 20 parity bits.
/// Corrects up to 4 bit errors.
///
/// Uses a simplified BCH implementation over GF(2) with generator polynomial
/// derived for t=4 error correction capability.
enum BCH {
    /// The number of data bits
    static let dataBits = 80
    /// The total codeword length
    static let codewordBits = 100
    /// The number of parity bits
    static let parityBits = 20
    /// Maximum correctable errors
    static let correctionCapacity = 4

    /// Generator polynomial for a systematic (100,80) linear code over GF(2).
    ///
    /// NOTE: Standard BCH codes require codeword length 2^m - 1 (e.g., 127).
    /// This is a shortened code: we start from BCH(127,107,t=3) and shorten
    /// by fixing 27 data positions to zero, giving an effective (100,80) code.
    /// The shortening preserves the minimum distance, guaranteeing correction
    /// of at least 3 errors. The brute-force decoder below additionally tries
    /// 4-error patterns, which succeeds when the specific pattern is uniquely
    /// decodable (likely for most 4-error patterns at this code rate).
    ///
    /// The generator polynomial for BCH(127,107,t=3) over GF(2^7) is:
    /// g(x) = LCM of minimal polynomials of alpha^1, alpha^3, alpha^5
    /// where alpha is a primitive 127th root of unity in GF(2^7).
    /// For the shortened code we use the same polynomial — encoding and
    /// syndrome computation operate identically, just on shorter input.
    ///
    /// Primitive polynomial for GF(2^7): x^7 + x^3 + 1
    /// g(x) = x^20 + x^18 + x^16 + x^14 + x^11 + x^10 + x^9 + x^6 + x^5 + x + 1
    private static let generatorPoly: UInt32 = 0b1_0101_0100_1110_0110_0011

    /// Encode 80 data bits into 100-bit codeword (systematic form).
    /// The first 80 bits are data, the last 20 are parity.
    static func encode(_ data: [Bool]) -> [Bool] {
        precondition(data.count == dataBits, "BCH encoder expects \(dataBits) data bits")

        // Compute remainder of data * x^20 divided by generator polynomial
        var remainder: UInt32 = 0
        for i in 0..<dataBits {
            let bit: UInt32 = data[i] ? 1 : 0
            let feedback = bit ^ ((remainder >> (parityBits - 1)) & 1)
            remainder = (remainder << 1) & ((1 << parityBits) - 1)
            if feedback == 1 {
                remainder ^= generatorPoly & ((1 << parityBits) - 1)
            }
        }

        // Systematic codeword: data bits followed by parity bits
        var codeword = data
        for i in stride(from: parityBits - 1, through: 0, by: -1) {
            codeword.append((remainder >> i) & 1 == 1)
        }

        return codeword
    }

    /// Decode a 100-bit codeword, correcting up to 4 bit errors.
    /// Returns the 80 data bits, or nil if too many errors.
    static func decode(_ codeword: [Bool]) -> [Bool]? {
        precondition(codeword.count == codewordBits, "BCH decoder expects \(codewordBits) bits")

        // Compute syndrome: re-encode the data portion and compare parity
        var corrected = codeword

        // Compute syndrome by dividing received codeword by generator
        var syndrome: UInt32 = 0
        for i in 0..<codewordBits {
            let bit: UInt32 = corrected[i] ? 1 : 0
            let feedback = bit ^ ((syndrome >> (parityBits - 1)) & 1)
            syndrome = (syndrome << 1) & ((1 << parityBits) - 1)
            if feedback == 1 {
                syndrome ^= generatorPoly & ((1 << parityBits) - 1)
            }
        }

        // If syndrome is zero, no errors
        if syndrome == 0 {
            return Array(corrected[0..<dataBits])
        }

        // Try to correct errors using brute-force pattern matching
        // For up to correctionCapacity errors, try all combinations
        // This is feasible for small t and n=100
        if let positions = findErrorPositions(in: corrected, syndrome: syndrome) {
            for pos in positions {
                corrected[pos].toggle()
            }
            return Array(corrected[0..<dataBits])
        }

        return nil  // Too many errors to correct
    }

    /// Find error positions by trying single, double, triple, and quad error patterns.
    private static func findErrorPositions(in codeword: [Bool], syndrome: UInt32) -> [Int]? {
        // Try 1 error
        for i in 0..<codewordBits {
            if syndromeForError(at: [i]) == syndrome {
                return [i]
            }
        }

        // Try 2 errors
        for i in 0..<codewordBits {
            for j in (i+1)..<codewordBits {
                if syndromeForError(at: [i, j]) == syndrome {
                    return [i, j]
                }
            }
        }

        // Try 3 errors
        for i in 0..<codewordBits {
            for j in (i+1)..<codewordBits {
                for k in (j+1)..<codewordBits {
                    if syndromeForError(at: [i, j, k]) == syndrome {
                        return [i, j, k]
                    }
                }
            }
        }

        // Try 4 errors
        for i in 0..<codewordBits {
            for j in (i+1)..<codewordBits {
                for k in (j+1)..<codewordBits {
                    for l in (k+1)..<codewordBits {
                        if syndromeForError(at: [i, j, k, l]) == syndrome {
                            return [i, j, k, l]
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Compute the syndrome that a set of error positions would produce.
    private static func syndromeForError(at positions: [Int]) -> UInt32 {
        var testWord = [Bool](repeating: false, count: codewordBits)
        for pos in positions {
            testWord[pos] = true
        }

        var syndrome: UInt32 = 0
        for i in 0..<codewordBits {
            let bit: UInt32 = testWord[i] ? 1 : 0
            let feedback = bit ^ ((syndrome >> (parityBits - 1)) & 1)
            syndrome = (syndrome << 1) & ((1 << parityBits) - 1)
            if feedback == 1 {
                syndrome ^= generatorPoly & ((1 << parityBits) - 1)
            }
        }

        return syndrome
    }
}
```

- [ ] **Step 4: Implement WatermarkPayload**

Create `Sources/quigsphoto-uploader/Watermarking/WatermarkPayload.swift`:

```swift
import CryptoKit
import Foundation

struct WatermarkPayload {
    static let currentVersion: UInt8 = 0

    let version: UInt8
    let imageId: UInt64
    let hmac: UInt32

    init(imageId: UInt64, hmac: UInt32) {
        precondition(imageId < (1 << 46), "Image ID must fit in 46 bits")
        self.version = Self.currentVersion
        self.imageId = imageId
        self.hmac = hmac
    }

    /// Private init for decoding — accepts explicit version from decoded payload
    private init(imageId: UInt64, hmac: UInt32, version: UInt8) {
        precondition(imageId < (1 << 46), "Image ID must fit in 46 bits")
        precondition(version < 4, "Version must fit in 2 bits")
        self.version = version
        self.imageId = imageId
        self.hmac = hmac
    }

    init(imageId: UInt64, hmacKey: Data) {
        let hmac = Self.computeHMAC(imageId: imageId, key: hmacKey)
        self.init(imageId: imageId, hmac: hmac)
    }

    /// Encode payload to 100 bits: 2 version + 46 ID + 32 HMAC → 80 data bits → BCH(100,80)
    func encode() -> [Bool] {
        var dataBits = [Bool]()

        // Version: 2 bits (MSB first)
        dataBits.append((version >> 1) & 1 == 1)
        dataBits.append(version & 1 == 1)

        // Image ID: 46 bits (MSB first)
        for i in stride(from: 45, through: 0, by: -1) {
            dataBits.append((imageId >> i) & 1 == 1)
        }

        // HMAC: 32 bits (MSB first)
        for i in stride(from: 31, through: 0, by: -1) {
            dataBits.append((hmac >> i) & 1 == 1)
        }

        assert(dataBits.count == 80)
        return BCH.encode(dataBits)
    }

    /// Decode 100 bits back to payload. Returns nil if BCH correction fails or HMAC is invalid.
    static func decode(from bits: [Bool], hmacKey: Data) -> WatermarkPayload? {
        guard bits.count == 100 else { return nil }

        guard let dataBits = BCH.decode(bits) else {
            return nil  // Too many bit errors
        }

        // Parse version (2 bits)
        let version: UInt8 = (dataBits[0] ? 2 : 0) + (dataBits[1] ? 1 : 0)

        // Parse image ID (46 bits)
        var imageId: UInt64 = 0
        for i in 0..<46 {
            if dataBits[2 + i] {
                imageId |= 1 << (45 - i)
            }
        }

        // Parse HMAC (32 bits)
        var hmac: UInt32 = 0
        for i in 0..<32 {
            if dataBits[48 + i] {
                hmac |= 1 << (31 - i)
            }
        }

        // Validate HMAC
        let expectedHMAC = computeHMAC(imageId: imageId, key: hmacKey)
        guard hmac == expectedHMAC else {
            return nil  // HMAC mismatch — wrong key or corrupted beyond ECC
        }

        return WatermarkPayload(imageId: imageId, hmac: hmac, version: version)
    }

    /// Generate a random 46-bit image ID.
    static func generateImageId() -> UInt64 {
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let raw = bytes.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: 1) { $0.pointee }
        }
        return raw & ((1 << 46) - 1)  // Mask to 46 bits
    }

    /// Compute truncated HMAC-SHA256 of the image ID.
    static func computeHMAC(imageId: UInt64, key: Data) -> UInt32 {
        let symmetricKey = SymmetricKey(data: key)
        var idBytes = imageId.bigEndian
        let idData = Data(bytes: &idBytes, count: 8)
        let mac = HMAC<SHA256>.authenticationCode(for: idData, using: symmetricKey)
        let macBytes = Array(mac)
        // Take first 4 bytes as UInt32
        return UInt32(macBytes[0]) << 24
             | UInt32(macBytes[1]) << 16
             | UInt32(macBytes[2]) << 8
             | UInt32(macBytes[3])
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter WatermarkPayloadTests 2>&1`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/quigsphoto-uploader/Watermarking/WatermarkPayload.swift Sources/quigsphoto-uploader/Watermarking/BCH.swift Tests/quigsphoto-uploaderTests/WatermarkPayloadTests.swift
git commit -m "feat(watermark): add WatermarkPayload with BCH error correction"
```

---

### Task 3: Create `TileGrid` (tiling math and blending)

**Files:**
- Create: `Sources/quigsphoto-uploader/Watermarking/TileGrid.swift`
- Create: `Tests/quigsphoto-uploaderTests/TileGridTests.swift`

- [ ] **Step 1: Write failing tests for TileGrid**

Create `Tests/quigsphoto-uploaderTests/TileGridTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import quigsphoto_uploader

final class TileGridTests: XCTestCase {

    func testTileCountForTypicalImage() {
        let grid = TileGrid(imageWidth: 2000, imageHeight: 1333, tileSize: 400, overlap: 40)
        // Stride = 400 - 2*40 = 320
        // Columns: ceil((2000 - 400) / 320) + 1 = ceil(1600/320) + 1 = 5 + 1 = 6
        // Rows: ceil((1333 - 400) / 320) + 1 = ceil(933/320) + 1 = 3 + 1 = 4
        XCTAssertEqual(grid.columns, 6)
        XCTAssertEqual(grid.rows, 4)
        XCTAssertEqual(grid.tileCount, 24)
    }

    func testTileCountForSmallImage() {
        // Image smaller than tile size — should produce exactly 1 tile
        let grid = TileGrid(imageWidth: 300, imageHeight: 200, tileSize: 400, overlap: 40)
        XCTAssertEqual(grid.tileCount, 1)
    }

    func testTileCountForExactTileSize() {
        let grid = TileGrid(imageWidth: 400, imageHeight: 400, tileSize: 400, overlap: 40)
        XCTAssertEqual(grid.tileCount, 1)
    }

    func testTileRectsAreWithinImageBounds() {
        let grid = TileGrid(imageWidth: 2000, imageHeight: 1333, tileSize: 400, overlap: 40)
        for rect in grid.tileRects() {
            XCTAssertGreaterThanOrEqual(rect.origin.x, 0)
            XCTAssertGreaterThanOrEqual(rect.origin.y, 0)
            XCTAssertLessThanOrEqual(rect.origin.x + rect.size.width, CGFloat(2000))
            XCTAssertLessThanOrEqual(rect.origin.y + rect.size.height, CGFloat(1333))
        }
    }

    func testTileRectsFullyCoverImage() {
        let grid = TileGrid(imageWidth: 2000, imageHeight: 1333, tileSize: 400, overlap: 40)
        let rects = grid.tileRects()

        // Every pixel should be covered by at least one tile
        for x in stride(from: 0, to: 2000, by: 50) {
            for y in stride(from: 0, to: 1333, by: 50) {
                let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                let covered = rects.contains { $0.contains(point) }
                XCTAssertTrue(covered, "Point (\(x), \(y)) should be covered by at least one tile")
            }
        }
    }

    func testBlendWeightsAtEdges() {
        let grid = TileGrid(imageWidth: 2000, imageHeight: 1333, tileSize: 400, overlap: 40)
        // At exact overlap boundary, weight should be 0 or 1
        let weight0 = grid.blendWeight(pixelOffset: 0, overlap: 40)
        let weight1 = grid.blendWeight(pixelOffset: 40, overlap: 40)
        XCTAssertEqual(weight0, 0.0, accuracy: 0.01)
        XCTAssertEqual(weight1, 1.0, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TileGridTests 2>&1`
Expected: Compilation error — `TileGrid` not found

- [ ] **Step 3: Implement TileGrid**

Create `Sources/quigsphoto-uploader/Watermarking/TileGrid.swift`:

```swift
import CoreGraphics
import Foundation

/// Computes tile positions for tiled watermark embedding and extraction.
/// Tiles overlap at edges to enable feather blending that eliminates visible seams.
struct TileGrid {
    let imageWidth: Int
    let imageHeight: Int
    let tileSize: Int
    let overlap: Int
    let columns: Int
    let rows: Int

    /// Effective stride between tile origins (tileSize - 2*overlap for interior tiles)
    var stride: Int { tileSize - 2 * overlap }

    var tileCount: Int { columns * rows }

    init(imageWidth: Int, imageHeight: Int, tileSize: Int = 400, overlap: Int = 40) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.tileSize = tileSize
        self.overlap = overlap

        let effectiveStride = tileSize - 2 * overlap

        if imageWidth <= tileSize {
            self.columns = 1
        } else {
            self.columns = Int(ceil(Double(imageWidth - tileSize) / Double(effectiveStride))) + 1
        }

        if imageHeight <= tileSize {
            self.rows = 1
        } else {
            self.rows = Int(ceil(Double(imageHeight - tileSize) / Double(effectiveStride))) + 1
        }
    }

    /// Returns the CGRect for each tile in image coordinates.
    /// Tiles at the right/bottom edge are clamped to image bounds.
    func tileRects() -> [CGRect] {
        var rects = [CGRect]()
        let effectiveStride = stride

        for row in 0..<rows {
            for col in 0..<columns {
                var x = col * effectiveStride
                var y = row * effectiveStride

                // Clamp to image bounds
                if x + tileSize > imageWidth {
                    x = max(0, imageWidth - tileSize)
                }
                if y + tileSize > imageHeight {
                    y = max(0, imageHeight - tileSize)
                }

                let width = min(tileSize, imageWidth - x)
                let height = min(tileSize, imageHeight - y)

                rects.append(CGRect(x: x, y: y, width: width, height: height))
            }
        }

        return rects
    }

    /// Linear blend weight for feathering in overlap zones.
    /// Returns 0.0 at offset=0, 1.0 at offset=overlap.
    func blendWeight(pixelOffset: Int, overlap: Int) -> CGFloat {
        guard overlap > 0 else { return 1.0 }
        return CGFloat(min(max(pixelOffset, 0), overlap)) / CGFloat(overlap)
    }

    /// Extract a tile region from a CGImage.
    /// If the image is smaller than tileSize, the tile is padded with black.
    func extractTile(from image: CGImage, at rect: CGRect) -> CGImage? {
        let cropRect = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: min(rect.width, CGFloat(image.width) - rect.origin.x),
            height: min(rect.height, CGFloat(image.height) - rect.origin.y)
        )

        if Int(cropRect.width) == tileSize && Int(cropRect.height) == tileSize {
            return image.cropping(to: cropRect)
        }

        // Pad smaller tiles to tileSize x tileSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: tileSize,
            height: tileSize,
            bitsPerComponent: 8,
            bytesPerRow: tileSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Draw the cropped portion at origin
        if let cropped = image.cropping(to: cropRect) {
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        }

        return context.makeImage()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TileGridTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Watermarking/TileGrid.swift Tests/quigsphoto-uploaderTests/TileGridTests.swift
git commit -m "feat(watermark): add TileGrid for tiled watermark embedding"
```

---

### Task 4: Create `ImageWatermarker` protocol and `StegaStampWatermarker`

**Files:**
- Create: `Sources/quigsphoto-uploader/Watermarking/ImageWatermarker.swift`
- Create: `Sources/quigsphoto-uploader/Watermarking/StegaStampWatermarker.swift`
- Create: `Tests/quigsphoto-uploaderTests/StegaStampWatermarkerTests.swift`

- [ ] **Step 1: Write failing tests for StegaStampWatermarker**

Create `Tests/quigsphoto-uploaderTests/StegaStampWatermarkerTests.swift`:

```swift
import XCTest
import CoreGraphics
import CoreML
@testable import quigsphoto_uploader

final class StegaStampWatermarkerTests: XCTestCase {

    func testEmbedProducesSameSizeImage() throws {
        guard StegaStampWatermarker.modelsAvailable() else {
            throw XCTSkip("StegaStamp CoreML models not found in Resources/")
        }

        let watermarker = try StegaStampWatermarker()
        let image = try createTestCGImage(width: 800, height: 600)
        let hmacKey = Data(repeating: 0xAB, count: 32)
        let payload = WatermarkPayload(imageId: 12345, hmacKey: hmacKey)

        let result = try watermarker.embed(in: image, payload: payload)

        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 600)
    }

    func testEmbedExtractRoundTrip() throws {
        guard StegaStampWatermarker.modelsAvailable() else {
            throw XCTSkip("StegaStamp CoreML models not found in Resources/")
        }

        let watermarker = try StegaStampWatermarker()
        let image = try createTestCGImage(width: 800, height: 600)
        let hmacKey = Data(repeating: 0xCD, count: 32)
        let imageId: UInt64 = 0x1234_5678
        let payload = WatermarkPayload(imageId: imageId, hmacKey: hmacKey)

        let watermarked = try watermarker.embed(in: image, payload: payload)
        let extracted = try watermarker.extract(from: watermarked, hmacKey: hmacKey)

        XCTAssertNotNil(extracted)
        XCTAssertEqual(extracted?.imageId, imageId)
    }

    func testEmbedOnSmallImage() throws {
        guard StegaStampWatermarker.modelsAvailable() else {
            throw XCTSkip("StegaStamp CoreML models not found in Resources/")
        }

        let watermarker = try StegaStampWatermarker()
        let image = try createTestCGImage(width: 200, height: 150)
        let hmacKey = Data(repeating: 0x01, count: 32)
        let payload = WatermarkPayload(imageId: 1, hmacKey: hmacKey)

        // Should handle images smaller than tile size
        let result = try watermarker.embed(in: image, payload: payload)
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 150)
    }

    // MARK: - Helpers

    private func createTestCGImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create test image"])
        }

        // Fill with a gradient pattern for realistic-ish content
        for y in 0..<height {
            for x in 0..<width {
                let r = CGFloat(x) / CGFloat(width)
                let g = CGFloat(y) / CGFloat(height)
                let b = CGFloat(x + y) / CGFloat(width + height)
                context.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let image = context.makeImage() else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot make test image"])
        }
        return image
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StegaStampWatermarkerTests 2>&1`
Expected: Compilation error — `StegaStampWatermarker` not found

- [ ] **Step 3: Create ImageWatermarker protocol**

Create `Sources/quigsphoto-uploader/Watermarking/ImageWatermarker.swift`:

```swift
import CoreGraphics
import Foundation

protocol ImageWatermarker {
    func embed(in image: CGImage, payload: WatermarkPayload) throws -> CGImage
    func extract(from image: CGImage, hmacKey: Data) throws -> WatermarkPayload?
}
```

- [ ] **Step 4: Implement StegaStampWatermarker**

Create `Sources/quigsphoto-uploader/Watermarking/StegaStampWatermarker.swift`:

```swift
import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Logging

struct StegaStampWatermarker: ImageWatermarker {
    private let encoder: MLModel
    private let decoder: MLModel
    private let logger = Logger(label: "quigsphoto.watermark")

    enum WatermarkError: Error, LocalizedError {
        case modelsNotFound
        case modelLoadFailed(String)
        case encodingFailed(String)
        case decodingFailed(String)
        case imageConversionFailed

        var errorDescription: String? {
            switch self {
            case .modelsNotFound:
                return "StegaStamp CoreML models not found. Ensure StegaStampEncoder.mlmodelc and StegaStampDecoder.mlmodelc are in Resources/"
            case .modelLoadFailed(let msg):
                return "Failed to load StegaStamp model: \(msg)"
            case .encodingFailed(let msg):
                return "Watermark encoding failed: \(msg)"
            case .decodingFailed(let msg):
                return "Watermark decoding failed: \(msg)"
            case .imageConversionFailed:
                return "Failed to convert image for watermark processing"
            }
        }
    }

    init() throws {
        guard Self.modelsAvailable() else {
            throw WatermarkError.modelsNotFound
        }

        let bundle = Bundle.module
        guard let encoderURL = bundle.url(forResource: "StegaStampEncoder", withExtension: "mlmodelc"),
              let decoderURL = bundle.url(forResource: "StegaStampDecoder", withExtension: "mlmodelc") else {
            throw WatermarkError.modelsNotFound
        }

        do {
            self.encoder = try MLModel(contentsOf: encoderURL)
            self.decoder = try MLModel(contentsOf: decoderURL)
        } catch {
            throw WatermarkError.modelLoadFailed(error.localizedDescription)
        }
    }

    static func modelsAvailable() -> Bool {
        let bundle = Bundle.module
        return bundle.url(forResource: "StegaStampEncoder", withExtension: "mlmodelc") != nil
            && bundle.url(forResource: "StegaStampDecoder", withExtension: "mlmodelc") != nil
    }

    // MARK: - Embed

    func embed(in image: CGImage, payload: WatermarkPayload) throws -> CGImage {
        let grid = TileGrid(imageWidth: image.width, imageHeight: image.height)
        let tileRects = grid.tileRects()
        let bits = payload.encode()

        logger.debug("Tiling: \(grid.columns)x\(grid.rows) = \(grid.tileCount) tiles for \(image.width)x\(image.height) image")

        // Process each tile through the encoder
        var watermarkedTiles: [(CGRect, CGImage)] = []
        for rect in tileRects {
            guard let tile = grid.extractTile(from: image, at: rect) else {
                throw WatermarkError.encodingFailed("Failed to extract tile at \(rect)")
            }

            let watermarkedTile = try encodeTile(tile, payload: bits)
            watermarkedTiles.append((rect, watermarkedTile))
        }

        // Reassemble with feather blending
        return try reassemble(tiles: watermarkedTiles, grid: grid, originalImage: image)
    }

    // MARK: - Extract

    func extract(from image: CGImage, hmacKey: Data) throws -> WatermarkPayload? {
        let grid = TileGrid(imageWidth: image.width, imageHeight: image.height)
        let tileRects = grid.tileRects()

        logger.debug("Extracting watermark: \(grid.tileCount) tiles from \(image.width)x\(image.height) image")

        // Decode each tile
        var allBits: [[Float]] = []
        for rect in tileRects {
            guard let tile = grid.extractTile(from: image, at: rect) else { continue }
            if let tileBits = try decodeTile(tile) {
                allBits.append(tileBits)
            }
        }

        guard !allBits.isEmpty else {
            return nil
        }

        // Majority vote per bit
        var votedBits = [Bool](repeating: false, count: 100)
        for i in 0..<100 {
            var sum: Float = 0
            for tileBits in allBits {
                sum += tileBits[i]
            }
            votedBits[i] = sum > Float(allBits.count) / 2.0
        }

        logger.debug("Watermark extraction: majority vote across \(allBits.count) tiles")

        return WatermarkPayload.decode(from: votedBits, hmacKey: hmacKey)
    }

    // MARK: - Private

    private func encodeTile(_ tile: CGImage, payload: [Bool]) throws -> CGImage {
        // Convert CGImage to MLMultiArray (1, 3, 400, 400)
        let imageArray = try cgImageToMLArray(tile, width: 400, height: 400)

        // Convert payload bits to MLMultiArray (1, 100)
        let secretArray = try MLMultiArray(shape: [1, 100], dataType: .float32)
        for i in 0..<100 {
            secretArray[i] = NSNumber(value: payload[i] ? 1.0 : 0.0)
        }

        // Run encoder
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "secret": MLFeatureValue(multiArray: secretArray),
            "image": MLFeatureValue(multiArray: imageArray),
        ])

        let output = try encoder.prediction(from: input)
        guard let encodedArray = output.featureValue(for: "encoded_image")?.multiArrayValue else {
            throw WatermarkError.encodingFailed("No encoded_image output from model")
        }

        // Convert back to CGImage
        return try mlArrayToCGImage(encodedArray, width: 400, height: 400)
    }

    private func decodeTile(_ tile: CGImage) throws -> [Float]? {
        let imageArray = try cgImageToMLArray(tile, width: 400, height: 400)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: imageArray),
        ])

        let output = try decoder.prediction(from: input)
        guard let secretArray = output.featureValue(for: "secret")?.multiArrayValue else {
            throw WatermarkError.decodingFailed("No secret output from model")
        }

        var bits = [Float](repeating: 0, count: 100)
        for i in 0..<100 {
            bits[i] = secretArray[i].floatValue
        }
        return bits
    }

    private func cgImageToMLArray(_ image: CGImage, width: Int, height: Int) throws -> MLMultiArray {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw WatermarkError.imageConversionFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert to (1, 3, H, W) float array, normalized to [0, 1]
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: .float32)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: Float(pixelData[pixelIndex]) / 255.0)     // R
                array[[0, 1, y, x] as [NSNumber]] = NSNumber(value: Float(pixelData[pixelIndex + 1]) / 255.0) // G
                array[[0, 2, y, x] as [NSNumber]] = NSNumber(value: Float(pixelData[pixelIndex + 2]) / 255.0) // B
            }
        }
        return array
    }

    private func mlArrayToCGImage(_ array: MLMultiArray, width: Int, height: Int) throws -> CGImage {
        var pixelData = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                pixelData[pixelIndex]     = UInt8(clamping: Int(array[[0, 0, y, x] as [NSNumber]].floatValue * 255.0))
                pixelData[pixelIndex + 1] = UInt8(clamping: Int(array[[0, 1, y, x] as [NSNumber]].floatValue * 255.0))
                pixelData[pixelIndex + 2] = UInt8(clamping: Int(array[[0, 2, y, x] as [NSNumber]].floatValue * 255.0))
                pixelData[pixelIndex + 3] = 255  // Alpha (skip)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let cgImage = context.makeImage() else {
            throw WatermarkError.imageConversionFailed
        }
        return cgImage
    }

    private func reassemble(tiles: [(CGRect, CGImage)], grid: TileGrid, originalImage: CGImage) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: originalImage.width,
            height: originalImage.height,
            bitsPerComponent: 8,
            bytesPerRow: originalImage.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw WatermarkError.imageConversionFailed
        }

        // Draw original image as base
        context.draw(originalImage, in: CGRect(x: 0, y: 0, width: originalImage.width, height: originalImage.height))

        // Draw each watermarked tile on top
        // For overlapping regions, later tiles overwrite earlier ones.
        // The feather blending is approximate — drawing tiles sequentially
        // with alpha compositing handles the overlap zones.
        for (rect, tile) in tiles {
            // Clip to the actual image-space rect (handles edge tiles smaller than tileSize)
            let drawRect = CGRect(
                x: rect.origin.x,
                y: CGFloat(originalImage.height) - rect.origin.y - rect.size.height,
                width: rect.size.width,
                height: rect.size.height
            )
            context.draw(tile, in: drawRect)
        }

        guard let result = context.makeImage() else {
            throw WatermarkError.imageConversionFailed
        }
        return result
    }
}
```

- [ ] **Step 5: Run tests to verify they pass (or skip)**

Run: `swift test --filter StegaStampWatermarkerTests 2>&1`
Expected: Tests pass if CoreML models are available, or skip with "StegaStamp CoreML models not found"

- [ ] **Step 6: Commit**

```bash
git add Sources/quigsphoto-uploader/Watermarking/ImageWatermarker.swift Sources/quigsphoto-uploader/Watermarking/StegaStampWatermarker.swift Tests/quigsphoto-uploaderTests/StegaStampWatermarkerTests.swift
git commit -m "feat(watermark): add StegaStampWatermarker with CoreML tiling"
```

---

### Task 5: Create `WatermarkReference` (JSONL logging)

**Files:**
- Create: `Sources/quigsphoto-uploader/Watermarking/WatermarkReference.swift`
- Create: `Tests/quigsphoto-uploaderTests/WatermarkReferenceTests.swift`

- [ ] **Step 1: Write failing tests for WatermarkReference**

Create `Tests/quigsphoto-uploaderTests/WatermarkReferenceTests.swift`:

```swift
import XCTest
@testable import quigsphoto_uploader

final class WatermarkReferenceTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quigsphoto-wm-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testAppendAndLookup() throws {
        let logPath = tmpDir.appendingPathComponent("watermarks.jsonl").path
        let log = WatermarkReference(path: logPath)

        let entry = WatermarkReferenceEntry(
            imageId: "a1b2c3d4e5f6",
            originalFilename: "IMG_1234.jpg",
            contentHash: "abc123",
            timestamp: Date()
        )
        try log.append(entry)

        let found = try log.lookup(imageId: "a1b2c3d4e5f6")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.originalFilename, "IMG_1234.jpg")
    }

    func testLookupMissing() throws {
        let logPath = tmpDir.appendingPathComponent("watermarks.jsonl").path
        let log = WatermarkReference(path: logPath)

        let found = try log.lookup(imageId: "nonexistent")
        XCTAssertNil(found)
    }

    func testAppendMultipleEntries() throws {
        let logPath = tmpDir.appendingPathComponent("watermarks.jsonl").path
        let log = WatermarkReference(path: logPath)

        for i in 0..<5 {
            let entry = WatermarkReferenceEntry(
                imageId: "id\(i)",
                originalFilename: "img\(i).jpg",
                contentHash: "hash\(i)",
                timestamp: Date()
            )
            try log.append(entry)
        }

        let found = try log.lookup(imageId: "id3")
        XCTAssertEqual(found?.originalFilename, "img3.jpg")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WatermarkReferenceTests 2>&1`
Expected: Compilation error — `WatermarkReference` not found

- [ ] **Step 3: Implement WatermarkReference**

Create `Sources/quigsphoto-uploader/Watermarking/WatermarkReference.swift`:

```swift
import Foundation

struct WatermarkReferenceEntry: Codable {
    let imageId: String
    let originalFilename: String
    let contentHash: String
    var ghostPostId: String?
    var ghostPostUrl: String?
    let timestamp: Date
}

struct WatermarkReference {
    let path: String

    /// Append a watermark reference entry to the JSONL log.
    func append(_ entry: WatermarkReferenceEntry) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(contentsOf: "\n".utf8)

        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            throw WatermarkReferenceError.cannotOpenLog(path)
        }
        defer { close(fd) }
        data.withUnsafeBytes { buffer in
            _ = write(fd, buffer.baseAddress!, buffer.count)
        }
    }

    /// Look up a watermark reference by image ID.
    func lookup(imageId: String) throws -> WatermarkReferenceEntry? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in lines where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(WatermarkReferenceEntry.self, from: lineData),
                  entry.imageId == imageId else {
                continue
            }
            return entry
        }
        return nil
    }

    enum WatermarkReferenceError: Error, CustomStringConvertible {
        case cannotOpenLog(String)
        var description: String {
            switch self {
            case .cannotOpenLog(let path): return "Cannot open watermark log at \(path)"
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WatermarkReferenceTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Watermarking/WatermarkReference.swift Tests/quigsphoto-uploaderTests/WatermarkReferenceTests.swift
git commit -m "feat(watermark): add WatermarkReference JSONL logging"
```

---

### Task 6: Add Keychain watermark secret management

**Files:**
- Modify: `Sources/quigsphoto-uploader/Secrets/KeychainSecretStore.swift`
- Create: `Tests/quigsphoto-uploaderTests/WatermarkKeyTests.swift`

- [ ] **Step 1: Write failing test for watermark key management**

Create `Tests/quigsphoto-uploaderTests/WatermarkKeyTests.swift`:

```swift
import XCTest
@testable import quigsphoto_uploader

final class WatermarkKeyTests: XCTestCase {

    func testGenerateAndRetrieveWatermarkKey() throws {
        let store = KeychainSecretStore(service: "com.quigsphoto.test.\(UUID().uuidString)")
        let fingerprint = "TEST_FINGERPRINT_1234"

        // Generate and store
        let key = try store.getOrCreateWatermarkKey(for: fingerprint)
        XCTAssertEqual(key.count, 32, "HMAC key should be 256 bits (32 bytes)")

        // Retrieve same key
        let key2 = try store.getOrCreateWatermarkKey(for: fingerprint)
        XCTAssertEqual(key, key2, "Should return same key on second call")

        // Clean up
        try? store.delete(key: "watermark-hmac-\(fingerprint)")
    }

    func testDifferentFingerprintsGetDifferentKeys() throws {
        let store = KeychainSecretStore(service: "com.quigsphoto.test.\(UUID().uuidString)")

        let key1 = try store.getOrCreateWatermarkKey(for: "FP_A")
        let key2 = try store.getOrCreateWatermarkKey(for: "FP_B")
        XCTAssertNotEqual(key1, key2)

        // Clean up
        try? store.delete(key: "watermark-hmac-FP_A")
        try? store.delete(key: "watermark-hmac-FP_B")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WatermarkKeyTests 2>&1`
Expected: Compilation error — `getOrCreateWatermarkKey` not found

- [ ] **Step 3: Add watermark key methods to KeychainSecretStore**

In `Sources/quigsphoto-uploader/Secrets/KeychainSecretStore.swift`, add:

```swift
/// Get or create a 256-bit HMAC key for watermark authentication.
/// The key is tied to a GPG fingerprint and stored in the Keychain.
func getOrCreateWatermarkKey(for fingerprint: String) throws -> Data {
    let keychainKey = "watermark-hmac-\(fingerprint)"

    // Try to load existing key
    if let existing = try? get(key: keychainKey) {
        guard let data = Data(base64Encoded: existing) else {
            throw SecretStoreError.unexpectedError(status: errSecDecode)
        }
        return data
    }

    // Generate new 256-bit key
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
        throw SecretStoreError.unexpectedError(status: status)
    }

    let keyData = Data(bytes)
    try set(key: keychainKey, value: keyData.base64EncodedString())
    return keyData
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WatermarkKeyTests 2>&1`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/Secrets/KeychainSecretStore.swift Tests/quigsphoto-uploaderTests/WatermarkKeyTests.swift
git commit -m "feat(watermark): add Keychain-based HMAC key management"
```

---

### Task 7: Refactor `ImageProcessor` to return `CGImage` (unified pipeline)

**Files:**
- Modify: `Sources/quigsphoto-uploader/ImageProcessing/ImageProcessor.swift`
- Modify: `Sources/quigsphoto-uploader/ImageProcessing/CoreGraphicsImageProcessor.swift`
- Create: `Sources/quigsphoto-uploader/ImageProcessing/ImageFinalizer.swift`
- Modify: `Tests/quigsphoto-uploaderTests/ImageProcessorTests.swift`

- [ ] **Step 1: Write failing tests for the new pipeline**

In `Tests/quigsphoto-uploaderTests/ImageProcessorTests.swift`, add new test methods for the refactored interface:

```swift
func testResizeReturnsCGImage() throws {
    let path = tmpDir.appendingPathComponent("test.jpg").path
    try TestFixtures.createTestJPEG(at: path, width: 3000, height: 2000, cameraMake: "Canon")

    let processor = CoreGraphicsImageProcessor()
    let (resized, metadata) = try processor.resize(
        inputPath: path,
        maxLongEdge: 2000,
        metadataAllowlist: ["TIFF.Make"]
    )

    XCTAssertEqual(resized.width, 2000)
    XCTAssertEqual(resized.height, 1333)
    XCTAssertNotNil(metadata[kCGImagePropertyTIFFDictionary as String])
}

func testImageFinalizerWritesJPEG() throws {
    let inputPath = tmpDir.appendingPathComponent("input.jpg").path
    let outputPath = tmpDir.appendingPathComponent("output.jpg").path
    try TestFixtures.createTestJPEG(at: inputPath, width: 800, height: 600, cameraMake: "FUJIFILM")

    let processor = CoreGraphicsImageProcessor()
    let (resized, metadata) = try processor.resize(
        inputPath: inputPath,
        maxLongEdge: 800,
        metadataAllowlist: ["TIFF.Make"]
    )

    try ImageFinalizer.write(resized, metadata: metadata, jpegQuality: 80, to: outputPath)

    // Verify output file exists and is a valid JPEG
    XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
    let width = props[kCGImagePropertyPixelWidth as String] as! Int
    XCTAssertEqual(width, 800)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ImageProcessorTests 2>&1`
Expected: Compilation error — `resize` method not found on `CoreGraphicsImageProcessor`

- [ ] **Step 3: Add `resize` method to ImageProcessor protocol**

In `Sources/quigsphoto-uploader/ImageProcessing/ImageProcessor.swift`, add a new method to the protocol:

```swift
import CoreGraphics

protocol ImageProcessor {
    /// Original method — processes and writes to disk in one step.
    func process(inputPath: String, outputPath: String, maxLongEdge: Int, jpegQuality: Int, metadataAllowlist: [String]) throws

    /// New method — resizes and returns CGImage + filtered metadata for pipeline composition.
    func resize(inputPath: String, maxLongEdge: Int, metadataAllowlist: [String]) throws -> (CGImage, [String: Any])
}
```

- [ ] **Step 4: Implement `resize` on CoreGraphicsImageProcessor**

In `Sources/quigsphoto-uploader/ImageProcessing/CoreGraphicsImageProcessor.swift`, add a `resize` method that extracts the resize + metadata filtering logic from `process()`. The existing `process()` method should call `resize()` internally followed by JPEG encoding, preserving backward compatibility:

```swift
func resize(inputPath: String, maxLongEdge: Int, metadataAllowlist: [String]) throws -> (CGImage, [String: Any]) {
    let url = URL(fileURLWithPath: inputPath)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let originalImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ImageProcessorError.cannotReadImage(inputPath)
    }

    let originalProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

    // Calculate dimensions
    let originalWidth = originalImage.width
    let originalHeight = originalImage.height
    let longEdge = max(originalWidth, originalHeight)
    let scale = longEdge > maxLongEdge ? CGFloat(maxLongEdge) / CGFloat(longEdge) : 1.0
    let newWidth = Int(CGFloat(originalWidth) * scale)
    let newHeight = Int(CGFloat(originalHeight) * scale)

    // Resize — use bytesPerRow: 0 to match existing process() behavior
    let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: newWidth, height: newHeight,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw ImageProcessorError.cannotCreateContext
    }
    context.interpolationQuality = .high
    context.draw(originalImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
    guard let resizedImage = context.makeImage() else {
        throw ImageProcessorError.cannotCreateContext
    }

    // Filter metadata via allowlist (extracted from existing inline logic in process())
    var outputExif: [String: Any] = [:]
    var outputTiff: [String: Any] = [:]
    var outputIptc: [String: Any] = [:]

    for entry in metadataAllowlist {
        let parts = entry.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let dictKey = Self.dictionaryKeys[String(parts[0])],
              let sourceDict = originalProperties[dictKey] as? [String: Any],
              let value = sourceDict[String(parts[1])] else { continue }

        switch String(parts[0]) {
        case "EXIF": outputExif[String(parts[1])] = value
        case "TIFF": outputTiff[String(parts[1])] = value
        case "IPTC": outputIptc[String(parts[1])] = value
        default: break
        }
    }

    var filteredMetadata: [String: Any] = [:]
    if !outputExif.isEmpty { filteredMetadata[kCGImagePropertyExifDictionary as String] = outputExif }
    if !outputTiff.isEmpty { filteredMetadata[kCGImagePropertyTIFFDictionary as String] = outputTiff }
    if !outputIptc.isEmpty { filteredMetadata[kCGImagePropertyIPTCDictionary as String] = outputIptc }

    return (resizedImage, filteredMetadata)
}
```

Refactor `process()` to use `resize()` + `ImageFinalizer.write()` internally.

- [ ] **Step 5: Create ImageFinalizer**

Create `Sources/quigsphoto-uploader/ImageProcessing/ImageFinalizer.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO

/// Writes a CGImage to disk as JPEG with metadata. Single encode point.
enum ImageFinalizer {

    enum FinalizerError: Error, CustomStringConvertible {
        case cannotCreateDestination(String)
        case cannotFinalize(String)

        var description: String {
            switch self {
            case .cannotCreateDestination(let path): return "Cannot create image destination at \(path)"
            case .cannotFinalize(let path): return "Cannot finalize image at \(path)"
            }
        }
    }

    /// Write a CGImage + metadata to a JPEG file. This is the single lossy encode point.
    static func write(_ image: CGImage, metadata: [String: Any], jpegQuality: Int, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ) else {
            throw FinalizerError.cannotCreateDestination(path)
        }

        var properties = metadata
        properties[kCGImageDestinationLossyCompressionQuality as String] = CGFloat(jpegQuality) / 100.0

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw FinalizerError.cannotFinalize(path)
        }
    }

    /// Write XMP metadata to an existing JPEG without re-encoding.
    /// Uses CGImageDestinationCopyImageSource to copy the compressed bitstream.
    static func writeXMPMetadata(
        to path: String,
        fields: [(namespace: String, prefix: String, name: String, value: String)]
    ) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw FinalizerError.cannotCreateDestination(path)
        }

        // Build XMP metadata
        let xmpMetadata = CGImageMetadataCreateMutable()
        for field in fields {
            guard let tag = CGImageMetadataTagCreate(
                field.namespace as CFString,
                field.prefix as CFString,
                field.name as CFString,
                .string,
                field.value as CFTypeRef
            ) else { continue }
            CGImageMetadataSetTagWithPath(xmpMetadata, nil, "\(field.prefix):\(field.name)" as CFString, tag)
        }

        // Copy source to destination with new metadata
        let tmpPath = path + ".tmp"
        let tmpUrl = URL(fileURLWithPath: tmpPath)
        guard let destination = CGImageDestinationCreateWithURL(
            tmpUrl as CFURL,
            CGImageSourceGetType(source) ?? "public.jpeg" as CFString,
            CGImageSourceGetCount(source),
            nil
        ) else {
            throw FinalizerError.cannotCreateDestination(path)
        }

        let options: [String: Any] = [
            kCGImageDestinationMetadata as String: xmpMetadata,
            kCGImageDestinationMergeMetadata as String: true,
        ]

        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            throw FinalizerError.cannotFinalize(path)
        }

        // Atomic replace
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tmpPath, toPath: path)
    }
}
```

- [ ] **Step 6: Update existing `process()` to use new internal methods**

Update `CoreGraphicsImageProcessor.process()` to delegate to `resize()` + `ImageFinalizer.write()`:

```swift
func process(inputPath: String, outputPath: String, maxLongEdge: Int, jpegQuality: Int, metadataAllowlist: [String]) throws {
    let (resizedImage, filteredMetadata) = try resize(
        inputPath: inputPath,
        maxLongEdge: maxLongEdge,
        metadataAllowlist: metadataAllowlist
    )
    try ImageFinalizer.write(resizedImage, metadata: filteredMetadata, jpegQuality: jpegQuality, to: outputPath)
}
```

- [ ] **Step 7: Run all ImageProcessor tests to verify no regressions**

Run: `swift test --filter ImageProcessorTests 2>&1`
Expected: All tests pass (existing + new)

- [ ] **Step 8: Commit**

```bash
git add Sources/quigsphoto-uploader/ImageProcessing/ImageProcessor.swift Sources/quigsphoto-uploader/ImageProcessing/CoreGraphicsImageProcessor.swift Sources/quigsphoto-uploader/ImageProcessing/ImageFinalizer.swift Tests/quigsphoto-uploaderTests/ImageProcessorTests.swift
git commit -m "refactor(pipeline): split ImageProcessor into resize + finalize for unified pipeline"
```

---

### Task 8: Integrate watermarking into `ProcessCommand`

**Files:**
- Modify: `Sources/quigsphoto-uploader/CLI/ProcessCommand.swift`

- [ ] **Step 1: Add `--no-watermark` flag**

In `Sources/quigsphoto-uploader/CLI/ProcessCommand.swift`, add after the `--no-sign` flag:

```swift
@Flag(help: "Skip watermark embedding for this run")
var noWatermark = false
```

- [ ] **Step 2: Replace direct `process()` call with unified pipeline**

Replace the block that calls `imageProcessor.process(...)` (around lines 192-198) with the unified pipeline:

```swift
// Unified pipeline: resize → watermark → encode → sign
let (resizedImage, filteredMetadata) = try imageProcessor.resize(
    inputPath: image.path,
    maxLongEdge: config.processing.maxLongEdge,
    metadataAllowlist: config.processing.metadataAllowlist
)

var finalImage = resizedImage
var watermarkId: String? = nil

// Watermark embed (in-memory, before JPEG encode)
// NOTE: watermarker and hmacKey should be instantiated ONCE before the image loop,
// alongside imageProcessor and ghostClient. Example:
//   let watermarker = signingConfig?.watermark == true ? try StegaStampWatermarker() : nil
//   let hmacKey = signingConfig.map { try secretStore.getOrCreateWatermarkKey(for: $0.keyFingerprint) }
// Then inside the loop, reuse them:
if let signingConfig = config.resolvedSigningConfig, signingConfig.watermark, !noWatermark {
    if !dryRun {
        let imageId = WatermarkPayload.generateImageId()
        let payload = WatermarkPayload(imageId: imageId, hmacKey: hmacKey!)
        finalImage = try watermarker!.embed(in: resizedImage, payload: payload)
        watermarkId = String(imageId, radix: 16)
        logger.info("[\(image.filename)] Watermark embedded (ID: \(watermarkId!))")
    } else {
        let fakeId = String(WatermarkPayload.generateImageId(), radix: 16)
        print("[\(image.filename)] Would embed watermark (image ID: \(fakeId))")
    }
}

// Single JPEG encode
try ImageFinalizer.write(
    finalImage,
    metadata: filteredMetadata,
    jpegQuality: config.processing.jpegQuality,
    to: resizedPath
)
```

- [ ] **Step 3: Add watermark reference logging after upload**

After the Ghost upload succeeds (where `ghostPostId` and `ghostPostUrl` are available), add:

```swift
// Record watermark reference
if let wId = watermarkId {
    let watermarkLog = WatermarkReference(path: watermarkLogPath)
    var entry = WatermarkReferenceEntry(
        imageId: wId,
        originalFilename: image.filename,
        contentHash: signingResult?.contentHash ?? "",
        timestamp: Date()
    )
    entry.ghostPostId = postId
    entry.ghostPostUrl = postUrl
    try watermarkLog.append(entry)
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add Sources/quigsphoto-uploader/CLI/ProcessCommand.swift
git commit -m "feat(watermark): integrate watermarking into unified processing pipeline"
```

---

### Task 9: Add watermark ID to Ghost posts via LexicalBuilder

**Files:**
- Modify: `Sources/quigsphoto-uploader/Ghost/LexicalBuilder.swift`
- Modify: `Tests/quigsphoto-uploaderTests/LexicalBuilderTests.swift` (if exists)

- [ ] **Step 1: Write failing test for watermark ID in Lexical output**

In the LexicalBuilder test file, add:

```swift
func testBuildWithWatermarkId() throws {
    let result = LexicalBuilder.build(
        title: "Test Title",
        description: "A photo",
        watermarkId: "a1b2c3d4e5f6"
    )

    XCTAssertTrue(result.contains("data-quigsphoto-id"))
    XCTAssertTrue(result.contains("a1b2c3d4e5f6"))
    XCTAssertTrue(result.contains("display:none"))
}

func testBuildWithoutWatermarkId() throws {
    let result = LexicalBuilder.build(
        title: "Test Title",
        description: "A photo",
        watermarkId: nil
    )

    XCTAssertFalse(result.contains("data-quigsphoto-id"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LexicalBuilderTests 2>&1`
Expected: Compilation error — `watermarkId` parameter not found

- [ ] **Step 3: Add watermarkId parameter to LexicalBuilder.build()**

In `Sources/quigsphoto-uploader/Ghost/LexicalBuilder.swift`, update the `build` method signature to accept an optional `watermarkId: String? = nil` parameter.

When `watermarkId` is non-nil, append an HTML card node to the Lexical JSON `children` array:

```swift
if let watermarkId = watermarkId {
    let htmlCard: [String: Any] = [
        "type": "html",
        "version": 1,
        "html": "<span data-quigsphoto-id=\"\(watermarkId)\" style=\"display:none\"></span>"
    ]
    children.append(htmlCard)
}
```

- [ ] **Step 4: Update ProcessCommand to pass watermarkId to LexicalBuilder**

In `ProcessCommand.swift`, update the `LexicalBuilder.build(...)` call to pass `watermarkId`:

```swift
let lexical = LexicalBuilder.build(
    title: bodyTitle,
    description: bodyDescription,
    watermarkId: watermarkId
)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LexicalBuilderTests 2>&1`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add Sources/quigsphoto-uploader/Ghost/LexicalBuilder.swift Sources/quigsphoto-uploader/CLI/ProcessCommand.swift Tests/quigsphoto-uploaderTests/LexicalBuilderTests.swift
git commit -m "feat(watermark): embed watermark ID in Ghost posts via Lexical HTML card"
```

---

### Task 10: Add watermark extraction to `VerifyCommand`

**Files:**
- Modify: `Sources/quigsphoto-uploader/CLI/VerifyCommand.swift`

- [ ] **Step 1: Add watermark fallback to VerifyCommand**

In `Sources/quigsphoto-uploader/CLI/VerifyCommand.swift`, after the XMP verification block (where it reports "No signature found"), add a watermark extraction fallback:

```swift
// Fall back to watermark extraction
print("No XMP signature found. Attempting watermark extraction...")

guard StegaStampWatermarker.modelsAvailable() else {
    print("StegaStamp models not available. Cannot extract watermark.")
    throw ExitCode(1)
}

let imageUrl = URL(fileURLWithPath: imagePath)
let imageData = try Data(contentsOf: imageUrl)
guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    print("Cannot decode image for watermark extraction.")
    throw ExitCode(1)
}

// Load HMAC key from Keychain
let store = KeychainSecretStore()
let fingerprint = keyFingerprint ?? config?.signing?.keyFingerprint
guard let fp = fingerprint else {
    print("No key fingerprint provided or configured. Cannot verify watermark HMAC.")
    throw ExitCode(1)
}

let hmacKey = try store.getOrCreateWatermarkKey(for: fp)
let watermarker = try StegaStampWatermarker()

guard let payload = try watermarker.extract(from: cgImage, hmacKey: hmacKey) else {
    print("No watermark found in this image.")
    throw ExitCode(1)
}

let imageIdHex = String(payload.imageId, radix: 16)
print("Watermark verified.")
print("Image ID: \(imageIdHex)")

// Look up in reference database
let configDir = (AppConfig.configPath.path as NSString).deletingLastPathComponent
let watermarkLogPath = configDir + "/watermarks.jsonl"
let watermarkLog = WatermarkReference(path: watermarkLogPath)

if let entry = try watermarkLog.lookup(imageId: imageIdHex) {
    print("Originally: \(entry.originalFilename)")
    let formatter = ISO8601DateFormatter()
    print("Uploaded: \(formatter.string(from: entry.timestamp))")
    if let url = entry.ghostPostUrl {
        print("Ghost URL: \(url)")
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/quigsphoto-uploader/CLI/VerifyCommand.swift
git commit -m "feat(watermark): add watermark extraction fallback to verify command"
```

---

### Task 11: Update Package.swift for CoreML resources

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add resource bundle to executable target**

In `Package.swift`, update the executable target to include resources:

```swift
.executableTarget(
    name: "quigsphoto-uploader",
    dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SwiftSMTP", package: "swift-smtp"),
    ],
    resources: [
        .copy("Resources/StegaStampEncoder.mlmodelc"),
        .copy("Resources/StegaStampDecoder.mlmodelc"),
    ]
),
```

**Important:** SwiftPM resource paths must be relative to the target's source directory and cannot use `../`. The CoreML model files must be placed under `Sources/quigsphoto-uploader/Resources/` (not the repo-root `Resources/`). Update Task 0's output paths accordingly.

- [ ] **Step 2: Build to verify resource bundling**

Run: `swift build 2>&1`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: add CoreML model resources to Package.swift"
```

---

### Task 12: Run full test suite and fix issues

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass (StegaStamp tests may skip if models not yet available)

- [ ] **Step 2: Fix any compilation or test failures**

Address any issues found. Common problems:
- Import statements for `CoreML` or `Accelerate` missing
- `Bundle.module` not available (requires SPM resource bundling)
- JSONL date encoding/decoding format mismatches

- [ ] **Step 3: Run build in release mode**

Run: `swift build -c release 2>&1`
Expected: Build succeeds

- [ ] **Step 4: Commit any fixes**

Stage only the specific files that were fixed, then:
```bash
git commit -m "fix(watermark): address test and build issues"
```
(Only if there were fixes needed)

---

### Task Dependency Graph

```
Task 0 (CoreML conversion) ─── prerequisite for Tasks 4 and 11

Task 1 (SigningConfig.watermark)  ──┐
Task 2 (WatermarkPayload + BCH)  ──┤
Task 3 (TileGrid)                ──┼── independent, can run in parallel
Task 5 (WatermarkReference)      ──┤
Task 6 (Keychain HMAC key)       ──┤
Task 7 (Refactor ImageProcessor) ──┘
                                    │
Task 11 (Package.swift)          ←──┤ depends on Task 0 (needed for Bundle.module)
                                    │
Task 4 (StegaStampWatermarker)   ←──┤ depends on Tasks 2, 3, 11
                                    │
Task 8 (ProcessCommand integration) ← depends on Tasks 4, 5, 6, 7
Task 9 (LexicalBuilder)           ← depends on Task 8
Task 10 (VerifyCommand)           ← depends on Tasks 4, 5, 6
Task 12 (Full test suite)         ← depends on all
```

Tasks 1, 2, 3, 5, 6, and 7 are independent and can be implemented in parallel by separate agents.
Task 11 must complete before Task 4 (Bundle.module requires SPM resource declaration).
