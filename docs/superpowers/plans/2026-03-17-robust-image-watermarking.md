# Robust Image Watermarking Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PixelSeal-based pixel watermarking that embeds authenticated 256-bit identifiers surviving metadata stripping, format conversion, resize, and light edits — as a fallback to XMP GPG signatures.

**Architecture:** A separate C++ binary (`piqley-watermark`) built with LibTorch runs the PixelSeal TorchScript model. The main Swift tool shells out to it (same pattern as GPG). 256-bit payload: 2-bit version + 46-bit image ID + 128-bit HMAC + 80-bit BCH ECC. PNG used as lossless interchange between Swift and the watermark binary, ensuring a single lossy JPEG encode.

**Tech Stack:**
- `piqley-watermark`: C++17, LibTorch (TorchScript runtime), stb_image (vendored)
- `piqley`: Swift 6.2, CryptoKit (HMAC-SHA256), CoreGraphics/ImageIO (image pipeline), macOS Keychain (HMAC secret storage)

---

### Task 0: Build `piqley-watermark` C++ binary

This is the new standalone project. It wraps PixelSeal's TorchScript model in a CLI that the Swift tool invokes as a subprocess.

**Files:**
- Create: `piqley-watermark/CMakeLists.txt`
- Create: `piqley-watermark/src/main.cpp`
- Create: `piqley-watermark/vendor/stb_image.h` (vendored, public domain)
- Create: `piqley-watermark/vendor/stb_image_write.h` (vendored, public domain)
- Download: `piqley-watermark/model/pixelseal.jit` (218MB TorchScript model)

- [ ] **Step 1: Create project structure**

```bash
mkdir -p piqley-watermark/src piqley-watermark/vendor piqley-watermark/model
```

- [ ] **Step 2: Download PixelSeal model**

```bash
curl -L -o piqley-watermark/model/pixelseal.jit \
  "https://dl.fbaipublicfiles.com/videoseal/y_256b_img.jit"
```

Verify: file should be ~218MB.

- [ ] **Step 3: Vendor stb_image headers**

Download from the stb repository (public domain, single-header):

```bash
curl -L -o piqley-watermark/vendor/stb_image.h \
  "https://raw.githubusercontent.com/nothings/stb/master/stb_image.h"
curl -L -o piqley-watermark/vendor/stb_image_write.h \
  "https://raw.githubusercontent.com/nothings/stb/master/stb_image_write.h"
```

- [ ] **Step 4: Write CMakeLists.txt**

Create `piqley-watermark/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.18)
project(piqley-watermark LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Torch REQUIRED)

add_executable(piqley-watermark src/main.cpp)
target_include_directories(piqley-watermark PRIVATE vendor)
target_link_libraries(piqley-watermark "${TORCH_LIBRARIES}")

# Install binary and model
install(TARGETS piqley-watermark DESTINATION bin)
install(FILES model/pixelseal.jit DESTINATION share/piqley-watermark)
```

- [ ] **Step 5: Write main.cpp**

Create `piqley-watermark/src/main.cpp`:

```cpp
#include <torch/script.h>
#include <torch/torch.h>
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <filesystem>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

namespace fs = std::filesystem;

// Find the model file: check next to binary, then in share dir
std::string find_model() {
    // 1. Next to the binary
    auto exe_dir = fs::canonical("/proc/self/exe").parent_path();
    auto local_model = exe_dir / "pixelseal.jit";
    if (fs::exists(local_model)) return local_model.string();

    // 2. In ../share/piqley-watermark/
    auto share_model = exe_dir.parent_path() / "share" / "piqley-watermark" / "pixelseal.jit";
    if (fs::exists(share_model)) return share_model.string();

    // 3. QUIGSPHOTO_WATERMARK_MODEL env var
    if (auto env = std::getenv("QUIGSPHOTO_WATERMARK_MODEL")) {
        if (fs::exists(env)) return env;
    }

    // 4. Homebrew Cellar path (macOS)
    auto brew_model = fs::path("/usr/local/share/piqley-watermark/pixelseal.jit");
    if (fs::exists(brew_model)) return brew_model.string();
    auto brew_arm = fs::path("/opt/homebrew/share/piqley-watermark/pixelseal.jit");
    if (fs::exists(brew_arm)) return brew_arm.string();

    return "";
}

torch::Tensor load_image(const std::string& path) {
    int w, h, c;
    unsigned char* data = stbi_load(path.c_str(), &w, &h, &c, 3);
    if (!data) {
        throw std::runtime_error("Cannot load image: " + path);
    }

    // Convert to float tensor [1, 3, H, W] in [0, 1]
    auto tensor = torch::from_blob(data, {h, w, 3}, torch::kUInt8).clone();
    stbi_image_free(data);

    tensor = tensor.to(torch::kFloat32).div(255.0);
    tensor = tensor.permute({2, 0, 1}).unsqueeze(0);  // [1, 3, H, W]
    return tensor;
}

void save_image(const torch::Tensor& tensor, const std::string& path) {
    // tensor is [1, 3, H, W] in [0, 1]
    auto img = tensor.squeeze(0).permute({1, 2, 0});  // [H, W, 3]
    img = img.mul(255.0).clamp(0, 255).to(torch::kUInt8).contiguous();

    int h = img.size(0);
    int w = img.size(1);

    std::string ext = fs::path(path).extension().string();
    if (ext == ".png") {
        stbi_write_png(path.c_str(), w, h, 3, img.data_ptr(), w * 3);
    } else if (ext == ".jpg" || ext == ".jpeg") {
        stbi_write_jpg(path.c_str(), w, h, 3, img.data_ptr(), 90);
    } else {
        stbi_write_png(path.c_str(), w, h, 3, img.data_ptr(), w * 3);
    }
}

torch::Tensor hex_to_message(const std::string& hex) {
    // Convert 64-char hex string to 256-bit float tensor
    if (hex.size() != 64) {
        throw std::runtime_error("Message must be 64 hex characters (256 bits), got " + std::to_string(hex.size()));
    }

    auto msg = torch::zeros({1, 256}, torch::kFloat32);
    for (int i = 0; i < 64; i++) {
        unsigned int byte;
        sscanf(hex.c_str() + i * 1, "%1x", &byte);
        // Actually, parse hex nibble by nibble
    }

    // Parse hex to bits properly
    for (size_t i = 0; i < hex.size(); i++) {
        char c = hex[i];
        int nibble = (c >= '0' && c <= '9') ? c - '0' :
                     (c >= 'a' && c <= 'f') ? c - 'a' + 10 :
                     (c >= 'A' && c <= 'F') ? c - 'A' + 10 : 0;
        for (int b = 3; b >= 0; b--) {
            int bit_idx = i * 4 + (3 - b);
            if (bit_idx < 256) {
                msg[0][bit_idx] = ((nibble >> b) & 1) ? 1.0f : 0.0f;
            }
        }
    }
    return msg;
}

std::string bits_to_json(const torch::Tensor& detection) {
    // detection is [1, 257] — first value is confidence, rest are 256 bit confidences
    auto d = detection.squeeze(0);
    float confidence = d[0].item<float>();

    std::string json = "{\"confidence\":";
    json += std::to_string(confidence);
    json += ",\"modelVersion\":\"pixelseal-1.0\"";
    json += ",\"bits\":[";

    for (int i = 1; i <= 256; i++) {
        if (i > 1) json += ",";
        json += std::to_string(d[i].item<float>());
    }
    json += "]}";
    return json;
}

void print_usage() {
    std::cerr << "Usage:" << std::endl;
    std::cerr << "  piqley-watermark embed --image <input> --message <64-hex-chars> --output <output>" << std::endl;
    std::cerr << "  piqley-watermark detect --image <input>" << std::endl;
    std::cerr << "  piqley-watermark version" << std::endl;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        print_usage();
        return 1;
    }

    std::string command = argv[1];

    if (command == "version") {
        std::cout << "piqley-watermark 1.0.0" << std::endl;
        std::cout << "Model: PixelSeal (Meta VideoSeal)" << std::endl;
        std::cout << "Payload: 256 bits" << std::endl;
        return 0;
    }

    // Parse args
    std::string image_path, message_hex, output_path;
    for (int i = 2; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--image" && i + 1 < argc) image_path = argv[++i];
        else if (arg == "--message" && i + 1 < argc) message_hex = argv[++i];
        else if (arg == "--output" && i + 1 < argc) output_path = argv[++i];
    }

    if (image_path.empty()) {
        std::cerr << "Error: --image is required" << std::endl;
        print_usage();
        return 1;
    }

    // Find and load model
    std::string model_path = find_model();
    if (model_path.empty()) {
        std::cerr << "Error: PixelSeal model not found. Set QUIGSPHOTO_WATERMARK_MODEL or install via Homebrew." << std::endl;
        return 1;
    }

    torch::jit::script::Module model;
    try {
        model = torch::jit::load(model_path);
        model.eval();
    } catch (const c10::Error& e) {
        std::cerr << "Error loading model: " << e.what() << std::endl;
        return 1;
    }

    torch::NoGradGuard no_grad;

    if (command == "embed") {
        if (message_hex.empty() || output_path.empty()) {
            std::cerr << "Error: embed requires --message and --output" << std::endl;
            return 1;
        }

        auto image = load_image(image_path);
        auto message = hex_to_message(message_hex);
        auto watermarked = model.get_method("embed")({image, message}).toTensor();
        watermarked = watermarked.clamp(0.0, 1.0);
        save_image(watermarked, output_path);

    } else if (command == "detect") {
        auto image = load_image(image_path);
        auto detection = model.get_method("detect")({image}).toTensor();
        std::cout << bits_to_json(detection) << std::endl;

    } else {
        std::cerr << "Unknown command: " << command << std::endl;
        print_usage();
        return 1;
    }

    return 0;
}
```

- [ ] **Step 6: Install LibTorch and build**

```bash
# On macOS with Homebrew:
brew install cmake

# Download LibTorch (CPU, macOS ARM)
cd /tmp
curl -L -o libtorch.zip "https://download.pytorch.org/libtorch/cpu/libtorch-macos-arm64-2.5.1.zip"
unzip libtorch.zip

# Build
cd piqley-watermark
mkdir build && cd build
cmake .. -DCMAKE_PREFIX_PATH=/tmp/libtorch
cmake --build . --config Release
```

- [ ] **Step 7: Test the binary**

```bash
# Create a test image
python3 -c "from PIL import Image; Image.new('RGB', (800, 600), 'blue').save('/tmp/test_input.png')"

# Test embed
./piqley-watermark embed \
  --image /tmp/test_input.png \
  --message "$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
  --output /tmp/test_watermarked.png

# Test detect
./piqley-watermark detect --image /tmp/test_watermarked.png

# Test version
./piqley-watermark version
```

Expected: embed produces a PNG, detect outputs JSON with 256 floats.

- [ ] **Step 8: Commit**

```bash
# Note: pixelseal.jit is 218MB — use Git LFS
cd piqley-watermark
git init
git lfs install
git lfs track "model/*.jit"
git add .gitattributes CMakeLists.txt src/ vendor/ model/
git commit -m "feat: initial piqley-watermark binary with PixelSeal"
```

---

### Task 1: Add `watermark` field to `SigningConfig`

**Files:**
- Modify: `Sources/piqley/Config/Config.swift`
- Modify: `Tests/piqleyTests/ConfigTests.swift`

- [ ] **Step 1: Write failing test for watermark config field**

In `Tests/piqleyTests/ConfigTests.swift`, add:

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
        "signing": { "keyFingerprint": "ABCD1234" }
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
        "signing": { "keyFingerprint": "ABCD1234", "watermark": false }
    }
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    XCTAssertEqual(config.signing?.watermark, false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1`

- [ ] **Step 3: Add watermark field to SigningConfig**

In `Sources/piqley/Config/Config.swift`, add to `SigningConfig`:
- Property: `var watermark: Bool`
- Static default: `static let defaultWatermark = true`
- Init parameter: `watermark: Bool = SigningConfig.defaultWatermark`
- Decoder: `watermark = try container.decodeIfPresent(Bool.self, forKey: .watermark) ?? SigningConfig.defaultWatermark`

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests 2>&1`

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Config/Config.swift Tests/piqleyTests/ConfigTests.swift
git commit -m "feat(watermark): add watermark field to SigningConfig"
```

---

### Task 2: Create `WatermarkPayload` (256-bit encode/decode with BCH ECC)

**Files:**
- Create: `Sources/piqley/Watermarking/WatermarkPayload.swift`
- Create: `Sources/piqley/Watermarking/BCH.swift`
- Create: `Tests/piqleyTests/WatermarkPayloadTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/WatermarkPayloadTests.swift`:

```swift
import XCTest
import CryptoKit
@testable import piqley

final class WatermarkPayloadTests: XCTestCase {

    func testEncodeDecodeRoundTrip() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let imageId: UInt64 = 0x1234_5678_9ABC
        let payload = WatermarkPayload(imageId: imageId, hmacKey: hmacKey)

        let bits = payload.encode()
        XCTAssertEqual(bits.count, 256)

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
        XCTAssertNil(recovered)
    }

    func testCorrectsBitErrors() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = WatermarkPayload(imageId: 0xABCD_EF01_2345, hmacKey: hmacKey)
        var bits = payload.encode()

        // Flip 6 bits (well within BCH correction of ~15)
        for i in [5, 42, 77, 130, 200, 250] { bits[i].toggle() }

        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.imageId, 0xABCD_EF01_2345)
    }

    func testFailsBeyondCorrectionCapacity() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = WatermarkPayload(imageId: 42, hmacKey: hmacKey)
        var bits = payload.encode()

        // Flip 20 bits (beyond BCH correction of ~15)
        for i in stride(from: 0, to: 250, by: 12) { bits[i].toggle() }

        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNil(recovered)
    }

    func testGenerateImageId() throws {
        let id1 = WatermarkPayload.generateImageId()
        let id2 = WatermarkPayload.generateImageId()
        XCTAssertNotEqual(id1, id2)
        XCTAssertTrue(id1 < (1 << 46))
        XCTAssertTrue(id2 < (1 << 46))
    }

    func testHmacIs128Bits() throws {
        let hmacKey = Data(repeating: 0xAB, count: 32)
        let payload = WatermarkPayload(imageId: 1, hmacKey: hmacKey)
        XCTAssertEqual(payload.hmac.count, 16) // 128 bits = 16 bytes
    }

    func testHexRoundTrip() throws {
        let hmacKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let payload = WatermarkPayload(imageId: 0xDEAD_BEEF, hmacKey: hmacKey)
        let hex = payload.encodeHex()
        XCTAssertEqual(hex.count, 64) // 256 bits = 64 hex chars

        let bits = WatermarkPayload.hexToBits(hex)
        XCTAssertEqual(bits.count, 256)

        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.imageId, 0xDEAD_BEEF)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WatermarkPayloadTests 2>&1`

- [ ] **Step 3: Implement BCH for 256-bit codewords**

Create `Sources/piqley/Watermarking/BCH.swift`:

BCH(256, 176) — 176 data bits, 80 parity bits. Use a shortened BCH code from BCH(255, 175) (standard GF(2^8) code). The brute-force syndrome decoder corrects up to t errors by trying all 1..t error patterns. For t=15 and n=256, the brute-force approach for high error counts is slow — use a lookup table or Berlekamp-Massey algorithm for production. For initial implementation, brute-force up to 6 errors (covers all measured scenarios) and fall back to HMAC validation for edge cases.

**Implementation note:** A practical approach is to use a simpler parity scheme initially (e.g., replicated HMAC bits for voting) and upgrade to full BCH later. The HMAC validation catches any remaining errors. However, the full BCH is preferred for robustness.

- [ ] **Step 4: Implement WatermarkPayload**

Create `Sources/piqley/Watermarking/WatermarkPayload.swift`:

Key methods:
- `encode() -> [Bool]` — version(2) + imageId(46) + hmac(128) → 176 data bits → BCH encode → 256 bits
- `encodeHex() -> String` — encode to 64-char hex string for passing to the watermark binary
- `static hexToBits(_ hex: String) -> [Bool]` — parse hex back to bits
- `static decode(from bits: [Bool], hmacKey: Data) -> WatermarkPayload?` — BCH decode → parse fields → validate HMAC
- `static generateImageId() -> UInt64` — random 46-bit value
- `static computeHMAC(imageId: UInt64, key: Data) -> Data` — HMAC-SHA256, take first 16 bytes (128 bits)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter WatermarkPayloadTests 2>&1`

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/Watermarking/WatermarkPayload.swift Sources/piqley/Watermarking/BCH.swift Tests/piqleyTests/WatermarkPayloadTests.swift
git commit -m "feat(watermark): add WatermarkPayload with 256-bit BCH error correction"
```

---

### Task 3: Create `WatermarkReference` (JSONL logging)

**Files:**
- Create: `Sources/piqley/Watermarking/WatermarkReference.swift`
- Create: `Tests/piqleyTests/WatermarkReferenceTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/piqleyTests/WatermarkReferenceTests.swift`:

```swift
import XCTest
@testable import piqley

final class WatermarkReferenceTests: XCTestCase {
    var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-wm-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmpDir) }

    func testAppendAndLookup() throws {
        let logPath = tmpDir.appendingPathComponent("watermarks.jsonl").path
        let log = WatermarkReference(path: logPath)
        let entry = WatermarkReferenceEntry(
            imageId: "a1b2c3d4e5f6", originalFilename: "IMG_1234.jpg",
            contentHash: "abc123", modelVersion: "pixelseal-1.0", timestamp: Date()
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement WatermarkReference**

Create `Sources/piqley/Watermarking/WatermarkReference.swift` following the existing `UploadLog` pattern: `Codable` entry struct with fields `imageId`, `originalFilename`, `contentHash`, `modelVersion`, `ghostPostId?`, `ghostPostUrl?`, `timestamp`. Use `JSONEncoder` with `.iso8601` dates, append via POSIX `open()` with `O_APPEND`, lookup by scanning lines. The `modelVersion` field (e.g., `"pixelseal-1.0"`) tracks which watermarking model was used, enabling graceful model upgrades.

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Watermarking/WatermarkReference.swift Tests/piqleyTests/WatermarkReferenceTests.swift
git commit -m "feat(watermark): add WatermarkReference JSONL logging"
```

---

### Task 4: Add Keychain watermark secret management

**Files:**
- Modify: `Sources/piqley/Secrets/KeychainSecretStore.swift`
- Create: `Tests/piqleyTests/WatermarkKeyTests.swift`

- [ ] **Step 1: Write failing test**

```swift
func testGenerateAndRetrieveWatermarkKey() throws {
    let store = KeychainSecretStore(service: "com.piqley.test.\(UUID().uuidString)")
    let fingerprint = "TEST_FP_1234"
    let key = try store.getOrCreateWatermarkKey(for: fingerprint)
    XCTAssertEqual(key.count, 32) // 256-bit key
    let key2 = try store.getOrCreateWatermarkKey(for: fingerprint)
    XCTAssertEqual(key, key2) // Same key on second call
    try? store.delete(key: "watermark-hmac-\(fingerprint)")
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Add `getOrCreateWatermarkKey` to KeychainSecretStore**

Generate a random 256-bit key on first call, store base64-encoded in Keychain keyed by `"watermark-hmac-\(fingerprint)"`, return on subsequent calls.

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Secrets/KeychainSecretStore.swift Tests/piqleyTests/WatermarkKeyTests.swift
git commit -m "feat(watermark): add Keychain-based HMAC key management"
```

---

### Task 5: Create `PixelSealWatermarker` (subprocess invocation)

**Files:**
- Create: `Sources/piqley/Watermarking/ImageWatermarker.swift`
- Create: `Sources/piqley/Watermarking/PixelSealWatermarker.swift`
- Create: `Tests/piqleyTests/PixelSealWatermarkerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import piqley

final class PixelSealWatermarkerTests: XCTestCase {

    func testBinaryDiscovery() throws {
        // Test that isAvailable returns a boolean without crashing
        let available = PixelSealWatermarker.isAvailable()
        // May be true or false depending on whether binary is installed
        _ = available
    }

    func testEmbedDetectRoundTrip() throws {
        guard PixelSealWatermarker.isAvailable() else {
            throw XCTSkip("piqley-watermark not installed")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("piqley-wm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create test image
        let inputPath = tmpDir.appendingPathComponent("input.png").path
        try TestFixtures.createTestJPEG(at: inputPath, width: 800, height: 600)

        let watermarker = PixelSealWatermarker()
        let hmacKey = Data(repeating: 0xAB, count: 32)
        let payload = WatermarkPayload(imageId: 0x1234_5678, hmacKey: hmacKey)

        // Embed
        let outputPath = try watermarker.embed(imagePath: inputPath, payload: payload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))

        // Detect
        let rawBits = try watermarker.extract(imagePath: outputPath)
        XCTAssertEqual(rawBits.count, 256)

        // Decode payload
        let bits = rawBits.map { $0 > 0 }
        let recovered = WatermarkPayload.decode(from: bits, hmacKey: hmacKey)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.imageId, 0x1234_5678)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Create ImageWatermarker protocol**

Create `Sources/piqley/Watermarking/ImageWatermarker.swift`:

```swift
import Foundation

protocol ImageWatermarker {
    /// Embed a watermark payload into an image. Returns path to watermarked image.
    func embed(imagePath: String, payload: WatermarkPayload) throws -> String
    /// Extract raw bit confidences from an image. Returns 256 floats.
    func extract(imagePath: String) throws -> [Float]
}
```

- [ ] **Step 4: Implement PixelSealWatermarker**

Create `Sources/piqley/Watermarking/PixelSealWatermarker.swift`:

```swift
import Foundation
import Logging

struct PixelSealWatermarker: ImageWatermarker {
    private let logger = Logger(label: "piqley.watermark")

    enum WatermarkError: Error, LocalizedError {
        case binaryNotFound
        case embedFailed(String)
        case detectFailed(String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "piqley-watermark not found. Install with: brew install piqley-watermark"
            case .embedFailed(let msg): return "Watermark embedding failed: \(msg)"
            case .detectFailed(let msg): return "Watermark detection failed: \(msg)"
            case .invalidOutput(let msg): return "Invalid watermark output: \(msg)"
            }
        }
    }

    static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["piqley-watermark", "version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func embed(imagePath: String, payload: WatermarkPayload) throws -> String {
        guard Self.isAvailable() else { throw WatermarkError.binaryNotFound }

        let outputPath = imagePath + ".watermarked.png"
        let messageHex = payload.encodeHex()

        logger.debug("Watermark binary: piqley-watermark embed --image \(imagePath) --message \(messageHex) --output \(outputPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["piqley-watermark", "embed",
                           "--image", imagePath,
                           "--message", messageHex,
                           "--output", outputPath]

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WatermarkError.embedFailed(stderr)
        }

        return outputPath
    }

    func extract(imagePath: String) throws -> [Float] {
        guard Self.isAvailable() else { throw WatermarkError.binaryNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["piqley-watermark", "detect", "--image", imagePath]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WatermarkError.detectFailed(stderr)
        }

        let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // Parse JSON: {"confidence": 0.05, "bits": [3.14, -2.71, ...]}
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bits = json["bits"] as? [Double] else {
            throw WatermarkError.invalidOutput("Cannot parse detect output")
        }

        return bits.map { Float($0) }
    }
}
```

- [ ] **Step 5: Run tests (skip if binary not installed)**

Run: `swift test --filter PixelSealWatermarkerTests 2>&1`

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/Watermarking/ImageWatermarker.swift Sources/piqley/Watermarking/PixelSealWatermarker.swift Tests/piqleyTests/PixelSealWatermarkerTests.swift
git commit -m "feat(watermark): add PixelSealWatermarker with subprocess invocation"
```

---

### Task 6: Refactor `ImageProcessor` to return `CGImage` + create `ImageFinalizer`

**Files:**
- Modify: `Sources/piqley/ImageProcessing/ImageProcessor.swift`
- Modify: `Sources/piqley/ImageProcessing/CoreGraphicsImageProcessor.swift`
- Create: `Sources/piqley/ImageProcessing/ImageFinalizer.swift`
- Modify: `Tests/piqleyTests/ImageProcessorTests.swift`

- [ ] **Step 1: Write failing tests for new interface**

Add to `Tests/piqleyTests/ImageProcessorTests.swift`:

```swift
func testResizeReturnsCGImage() throws {
    let path = tmpDir.appendingPathComponent("test.jpg").path
    try TestFixtures.createTestJPEG(at: path, width: 3000, height: 2000, cameraMake: "Canon")

    let processor = CoreGraphicsImageProcessor()
    let (resized, metadata) = try processor.resize(
        inputPath: path, maxLongEdge: 2000, metadataAllowlist: ["TIFF.Make"]
    )
    XCTAssertEqual(resized.width, 2000)
    XCTAssertEqual(resized.height, 1333)
}

func testImageFinalizerWritesJPEG() throws {
    let inputPath = tmpDir.appendingPathComponent("input.jpg").path
    let outputPath = tmpDir.appendingPathComponent("output.jpg").path
    try TestFixtures.createTestJPEG(at: inputPath, width: 800, height: 600)

    let processor = CoreGraphicsImageProcessor()
    let (resized, metadata) = try processor.resize(
        inputPath: inputPath, maxLongEdge: 800, metadataAllowlist: []
    )
    try ImageFinalizer.writeJPEG(resized, metadata: metadata, quality: 80, to: outputPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
}

func testImageFinalizerWritesPNG() throws {
    let inputPath = tmpDir.appendingPathComponent("input.jpg").path
    let outputPath = tmpDir.appendingPathComponent("output.png").path
    try TestFixtures.createTestJPEG(at: inputPath, width: 400, height: 300)

    let processor = CoreGraphicsImageProcessor()
    let (resized, _) = try processor.resize(
        inputPath: inputPath, maxLongEdge: 400, metadataAllowlist: []
    )
    try ImageFinalizer.writePNG(resized, to: outputPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Add `resize` method to protocol and implementation**

Add `resize(inputPath:maxLongEdge:metadataAllowlist:) throws -> (CGImage, [String: Any])` to `ImageProcessor` protocol. Implement on `CoreGraphicsImageProcessor` by extracting the resize + metadata filtering logic from `process()`. Use `bytesPerRow: 0` and `cgImage.colorSpace` to match existing behavior. Refactor `process()` to call `resize()` + `ImageFinalizer.writeJPEG()`.

- [ ] **Step 4: Create ImageFinalizer**

Create `Sources/piqley/ImageProcessing/ImageFinalizer.swift` with:

- `static func writeJPEG(_ image: CGImage, metadata: [String: Any], quality: Int, to path: String) throws` — single JPEG encode point
- `static func writePNG(_ image: CGImage, to path: String) throws` — lossless interchange for watermark binary
- `static func readCGImage(from path: String) throws -> CGImage` — read any image format back to CGImage
- `static func writeXMPMetadata(to path: String, fields: [...]) throws` — uses `CGImageDestinationCopyImageSource` for lossless XMP embedding

- [ ] **Step 5: Run all ImageProcessor tests**

Run: `swift test --filter ImageProcessorTests 2>&1`

- [ ] **Step 6: Commit**

```bash
git add Sources/piqley/ImageProcessing/ Tests/piqleyTests/ImageProcessorTests.swift
git commit -m "refactor(pipeline): split ImageProcessor into resize + finalize for unified pipeline"
```

---

### Task 7: Integrate watermarking into `ProcessCommand`

**Files:**
- Modify: `Sources/piqley/CLI/ProcessCommand.swift`

- [ ] **Step 1: Add `--no-watermark` flag**

After the existing `--no-sign` flag, add:
```swift
@Flag(help: "Skip watermark embedding for this run")
var noWatermark = false
```

- [ ] **Step 2: Create watermarker instance before the image loop**

At the top of `run()`, alongside existing `imageProcessor` and `ghostClient`:
```swift
let watermarker: PixelSealWatermarker? = {
    guard let sc = config.resolvedSigningConfig, sc.watermark else { return nil }
    guard PixelSealWatermarker.isAvailable() else { return nil }
    return PixelSealWatermarker()
}()
let hmacKey: Data? = try config.resolvedSigningConfig.map {
    try secretStore.getOrCreateWatermarkKey(for: $0.keyFingerprint)
}
```

- [ ] **Step 3: Replace `imageProcessor.process()` with unified pipeline**

Replace the direct `process()` call with:
1. `processor.resize()` → `CGImage` + metadata
2. If watermarking: `ImageFinalizer.writePNG()` → `watermarker.embed()` → `ImageFinalizer.readCGImage()`
3. `ImageFinalizer.writeJPEG()` with filtered metadata
4. GPG sign (existing)
5. Record watermark reference

- [ ] **Step 4: Build to verify compilation**

Run: `swift build 2>&1`

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/CLI/ProcessCommand.swift
git commit -m "feat(watermark): integrate watermarking into unified processing pipeline"
```

---

### Task 8: Add watermark ID to Ghost posts via LexicalBuilder

**Files:**
- Modify: `Sources/piqley/Ghost/LexicalBuilder.swift`
- Modify: `Sources/piqley/CLI/ProcessCommand.swift`

- [ ] **Step 1: Write failing test**

```swift
func testBuildWithWatermarkId() throws {
    let result = LexicalBuilder.build(title: "Test", description: "A photo", watermarkId: "a1b2c3d4e5f6")
    XCTAssertTrue(result.contains("data-piqley-id"))
    XCTAssertTrue(result.contains("a1b2c3d4e5f6"))
}
func testBuildWithoutWatermarkId() throws {
    let result = LexicalBuilder.build(title: "Test", description: "A photo", watermarkId: nil)
    XCTAssertFalse(result.contains("data-piqley-id"))
}
```

- [ ] **Step 2: Add `watermarkId` parameter to `LexicalBuilder.build()`**

Add optional `watermarkId: String? = nil`. When non-nil, append an HTML card node with hidden span.

- [ ] **Step 3: Pass watermarkId from ProcessCommand**

- [ ] **Step 4: Run tests**

- [ ] **Step 5: Commit**

```bash
git add Sources/piqley/Ghost/LexicalBuilder.swift Sources/piqley/CLI/ProcessCommand.swift Tests/
git commit -m "feat(watermark): embed watermark ID in Ghost posts via Lexical HTML card"
```

---

### Task 9: Add watermark extraction to `VerifyCommand`

**Files:**
- Modify: `Sources/piqley/CLI/VerifyCommand.swift`

- [ ] **Step 1: Add watermark fallback after XMP verification fails**

When no XMP signature is found, add:
1. Check `PixelSealWatermarker.isAvailable()`
2. Shell out to `piqley-watermark detect`
3. Parse 256 float confidences → threshold to bits
4. BCH decode → validate HMAC
5. Look up image ID in `WatermarkReference`
6. Report results

- [ ] **Step 2: Build to verify compilation**

Run: `swift build 2>&1`

- [ ] **Step 3: Commit**

```bash
git add Sources/piqley/CLI/VerifyCommand.swift
git commit -m "feat(watermark): add watermark extraction fallback to verify command"
```

---

### Task 10: Run full test suite and fix issues

- [ ] **Step 1: Run all tests**

Run: `swift test 2>&1`

- [ ] **Step 2: Fix any compilation or test failures**

- [ ] **Step 3: Run build in release mode**

Run: `swift build -c release 2>&1`

- [ ] **Step 4: Commit any fixes**

---

### Task Dependency Graph

```
Task 0 (C++ binary)              ── independent, can start immediately

Task 1 (SigningConfig.watermark)  ──┐
Task 2 (WatermarkPayload + BCH)  ──┤
Task 3 (WatermarkReference)      ──┼── independent, can run in parallel
Task 4 (Keychain HMAC key)       ──┤
Task 6 (Refactor ImageProcessor) ──┘
                                    │
Task 5 (PixelSealWatermarker)    ←──┤ depends on Tasks 2, 0 (needs binary for integration tests)
                                    │
Task 7 (ProcessCommand)          ←──┤ depends on Tasks 5, 3, 4, 6
Task 8 (LexicalBuilder)          ←──┤ depends on Task 7
Task 9 (VerifyCommand)           ←──┤ depends on Tasks 5, 3, 4
Task 10 (Full test suite)        ←──  depends on all
```

Tasks 0, 1, 2, 3, 4, and 6 are independent and can run in parallel.
