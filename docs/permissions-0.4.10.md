# Sonuvi 0.4.10 · 权限流程修复

## 修复范围
- 记住授权来自设置还是新手引导。授权返回或重新启动后，恢复对应页面及设置分组。
- 修复设置中的“重启并检查”错误地进入新手引导的问题；迁移旧版遗留标记。
- 授权前启动一个限时重启助手，覆盖系统“退出并重新打开”流程。
- 主动重启先等待助手就绪；助手失败时应用保持打开并显示错误。
- 重启助手等待旧进程结束，再通过 LaunchServices 打开原应用；已存在新进程时不重复启动。
- 翻译读取 API Key 使用不允许交互的钥匙串调用。需要授权时显示应用内提示，只有用户在模型设置中点击“授权访问”才允许系统弹窗。
- 成功读取的 Key 仅在进程内复用；不会改为明文磁盘存储，也不会扩大钥匙串访问控制。
- 修复 Key 删除失败仍显示已删除的问题。

## 签名限制
当前环境没有可用的代码签名证书，本包仍为 ad-hoc 签名。固定 Bundle ID 不等于固定代码身份。跨版本更新后，macOS 仍可能要求重新授权辅助功能、屏幕录制或钥匙串。此项尚不能承诺消除。
后续应使用同一 Developer ID Application 身份签署应用和助手。构建脚本保留 MUSE_SIGNING_IDENTITY 入口。
不得通过重置权限数据库、放宽 designated requirement 或取消钥匙串 ACL 解决。

Apple 参考：
https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
https://developer.apple.com/documentation/security/seckeychainsetuserinteractionallowed(_:)

## 验证
- 101 项核心检查通过，包含新增权限来源持久化、过期清理、授权拒绝及会话缓存测试。
- 29 项划词回归检查通过。
- 实际重启测试：助手就绪前不退出；旧进程退出后打开测试应用；取消后不重开；权限监视模式正常重开。
- LaunchServices 原生测试应用退出后恰好重开一次。
- 不使用真实 API Key，不修改用户的系统权限。
- 尚未在用户 MacBook Air 上手工复现系统授权对话框全流程。

## 安装
本更新包沿用已有本地模型，不包含模型副本。先退出旧 Sonuvi，再把 Sonuvi.app 拖到“应用程序”替换，随后从“应用程序”启动。
不要使用清理工具删除 ~/Library/Application Support/MuseTranslate 或重置 Sonuvi 的权限。
如翻译提示钥匙串访问未授权，前往设置 → 模型 → 授权访问；在系统弹窗选择 Always Allow（始终允许）可让系统记住当前构建的访问许可。
