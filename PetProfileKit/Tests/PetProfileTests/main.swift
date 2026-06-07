// main.swift
// PetProfileTests 入口：注册全部 test 并运行
//

import Foundation
@testable import PetProfile

// 用 sub-suite 隔离，output 加上 prefix
let tests = Tests(suiteName: "PetProfileKit")

// 调用各 file 里的 register
registerV01Tests(tests)
registerV1Tests(tests)
registerValidatorTests(tests)
registerUpgraderTests(tests)

let code = tests.run()
exit(code)
