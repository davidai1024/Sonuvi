# 构建与完整离线包

基础源码应用与完整离线包的区别在于是否包含 `Contents/Resources/BundledVoice`。源码仓库不提交模型、Python 运行环境、API Key 或用户数据。

## 基础应用

```bash
bash scripts/prepare-uv.sh
bash build.sh
```

输出为 `build/Sonuvi.app`。需要 Apple Silicon 和支持 macOS 26 SDK 的构建工具。基础界面部署目标为 macOS 13，捆绑的 MLX 运行环境要求 macOS 14.0+。

## 准备离线资源

使用 Python 3.12 执行资源打包脚本。前提是已经有可正常朗读、包含 `ready.json` 的独立 Sonuvi 语音目录。脚本会校验运行环境与模型都位于该目录内，拒绝依赖外部 Python 的虚拟环境，不会自动从零下载模型。

```bash
python3 scripts/package_voice.py \
  --source-root '/absolute/path/to/owned/Voice' \
  --destination '/absolute/path/to/BundledVoice'
```

目标目录必须不存在。资源包括固定版本 Kokoro 权重、28 个英文音色、独立运行环境、依赖清单与许可证。`ready.json` 中的绝对路径只用于构建输入，不应作为用户数据提交到 Git。

MLX 0.32.4 为不同 macOS 版本提供了多个二进制发行包。必须安装文件名带 `macosx_14_0_arm64` 的 `mlx` 和 `mlx-metal`，不能让当前系统自动选择 `macosx_26_0_arm64`。已固定的官方下载地址与 SHA256 见 `Resources/runtime_setup.py` 的 `MLX_WHEELS`。不要只修改 manifest 或 Info.plist 中的系统版本。

打包前执行 `python3 Resources/runtime_compat.py '/absolute/path/to/runtime' --minimum 14.0`。打包脚本、应用构建和发布检查均会读取每个 arm64 Mach-O 的实际部署版本，拒绝高于声明版本的原生依赖。

在有 GPU 的 Mac 上执行 `python3 Tests/verify_offline_voice.py --bundle '/absolute/path/to/BundledVoice' --report '/tmp/sonuvi-voice-check.json'`，验证隔离目录安装、断网推理和 28 个音色。macOS 14、15 真机回归需另行进行，不能用新系统测试代替。

## 构建内置模型的应用

```bash
SONUVI_BUNDLED_VOICE='/absolute/path/to/BundledVoice' \
MUSE_BUILD_DIR="$PWD/build-offline" \
bash build.sh
```

使用全新的构建目录。脚本会把最低系统要求设为 macOS 14.0，加入内置语音标记，签名并执行核心检查。可通过 `MUSE_SIGNING_IDENTITY` 指定已有的代码签名身份；默认仍是 ad-hoc，不能替代 Developer ID 签名和公证。

## 生成 DMG

用单独的打包环境安装 `ds_store==1.3.3` 和 `mac_alias==2.2.3`，不要把打包依赖装入已经签名的语音运行环境。

```bash
python3 -m venv .packaging-venv
.packaging-venv/bin/pip install ds_store==1.3.3 mac_alias==2.2.3
.packaging-venv/bin/python Tools/build_dmg.py \
  --app "$PWD/build-offline/Sonuvi.app" \
  --output "$PWD/dist/Sonuvi-Mac-v0.4.19-Offline.dmg" \
  --workdir "$PWD/dmg-work"
```

DMG 内包含应用、Applications 链接、拖拽安装背景与说明。替换已安装应用由 Finder 的原生对话框处理。打包脚本会校验 DMG 完整性；分享前还需验证应用签名、断网朗读和目标设备兼容性。

若分发 GPL 应用二进制，请一并提供与构建对应的完整源码及所需许可证。第三方资源的许可边界见仓库根目录 `THIRD_PARTY_NOTICES.txt`。

## 准备并发布到 GitHub

打包命令可附加 `--prepare-release --source-ref '<对应源码的完整提交 SHA>'`，自动从 DMG 读取版本并准备发布文件。随后双击仓库根目录的 **发布到GitHub.command**。已有 DMG 也可单独准备，详见 [通用发布流程](releasing.md)。
