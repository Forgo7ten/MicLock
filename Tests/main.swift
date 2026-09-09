import Foundation

// 顶层代码在主 actor 上执行，统计变量随之为 main actor 隔离；
// expect/test 标注 @MainActor 以便访问。
var passCount = 0
var failCount = 0

@MainActor
func test(_ name: String) {
    print("• \(name)")
}

@MainActor
func expect(
    _ condition: Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    if condition {
        passCount += 1
    } else {
        failCount += 1
        print("  ✗ \(message)  [\(file):\(line)]")
    }
}

print("MicLock v2 unit tests")
print()

await runAllTests()

print()
print("== \(passCount) passed, \(failCount) failed ==")

exit(failCount == 0 ? 0 : 1)
