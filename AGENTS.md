# 青果鸿蒙项目

先阅读 `README-MIGRATION.md`、`handoff/AGENT_HANDOFF.md` 和 `handoff/BUSINESS_PARITY_AUDIT.md`，再检查当前工作区与 Git 状态。最新功能包含未提交和未跟踪文件，不能只按 HEAD 还原项目。

- 原生 ArkUI/ArkTS + C++ QuickJS，不是 Flutter/Android 工程。
- 保留名称、功能、数据兼容和当前主题；局部需求不要顺便重新设计。
- 测试：设置 `DEVECO_STUDIO_HOME` 后执行 `node scripts/run-tests.cjs`。
- 构建：`powershell -ExecutionPolicy Bypass -File .\handoff\Build-Project.ps1`。
- `.private-signing/` 包含真实签名及解密材料，不要打印或公开上传，不要覆盖其他机器的全局签名文件。
- 以实际命令输出判断构建/测试状态，不能将 Node/WASM 测试描述为手机实测。
