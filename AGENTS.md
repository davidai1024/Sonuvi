# Sonuvi 构建与发布

- 本机固定自签名证书已经建立。签名配置位于 `.release-local.json` 的 `signing_profile` 字段；只读取路径，不打印其中的口令、私钥或完整配置。
- 证书 SHA-1 指纹为 `12218F15EF84E0024157830D4E5DC6936A44807D`。私钥丢失、身份不可用或指纹改变时必须停止发布，不能自动重新生成证书。
- `build.sh` 会在配置存在时使用固定身份。添加或更改 App 内资源之后，使用 `python3 Tools/sign_code.py APP_OR_HELPER_PATH...` 重新签名；禁止在打包阶段用 `codesign --sign -` 覆盖固定签名。
- 正式构建设置 `SONUVI_REQUIRE_FIXED_SIGNING=1`。普通无配置开发构建仍可使用临时签名；`SONUVI_PREVIEW=1` 的预览包保持隔离身份，不注册生产 Services。
- 不要降低签名身份校验、把要求改成仅 Bundle ID、关闭 Gatekeeper/SIP、清空 TCC，或修改整个系统的证书信任。
- 钥匙串已用两版不同程序验证：同证书新版可静默读取旧版的测试凭据，临时签名对照组被拒绝。
- 2026-10-22 在本机 macOS 26.6.2 完成独立测试 App 的真实权限升级验证：用户首次授权并重启后，同路径替换为同证书、不同二进制的 V2；辅助功能及屏幕录制授权均保留，实际读取配套测试窗口标题及 1 像素截图成功，V2 显式授权请求次数为 0。记录在工作目录 `tcc-upgrade-result.json`，测试源码为 `Tools/PrivacyUpgradeFixture.swift`。
- 上述结论只覆盖本机固定签名到固定签名的升级；不代表旧临时签名迁移、其他 macOS 或 Gatekeeper 的首次安装验证已经通过。禁止据此清空 TCC 或承诺所有用户永不需要重新授权。
- 本规则建立于 0.4.29 发布后；该公开版本使用原临时签名。后续公开状态须另查 Releases。本次固定签名验证阶段不替换已发布资源；采用新身份时需要明确标记迁移版本。
- 0.4.30 起使用 Sparkle 2.10.0；下载源与 SHA-256 固定在 `Tools/prepare_sparkle.py`。保留框架官方签名、符号链接和随包许可证；不要对整个 App 使用 `codesign --deep --sign -`。
- 更新公钥位于 `Resources/UpdatePublicKey.txt`；私钥路径在本机 `.release-local.json` 的 `update_signing_key` 字段。私钥不可提交、打印或自动重新生成。只有首次建立未发布身份时才使用 `Tools/GenerateUpdateKey.swift`。
- 每次发布必须运行 `Tools/package_app_updates.py`，验证两版 App 固定签名，签署并校验两份 DMG 和两份 appcast。先上传且核对 GitHub 附件，再更新官网的 `updates/appcast.xml` 与 `updates/appcast-full.xml`；部署后核对线上文件字节/签名。不要手改已签名 appcast。
- 更新只替换 App，不能删除 Application Support 下的语音资源、用户配置或钥匙串项目。固定签名构建不自动重置 TCC；迁移旧临时签名可能需要用户首次重新授权。
- 0.4.31 的 `SigningPermissionMigration` 记录实际证书摘要，区分签名迁移与普通换包。历史请求标记只在身份首次变化且相应权限不可用时清理；它们不是 macOS 授权证明。迁移只提示恢复，不自动执行 TCC 清理。
- 系统开关开启但实际授权失效时，使用权限页或引导的「修复旧授权记录」。它在用户点击后只重置实际不可用的服务，仍严格限定生产 Bundle ID，并重启返回；不得扩大为每次更新自动清空两项权限。
