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
// P2-E2: 视觉上传 + Provider 协议层
registerUploadImageProviderTests(tests)
registerImageProviderRegistryTests(tests)
registerStubProviderTests(tests)
// P2-L-2: Selection trigger + panel + coordinator
registerSelectionCoordinatorTests(tests)
registerSelectionPanelTests(tests)

let code = tests.run()
exit(code)
