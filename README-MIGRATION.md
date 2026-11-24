# 青果项目完整迁移包

这是可继续开发的项目快照，包含当前源码、未提交和未跟踪的项目文件、`.git` 历史、签名及密码解密材料、测试依赖与夹具、最新和历史安装包，以及本说明。当前应用版本为 **1.1.1 / 1001001**。

**新 agent 请先阅读 `handoff/AGENT_HANDOFF.md`。** 当前大量有效功能尚未提交，不能用 `git archive HEAD`、`reset --hard` 或旧提交替换工作区。

## 新电脑开始开发

本包按 Windows 开发环境整理。推荐使用当前已验证环境：DevEco Studio **26.0.0.865**、HarmonyOS SDK **API 26 / 26.0.0.105**；项目最低兼容配置为 `6.1.1(24)`。SDK、IDE 和系统驱动不包含在 ZIP 中，需要在新电脑安装。使用其他系统或 SDK 版本需要另行适配，不能视为已验证。

1. 将 ZIP 完整解压到可写目录，例如 `C:\Projects\qingguoapp`，用资源管理器确认 `.git`、`.private-signing` 等点开头目录也存在。不要只复制 `entry`。
2. 在 DevEco Studio 安装 HarmonyOS SDK 的 ETS、Native、Toolchains 等组件。推荐先安装与上面相同的版本；CLI 使用 DevEco 自带 Node、Java、Hvigor 和 OHPM，不要求另外装 Node。
3. 在项目根目录打开 PowerShell，按实际 IDE 安装位置执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\handoff\Verify-Project.ps1
powershell -ExecutionPolicy Bypass -File .\handoff\Setup-Project.ps1 -DevEcoHome "C:\Program Files\Huawei\DevEco Studio"
powershell -ExecutionPolicy Bypass -File .\handoff\Build-Project.ps1
```

第一条在首次设置或编辑前核对解压文件；设置脚本保存本机 IDE 路径，构建脚本读取该路径，运行全部 21 项测试后编译、打包并签名。若 SDK 不在 IDE 的 `sdk` 子目录，首次设置时加 `-SdkHome "E:\HarmonySDK"`，该目录下应有 `default\openharmony`。

4. 用 DevEco 打开整个项目根目录继续编码。若依赖同步提示更新，先保留现有版本；确需重新安装依赖，可运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\handoff\Setup-Project.ps1 -ReinstallDependencies
```

正常情况下包内已经带有展开为普通目录的 OHPM 依赖，以及 QuickJS-WASM 测试依赖，不依赖原电脑的 junction。重新安装或升级依赖需要网络；本包不是完整离线 SDK 安装器。

生成的签名 HAP 位于：

```text
entry/build/default/outputs/default/entry-default-signed.hap
```

`handoff/regression.log` 和 `handoff/build.log` 保存本机测试、构建输出。只跑测试时，在已设置环境的终端执行 `node scripts/run-tests.cjs`；或指定 `DEVECO_STUDIO_HOME` 后使用 IDE 自带 `tools/node/node.exe` 执行。

## 签名迁移

`.private-signing/` 包含本项目的 `.p12` 私钥容器、`.cer` 证书、`.p7b` 调试描述文件、可用的 `.csr`，以及 `material/` 密码解密材料。`build-profile.json5` 保留原有加密密码和别名，三个签名文件路径改为包内相对路径。**仅复制 p12/p7b/cer 而漏掉 material 会导致原加密密码不能解密。**

设置脚本只使用本项目内的材料，不覆盖新电脑的全局 `.ohos/config`，也不打印密码。请保留这几个文件之间的配套关系，不要在 DevEco 中随手改成另一套自动调试签名。

沿用调试描述文件的设备授权及有效期限制：更换开发电脑不等于授权新手机。安装到原有已授权设备可按说明覆盖安装；换手机、描述文件过期或授权失效时，需在 DevEco 用相应开发者权限重新生成匹配的描述文件/签名配置。不要通过卸载 App 解决签名问题，以免丢失数据。

**此 ZIP 内含真实私钥及解密材料，请私下传输保存，不要上传公开仓库或公开网盘。** `.private-signing/` 已加入项目忽略规则；现有 Git 历史及构建配置也仅作为私有迁移内容处理。没有打包 Huawei 账号登录令牌、浏览器登录状态或其他项目的私钥。

## 包含与排除

- 包含当前项目工作区、源码资源、C/C++ QuickJS、两级包清单和锁文件、Git 历史、UI 设计文档与实验目录、原有 `dist` 文件、21 项测试及其所需离线依赖。
- `.cache/module-html-runtime` 和 `.cache/module-work` 为测试所需，已保留，不能把整个 `.cache` 删掉后直接声称测试可运行。
- 不携带可重新生成且绑定旧路径的 `.hvigor`、`entry/build`、`.cxx`、IDE 工作区、旧截图/调试缓存和本次打包临时目录；保留的 Git 历史不会因此被裁剪。精确排除规则见 `handoff/create-stage.cjs`。
- 不包含手机应用沙箱中的 Preferences、观看记录、已安装站源状态；这些数据仍在手机上，开发电脑迁移不会自动导出它们。
- `MANIFEST.sha256` 记录最终 ZIP 内项目文件的 SHA-256（不含它自己），外部同名 `.sha256.txt` 用于核对整个 ZIP。

## 验证边界

交付前会在全新迁移目录运行设置、21 项测试、完整 HAP 构建和签名，并核对 ZIP 的每个文件、Git 历史和签名材料。实际结果写入 `handoff/TRANSFER_VERIFICATION.json`。

这验证了换路径后的项目可恢复构建，不等于已经在另一台物理电脑或手机执行。新电脑仍需安装匹配的 DevEco/SDK，设备仍需有效调试授权。1.1.1 分季版本尚无本次目标手机实测记录。
