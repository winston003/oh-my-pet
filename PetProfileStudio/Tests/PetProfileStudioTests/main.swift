// main.swift
// PetProfileStudioTests 入口：注册全部 test 并运行
//

import Foundation
@testable import PetProfileStudio

let tests = Tests(suiteName: "PetProfileStudio")

registerPetStoreTests(tests)
registerStudioViewTests(tests)
registerHouseViewTests(tests)
registerExportTests(tests)

let code = tests.run()
exit(code)
