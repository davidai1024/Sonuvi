# 构建轻量应用与语音资源

默认发布轻量应用，语音资源的独立打包和签名见 [模型更新](model-updates.md)。可选的完整离线包与轻量应用的区别在于是否包含 `Contents/Resources/BundledVoice`。源码仓库不提交模型、Python 运行环境、API Key 或用户数据。

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

## 可选：构建内置模型的应用

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
  --output "$PWD/dist/Sonuvi-Mac-v0.4.22-Offline.dmg" \
  --workdir "$PWD/dmg-work"
```

DMG 内包含应用、Applications 链接、拖拽安装背景、首次打开修复脚本与说明。修复脚本在应用完成最终签名后生成，自动固定该应用的版本和主程序 SHA256；生成后不要再修改或重签应用，否则应重新打包。脚本以真实 Finder 文件图标出现在安装窗口下方，并带有工具图标和隐藏扩展名。替换已安装应用由 Finder 的原生对话框处理。打包脚本会校验 DMG 完整性；分享前还需验证应用签名、断网朗读和目标设备兼容性。

若分发 GPL 应用二进制，请一并提供与构建对应的完整源码及所需许可证。第三方资源的许可边界见仓库根目录 `THIRD_PARTY_NOTICES.txt`。

## 准备并发布到 GitHub

打包命令可附加 `--prepare-release --source-ref '<对应源码的完整提交 SHA>'`，自动从 DMG 读取版本并准备发布文件。随后双击仓库根目录的 **发布到GitHub.command**。已有 DMG 也可单独准备，详见 [通用发布流程](releasing.md)。

首次打开修复工具本身也可能被 Gatekeeper 拦截。终端运行测试应使用独立测试应用，附加下载隔离标记后，以 `/bin/zsh` 运行脚本并传入 `--app` 和 `--no-open`，确认标记清除且未启动应用。该测试不代表浏览器下载后可直接双击通过。正式分发仍需 Developer ID 签名和公证。

## 同版本双安装包

官网同时提供 `Sonuvi-Mac.dmg`（轻量版）与 `Sonuvi-Mac-Offline.dmg`（完整朗读版）。两者须使用同一版本的应用代码；完整包加入 `BundledVoice` 并设置 `SonuviIncludesVoice=true` 后重新签名。`build.sh` 已通过 `SONUVI_BUNDLED_VOICE` 支持完整包构建。安装背景、使用说明和首次打开修复工具会根据该标记选择相应文案和下载地址。

为已发布的版本追加完整包时，保留原轻量包，上传完整包，并更新包含两个文件的 `SHA256SUMS.txt`；不要用单包发布流程替换该版本。确认完整包的首次离线准备与 28 个音色可用后，再发布官网双下载入口。轻量版的本地朗读模型按需下载免费，翻译 API 费用另计。
