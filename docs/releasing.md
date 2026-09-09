# 发布与 Homebrew Cask

## 从 GitHub 网页发布

仓库中的 `Release` workflow 由网页手动触发：Ubuntu runner 读取版本并发布，macOS runner 负责测试与双架构构建，整体完成以下工作：

1. 从 `Info.plist` 读取版本号并生成 tag；
2. 运行单元测试；
3. 分别在 Apple Silicon 与 Intel runner 上构建对应架构的 `MicLock.app`；
4. 将两个 App 分别打包为带架构名称的 ZIP；
5. 创建 tag 和 GitHub Release，上传 ZIP 与 SHA-256 校验文件。

发布前修改 `Info.plist`：

- `CFBundleShortVersionString`：用户看到的版本，使用 `X.Y.Z` 格式；
- `CFBundleVersion`：只递增的整数构建号。

应用的 `CFBundleIdentifier` 固定为 `lee.miclock.app`，正常发版时不要修改。

提交并推送版本改动到默认分支后：

1. 打开 GitHub 仓库的 **Actions** 页面；
2. 选择左侧的 **Release**；
3. 点击 **Run workflow**，分支选择 `main`；
4. 正式版本不勾选预发布，测试版本勾选；
5. 再次点击 **Run workflow**。

不需要输入或提前创建 tag。workflow 会从默认分支当前 HEAD 的 `CFBundleShortVersionString` 读取版本，将 `X.Y.Z` 生成为 `vX.Y.Z`。发布成功时，tag 会指向该 HEAD 提交并自动生成 Release Notes。`CFBundleShortVersionString` 必须使用 `MAJOR.MINOR.PATCH` 格式，`CFBundleVersion` 必须是整数，否则任务会停止。

若同名 tag 已指向其他提交，workflow 会在两个架构的产物都构建并校验成功后，删除与该 tag 关联的旧 Release（若有）和 tag，再从当前 HEAD 重新创建。若同名 Release 已经指向当前 HEAD，任务会停止，避免重复发布。

Release 产物命名如下：

```text
MicLock-vX.Y.Z-arm64.zip
MicLock-vX.Y.Z-arm64.zip.sha256
MicLock-vX.Y.Z-x86_64.zip
MicLock-vX.Y.Z-x86_64.zip.sha256
```

Apple Silicon Mac 使用 `arm64`，Intel Mac 使用 `x86_64`。两个 ZIP 内的应用名称都保持为 `MicLock.app`。

当前构建使用 ad-hoc 签名，没有 Apple Developer ID 公证。用户首次打开下载的 App 时，macOS 可能显示来源或开发者无法验证的提示；要获得无提示的公开分发体验，需要 Apple Developer Program 证书并在 workflow 中增加 Developer ID 签名和 notarization。

## Homebrew Cask

Homebrew Tap 与 Cask 文件、安装方法和自动追踪说明已移至独立仓库：[Forgo7ten/homebrew-tap](https://github.com/Forgo7ten/homebrew-tap)。

Stable Release 发布成功后，Release workflow 会通过 `repository_dispatch`
触发 `Forgo7ten/homebrew-tap` 的 MicLock Cask 更新流程。

源仓库需要配置 Actions Secret `HOMEBREW_TAP_TOKEN`。该 Secret 使用只授权
`Forgo7ten/homebrew-tap` 的 fine-grained PAT，并授予 `Contents: Read and write`。

预发布版本不会触发 Tap 更新。若自动 dispatch 失败，Release 本身仍保持成功，
随后在 `Forgo7ten/homebrew-tap` 中手动运行 `Update MicLock Cask` workflow 即可补同步。
