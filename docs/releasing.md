# 通用发布流程

适用于 Sonuvi 的 Apple Silicon DMG 正式版（默认轻量版；可选完整离线包）。版本号采用 `x.y.z`，从 DMG 内的 `Info.plist` 读取，不依赖安装包文件名。

## 每次更新怎么做

1. 修改应用版本和 `CHANGELOG.md`，完成构建、测试与源码提交。确认用于构建的源码已经推送 GitHub，记录完整提交 SHA。
2. 生成 DMG 时加 `--prepare-release --source-ref <对应源码提交>`。工具准备发布文件，不访问 GitHub。
3. 检查生成的 `dist/releases/v版本号/release-notes.md` 与 `release.json`。
4. 双击仓库根目录的 **发布到GitHub.command**。默认选择已准备的最高版本；会上传附件、校验、发布，然后更新 README。

官网使用固定地址，无需随版本改动：

```text
https://github.com/davidai1024/Sonuvi/releases/latest/download/Sonuvi-Mac-Offline.dmg
```

已有登录会复用。此工具是维护者的发布工具，不是用户端自动更新功能。

## 已有 DMG：直接准备

```bash
python3 scripts/release.py prepare '/absolute/path/to/new-package.dmg' \
  --source-ref '<与安装包对应的完整40位源码提交SHA>'

# 只校验准备结果，不登录、不上传
python3 scripts/release.py publish --check-only

# 发布已准备的最高版本；与双击入口等效
python3 scripts/release.py publish
```

准备时会校验 DMG 与应用签名，检查语音分发配置、许可证、源码归档；轻量版还会执行原生签名目录验证，读取实际版本、构建号、最低系统要求和音色数量，复制安装包并计算 SHA-256。最低系统要求取应用和语音环境两者中较高者。

新的打包命令指定 `--source-ref` 后，会同时生成 `安装包.dmg.release-build.json`，从实际装入 DMG 的应用读取信息，并绑定 DMG 的 SHA-256。准备时优先校验并使用这份本机打包记录，无需再次挂载 DMG；记录与文件或源码不一致时停止。它是受信任的本机构建记录，不是公证或加密签名证明，请与 DMG 一起保留，不要手工修改。没有记录的旧包会只读挂载检查，需要在允许挂载磁盘映像的 macOS 环境运行。

`--source-ref` 必须由构建者确认。工具会检查该提交在 GitHub 存在、已有版本标签是否一致，但不会声称能从编译后二进制反推出源码提交。不要用“当前最新提交”替代实际构建来源。

更新说明默认提取 `CHANGELOG.md` 对应的 `## x.y.z` 小节。也可用 `--notes '/path/to/changes.md'` 提供本次更新内容；工具自动补上下载、安装、校验和源码链接。相同版本已准备成功后会复用原结果；若需要修订未发布说明，可删除该版本的本地准备目录，再使用同一安装包重新准备。已公开版本不能用于重新发布不同安装包。

## 打包时一起准备

```bash
.packaging-venv/bin/python Tools/build_dmg.py \
  --app "$PWD/build-offline/Sonuvi.app" \
  --output "$PWD/dist/Sonuvi-Mac-Offline.dmg" \
  --workdir "$PWD/dmg-work" \
  --prepare-release \
  --source-ref '<对应构建的完整40位源码提交SHA>'
```

可附加 `--release-notes '/path/to/changes.md'`。打包和准备都不会执行远程发布。

## 首次环境配置

需要 macOS、Python 3.9+、官方 [GitHub CLI](https://cli.github.com/)。运行 `gh auth login --hostname github.com --web` 登录具有该仓库写入权限的账号，之后复用登录。发布工具不读取或打印 Token，不会把网络错误当成登录失效而反复授权。

默认从 PATH 查找 `gh`；如需使用其他本机位置，在仓库根目录创建已被 Git 忽略的 `.release-local.json`：

```json
{
  "gh_path": "/absolute/path/to/gh",
  "gh_config_dir": "/absolute/path/to/gh-config"
}
```

路径也可相对于仓库根目录。没有自定义配置目录时，省略 `gh_config_dir`，沿用官方 CLI 的默认登录配置。此文件只放路径，不要填写密码或 Token。

如果本机默认 macOS SDK 与 Swift 编译器版本不匹配，可在 `.release-local.json` 添加 `sdk_path`，指向已安装且与编译器匹配的 SDK 目录。`build.sh` 在未显式设置 `SDKROOT` 时自动读取该路径；独立运行打包或签名辅助程序前，也应将 `SDKROOT` 设置为该路径。此配置仅作用于当前发布环境，不修改系统默认开发工具。

## 发布过程及保护

- **版本自动识别**：不硬编码版本、大小、校验值或 README 原始 SHA。
- **草稿按 ID 查询**：从认证后的发布列表查找草稿，避免尚无 Git 标签时出现 404。
- **先上传后公开**：安装包及 `SHA256SUMS.txt` 均经 GitHub 返回的 SHA-256 与大小校验后才发布。
- **重试跳过已完成附件**：上传成功的附件不会重复传。中断的单个文件需要重新上传，不提供字节级断点续传。
- **同版本保护**：已公开附件不覆盖；草稿中的同名不同内容也会停止。只允许清理未完成的 `starter` 附件后重传。
- **避免降级与并行冲突**：不把低版本设为最新版；同一准备目录有本机锁；发布前再次核对是否已有更新版本。
- **保护 README**：从线上最新内容开始，只更新 `sonuvi-download` 标记区和版本徽章，用文件 SHA 检测并发修改，不覆盖其他段落。
- **固定下载地址**：公开后检查最新版身份、HTTP 下载响应与文件大小，成功后才更新 README。
- **源码对应**：发布时绑定显式源码 SHA，不移动已有标签；检查轻量和带注释标签的最终提交。

`dist/releases/v版本号/publish-result.json` 只在所有步骤完成后写入。若上传成功、后续网络校验失败，重新运行即可；不要删除远程附件或创建同版本第二份发布。

`dist/`、安装包、本机 CLI 配置与登录信息不提交 Git。此流程不会自动构建或测试产品，不替代真实设备验证、Developer ID 签名或公证。

## 指定版本或其他准备目录

```bash
python3 scripts/release.py publish --manifest '/path/to/v1.2.3/release.json'
python3 scripts/release.py prepare '/path/to/package.dmg' --source-ref '<40位SHA>' --output '/path/to/releases'
python3 scripts/release.py publish --directory '/path/to/releases'
```

## 验证发布工具

```bash
python3 -m unittest discover -s Tests -p 'test_release.py' -v
```

测试使用临时文件与模拟 GitHub，覆盖草稿恢复、上传失败、公开包保护、下载失败重试、版本排序与降级防护、标签源码冲突，以及 README 的并发编辑保护；不会创建真实发布。
