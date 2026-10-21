# 本地语音资源独立更新

默认 App 不包含 Python、MLX 或模型权重。首次下载一个完整、可迁移的语音资源包；已有 `MuseTranslate/Voice` 安装会复用。资源的 `sequence` 与 App 版本独立递增。首次使用或更新均由用户在引导或模型页主动选择，自动检查不会自动下载大文件。

## 发布资源

1. 按 `packaging.md` 准备 `BundledVoice`。确认 macOS 14 二进制、28 个音色、许可证及资源 manifest 均正确。只有模型或运行环境变化时才发布新资源，不要为普通 App 更新重新打包资源。
2. 使用 Python 3.12 生成固定版本资源和目录 payload：

```bash
python3 scripts/package_voice_download.py \
  --source /path/to/BundledVoice \
  --output /path/to/Sonuvi-Voice-arm64-v2.tar.gz \
  --catalog /path/to/payload.json --sequence 2
```

3. 使用原有发布私钥签名，并核对它与 App 内公钥一致。私钥不提交 Git，也不分发给用户。不要用新生成的私钥替换已有更新通道。

```bash
swift Tools/SignVoiceCatalog.swift /secure/path/catalog-signing.key \
  /path/to/payload.json /path/to/latest.json Resources/VoicePublicKey.txt
```

4. 在同一官方 GitHub 仓库发布 `voice-kokoro-en-v2`，上传对应固定文件名，验证大小与 SHA256。资源 Release 必须标记为 prerelease，发布时设置 `make_latest=false`，不能占用 App 的 latest 下载入口。
5. 资源公开后，将签名目录同步到 App 源码的 `Resources/VoiceCatalog.json`（供后续 App 作为离线目录回退）以及官网仓库的 `sonuvi/dist/voice/latest.json`。官网目录设置 `Cache-Control: no-store`，经 GitHub Actions 发布到腾讯云；验证线上 JSON 和部署提交。
6. 模型、模型协议、依赖或操作系统要求不兼容时，提高 `minimumAppVersion` / `minimumMacOS`。客户端不会降级到低于已安装 generation 的资源，也不会在不兼容平台上安装。

## 客户端流程

目录 Ed25519 签名 → HTTPS 下载（可取消及续传）→ 大小和 SHA256 → 解压前校验路径与成员类型 → 内容及环境验证 → `ready.json` 原子切换 → 清理旧 generation。

资源在应用支持目录中，不修改已签名 App。取消、验证失败和子进程失败均保留旧的 ready marker。已安装模型不会随 App 替换而被删除。只处理模型和运行环境，不更新 App 本体，也不替用户授予系统权限。

## 验证

`--voice-package-test` 使用合成签名覆盖目录篡改、错误来源、兼容性、哈希和路径校验。附加 `--voice-test-archive ARCHIVE DESTINATION` 可验证真实资源的完整解压。

`Tests/verify_offline_voice.py` 在独立临时目录中安装资源并离线合成全部 28 个音色。`--voice-runtime-test` 仅能在带专用 `/tmp/sv22-` 根目录的 preview bundle 中运行，用于完整首次安装和取消更新保留旧模型的回归检查。测试不访问 API Key 或真实模型目录。
