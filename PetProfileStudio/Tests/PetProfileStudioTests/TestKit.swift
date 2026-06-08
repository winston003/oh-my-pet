// TestKit.swift
// 极简 test runner（跟 PetProfileKit/Tests/PetProfileTests/TestKit.swift 一致）
// 各 test target 独立，不共享 TestKit。
//
// P2-J 增加：makeTempPetStore() —— 给 PetStore 一个独立 tmp dir，
// 测试结束后自动 cleanup。production 路径仍走 PetStore.shared。
//

import Foundation
import AppKit
import PetProfileRuntime
@testable import PetProfileStudio

public struct TestFailure: Error, CustomStringConvertible {
    public let name: String
    public let message: String
    public var description: String { "TestFailure(\(name)): \(message)" }
}

public final class Tests {
    public static let shared = Tests()
    public typealias TestFn = (Tests) throws -> Void
    public typealias AsyncTestFn = (Tests) async throws -> Void

    private enum AnyTest {
        case sync(TestFn)
        case async(AsyncTestFn)
    }

    private var tests: [(name: String, fn: AnyTest)] = []
    public let suiteName: String

    public init(suiteName: String = "PetProfileStudio") {
        self.suiteName = suiteName
    }

    public func add(_ name: String, _ fn: @escaping TestFn) {
        tests.append((name, .sync(fn)))
    }

    public func add(_ name: String, _ fn: @escaping AsyncTestFn) {
        tests.append((name, .async(fn)))
    }

    @discardableResult
    public func run() -> Int32 {
        var passed = 0
        var failed = 0
        print("=== \(suiteName) ===")
        for (name, test) in tests {
            do {
                switch test {
                case .sync(let fn):
                    try fn(self)
                case .async(let fn):
                    let semaphore = DispatchSemaphore(value: 0)
                    var caughtError: Error?
                    Task {
                        do {
                            try await fn(self)
                        } catch {
                            caughtError = error
                        }
                        semaphore.signal()
                    }
                    semaphore.wait()
                    if let err = caughtError {
                        throw err
                    }
                }
                print("  [PASS] \(name)")
                passed += 1
            } catch {
                print("  [FAIL] \(name): \(error)")
                failed += 1
            }
        }
        print("---")
        print("Passed: \(passed), Failed: \(failed), Total: \(tests.count)")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - assertion helpers

public func XCTAssert(_ cond: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !cond() {
        throw TestFailure(name: "\(file):\(line)", message: message.isEmpty ? "XCTAssert failed" : message)
    }
}

public func XCTAssertTrue(_ cond: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !cond() {
        throw TestFailure(name: "\(file):\(line)", message: message.isEmpty ? "XCTAssertTrue failed" : message)
    }
}

public func XCTAssertFalse(_ cond: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if cond() {
        throw TestFailure(name: "\(file):\(line)", message: message.isEmpty ? "XCTAssertFalse failed" : message)
    }
}

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = a(); let bv = b()
    if av != bv {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertEqual failed: \(av) != \(bv). \(message)")
    }
}

public func XCTAssertEqualD(_ a: @autoclosure () -> Double, _ b: @autoclosure () -> Double, accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = a(); let bv = b()
    if Swift.abs(av - bv) > accuracy {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertEqualD failed: \(av) != \(bv) (accuracy=\(accuracy)). \(message)")
    }
}

public func XCTAssertNotNil<T>(_ v: @autoclosure () -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if v() == nil {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertNotNil failed. \(message)")
    }
}

public func XCTAssertNil<T>(_ v: @autoclosure () -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if v() != nil {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertNil failed. \(message)")
    }
}

public func XCTAssertThrowsError(_ fn: () throws -> Void, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    do {
        try fn()
    } catch {
        return
    }
    throw TestFailure(name: "\(file):\(line)", message: "XCTAssertThrowsError: expected throw. \(message)")
}

public func XCTAssertNoThrow(_ fn: () throws -> Void, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    do {
        try fn()
    } catch {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertNoThrow: unexpected throw: \(error). \(message)")
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !(a() >= b()) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertGreaterThanOrEqual failed: \(a()) < \(b()). \(message)")
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !(a() <= b()) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertLessThanOrEqual failed: \(a()) > \(b()). \(message)")
    }
}

public func XCTUnwrap<T>(_ v: @autoclosure () -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let x = v() else {
        throw TestFailure(name: "\(file):\(line)", message: "XCTUnwrap failed. \(message)")
    }
    return x
}

// MARK: - Selection 测试 helper（P2-L-2 引入）

/// 创建 NSPasteboard mock —— 用 withUniqueName 拿到独立 pasteboard，**不**碰 .general
/// 返回 (pasteboard, cleanup)；测试结束 defer cleanup() 释放
public func makeMockPasteboard() -> (NSPasteboard, () -> Void) {
    let pb = NSPasteboard(name: NSPasteboard.Name("test-\(UUID().uuidString)"))
    pb.clearContents()
    return (pb, { pb.releaseGlobally() })
}

/// 在 pasteboard 写 string
public func setPasteboardString(_ pb: NSPasteboard, _ s: String?) {
    pb.clearContents()
    if let s, !s.isEmpty {
        pb.setString(s, forType: .string)
    }
}

/// 固定 FrontmostAppCapture.Snapshot（注入）
public func fixedSnapshot() -> FrontmostAppCapture.Snapshot {
    FrontmostAppCapture.Snapshot(
        bundleID: "com.test.app",
        appName: "TestApp",
        windowTitle: nil,  // MVP 不读
        capturedAt: Date()
    )
}

// MARK: - PetStore 临时目录 helper（P2-J 引入）

/// 创建一个独立的 tmp PetStore root，避开真实 ~/Library/Application Support。
/// 返回 (store, tmpRootURL)，test 末尾用 cleanupTempPetStore() 删除 tmpRoot。
///
/// 使用模式：
/// ```
/// let (store, tmp) = try makeTempPetStore()
/// defer { cleanupTempPetStore(tmp) }
/// ```
///
/// 重要：必须显式传 `UploadImageProvider(store: store)`，否则走 default `.shared` 会污染用户 Application Support。
public func makeTempPetStore() throws -> (store: PetStore, tmpRoot: URL) {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("oh-my-pet-test-\(UUID().uuidString.prefix(12))", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let storeRoot = tmp.appendingPathComponent("store-root", isDirectory: true)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    return (PetStore(root: storeRoot), tmp)
}

/// 清理 makeTempPetStore() 产生的 tmp dir。
/// 用 FileManager.removeItem —— best effort，cleanup 失败不抛错。
public func cleanupTempPetStore(_ tmpRoot: URL) {
    try? FileManager.default.removeItem(at: tmpRoot)
}

/// 当前用户真实 ~/Library/Application Support/oh-my-pet/pets/ 路径（用于隔离断言）
public func realAppSupportPetsPath() -> URL {
    return PetStore.defaultRoot()
}
