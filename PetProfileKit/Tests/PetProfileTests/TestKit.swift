// TestKit.swift
// 极简 test runner：不依赖 XCTest / Swift Testing，可在任何 Swift 编译器上跑
// 用法：
//   - test suite 函数把 test 注入到 `Tests.shared.add`
//   - `Tests.shared.run()` 输出 "[PASS]/[FAIL] test-name" 并统计
//   - 进程退出码 = 失败数
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

    public init(suiteName: String = "PetProfileKit") {
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
