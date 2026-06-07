// main.swift
// PetProfileStudioApp 命令行入口
//
// 行为：
//   1. 验证 PetStore 可用：用 fixture 路径 + 注入临时 root
//   2. 跑 CRUD：loadAll → create → update → delete → loadAll
//   3. 跑 export：把 pet 打成 .omppet 文件
//   4. 触发 SwiftUI App 类型检查（不实际启动 GUI）
//   5. exit 0
//
// 用法：
//   swift run PetProfileStudioApp
//
// 不要求 GUI 实际显示；只验证：
//   - PetStore CRUD 通过
//   - Export .omppet 通过
//   - SwiftUI App 入口 build 通过（PetProfileStudioApp.main() 编译可用）
//
// Exit code:
//   0 = success
//   1 = failure（store / export / type-check 错）
//

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileStudio

// 触发 SwiftUI App 类型检查（不实际启动 GUI）
_ = PetProfileStudioApp.self

func printBanner(_ msg: String) {
    print("[studio] \(msg)")
}

// 1. 用临时目录（避免污染真 ~/Library/Application Support）
let tmpRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("oh-my-pet-studio-\(UUID().uuidString.prefix(8))", isDirectory: true)
let store = PetStore(root: tmpRoot)
printBanner("root: \(tmpRoot.path)")

// 2. loadAll (空)
let initial = try store.loadAll()
printBanner("初始 loadAll：\(initial.count) 只 pet")

// 3. 找 fixture
let fixtureRoot = "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
let pakoManifest = URL(fileURLWithPath: "\(fixtureRoot)/pako-v1.0.0.json")
let mituManifest = URL(fileURLWithPath: "\(fixtureRoot)/mitu-v1.0.0.json")
let zorpManifest = URL(fileURLWithPath: "\(fixtureRoot)/zorp-v1.0.0.json")

// 4. create 3 只
let loader = PetProfileLoader()
for url in [pakoManifest, mituManifest, zorpManifest] {
    let loaded = try loader.loadProfile(from: url)
    try store.create(profile: loaded)
}
let all = try store.loadAll()
guard all.count == 3 else {
    FileHandle.standardError.write(Data("expected 3 pets, got \(all.count)\n".utf8))
    exit(1)
}
printBanner("[OK] 创建 3 只 pet：\(all.map { $0.name }.joined(separator: ", "))")

// 5. update（改 Pako 名字 + 加 tag）
let pako = all.first { $0.id == "pet_pako_v10" }!
var pakoLoaded = try store.load(id: pako.id)
let newPersona = PersonaCard(
    name: "Pako",
    loreShort: pakoLoaded.manifest.persona.loreShort,
    relationshipWithUser: pakoLoaded.manifest.persona.relationshipWithUser,
    recurringMotifs: pakoLoaded.manifest.persona.recurringMotifs,
    backstoryTags: (pakoLoaded.manifest.persona.backstoryTags ?? []) + ["edited"]
)
let newManifest = PetProfileV1(
    version: pakoLoaded.manifest.version,
    minRuntimeVersion: pakoLoaded.manifest.minRuntimeVersion,
    id: pakoLoaded.manifest.id,
    name: "Pako-Edited",
    createdAt: pakoLoaded.manifest.createdAt,
    locale: pakoLoaded.manifest.locale,
    visual: pakoLoaded.manifest.visual,
    audio: pakoLoaded.manifest.audio,
    action: pakoLoaded.manifest.action,
    expression: pakoLoaded.manifest.expression,
    humor: pakoLoaded.manifest.humor,
    persona: newPersona
)
pakoLoaded = LoadedPetProfile(
    profileRoot: pakoLoaded.profileRoot,
    manifest: newManifest,
    visualAssetURLs: pakoLoaded.visualAssetURLs,
    expressionAssetURLs: pakoLoaded.expressionAssetURLs,
    actionIdleAssetURL: pakoLoaded.actionIdleAssetURL,
    actionReactionAssetURLs: pakoLoaded.actionReactionAssetURLs,
    voiceCloneSampleURL: pakoLoaded.voiceCloneSampleURL
)
try store.update(pakoLoaded)
let afterUpdate = try store.loadAll()
guard let updated = afterUpdate.first(where: { $0.id == "pet_pako_v10" }), updated.name == "Pako-Edited" else {
    FileHandle.standardError.write(Data("update failed: name not changed\n".utf8))
    exit(1)
}
printBanner("[OK] update：\(pako.name) → \(updated.name)")

// 6. delete 1 只
try store.delete(id: "pet_zorp_v10")
let afterDelete = try store.loadAll()
guard afterDelete.count == 2 else {
    FileHandle.standardError.write(Data("expected 2 pets after delete, got \(afterDelete.count)\n".utf8))
    exit(1)
}
printBanner("[OK] delete：zorp 已删，剩 \(afterDelete.count) 只")

// 7. export Pako
let exportURL = tmpRoot.appendingPathComponent("pako-export.omppet")
try store.export(profileID: "pet_pako_v10", to: exportURL)
guard FileManager.default.fileExists(atPath: exportURL.path) else {
    FileHandle.standardError.write(Data("export file not created\n".utf8))
    exit(1)
}
let size = (try? FileManager.default.attributesOfItem(atPath: exportURL.path)[.size] as? Int) ?? 0
printBanner("[OK] export：\(exportURL.path) (\(size) bytes)")

// 8. final summary
printBanner("[OK] PetProfileStudioApp：CRUD + export 通过；SwiftUI App 编译可用")
exit(0)
