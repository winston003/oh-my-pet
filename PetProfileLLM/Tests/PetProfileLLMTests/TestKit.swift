// TestKit.swift
// PetProfileLLMTests 测试基础 — 极简 test runner（跟 PetProfileBrain / PetProfileKit /
// PetProfileRuntime / PetProfileOnboarding 同款）
//
// 设计：避开 XCTest.framework（CommandLineTools 目标没公共 XCTest）；用 do-try-catch +
// 抛 TestFailure 的方式统计通过/失败。
//
// 用法：
//   - Tests(suiteName:) → 注册容器
//   - tests.add(name, fn) → 各测试 file 暴露 register 函数，main 调一遍
//   - tests.run() → 跑全部
//
//

import Foundation

public struct TestFailure: Error, CustomStringConvertible {
    public let name: String
    public let message: String
    public var description: String { "TestFailure(\(name)): \(message)" }
}

public final class Tests {
    public static let shared = Tests()
    public typealias TestFn = (Tests) throws -> Void

    private var tests: [(name: String, fn: TestFn)] = []
    public let suiteName: String

    public init(suiteName: String = "PetProfileLLM") {
        self.suiteName = suiteName
    }

    public func add(_ name: String, _ fn: @escaping TestFn) {
        tests.append((name, fn))
    }

    @discardableResult
    public func run() -> Int32 {
        var passed = 0
        var failed = 0
        print("=== \(suiteName) ===")
        for (name, fn) in tests {
            do {
                try fn(self)
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

public func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = try a(); let bv = try b()
    if av != bv {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertEqual failed: \(av) != \(bv). \(message)")
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = try a(); let bv = try b()
    if av == bv {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertNotEqual failed: \(av) == \(bv). \(message)")
    }
}

public func XCTAssertEqualD(_ a: @autoclosure () -> Double, _ b: @autoclosure () -> Double, accuracy: Double = 1e-9, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = a(); let bv = b()
    if Swift.abs(av - bv) > accuracy {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertEqualD failed: \(av) != \(bv) (accuracy=\(accuracy)). \(message)")
    }
}

public func XCTAssertNotNil<T>(_ v: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if try v() == nil {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertNotNil failed. \(message)")
    }
}

public func XCTAssertNil<T>(_ v: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if try v() != nil {
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

public func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = try a(); let bv = try b()
    if !(av >= bv) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertGreaterThanOrEqual failed: \(av) < \(bv). \(message)")
    }
}

public func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = try a(); let bv = try b()
    if !(av < bv) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertLessThan failed: \(av) >= \(bv). \(message)")
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let av = try a(); let bv = try b()
    if !(av > bv) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertLessThanOrEqual failed: \(av) > \(bv). \(message)")
    }
}

public func XCTUnwrap<T>(_ v: @autoclosure () throws -> T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let x = try v() else {
        throw TestFailure(name: "\(file):\(line)", message: "XCTUnwrap failed. \(message)")
    }
    return x
}

public func XCTAssertContains(_ haystack: @autoclosure () throws -> String, _ needle: String, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let h = try haystack()
    if !h.contains(needle) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertContains failed: '\(h.prefix(200))' does not contain '\(needle)'. \(message)")
    }
}

public func XCTAssertNotContains(_ haystack: @autoclosure () throws -> String, _ needle: String, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    let h = try haystack()
    if h.contains(needle) {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertNotContains failed: '\(h.prefix(200))' contains '\(needle)'. \(message)")
    }
}

// MARK: - async helper

/// 跑 async closure 同步等结果。`fn` 必须用 `throws async -> Void` 形式。
public func XCTAssertAsync(
    timeout: TimeInterval = 30,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line,
    _ fn: @escaping () async throws -> Void
) throws {
    let sem = DispatchSemaphore(value: 0)
    let box = SyncResultBox()
    Task.detached(priority: .userInitiated) {
        do {
            try await fn()
            box.set(.success(()))
        } catch {
            box.set(.failure(error))
        }
        sem.signal()
    }
    let result = sem.wait(timeout: .now() + timeout)
    if result == .timedOut {
        throw TestFailure(name: "\(file):\(line)", message: "XCTAssertAsync timed out after \(timeout)s. \(message)")
    }
    try box.unwrap()
}

private final class SyncResultBox: @unchecked Sendable {
    private var value: Result<Void, Error>?
    private let lock = NSLock()
    func set(_ r: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = r
    }
    func unwrap() throws {
        lock.lock(); defer { lock.unlock() }
        guard let v = value else {
            throw TestFailure(name: "XCTAssertAsync", message: "no result")
        }
        try v.get()
    }
}
