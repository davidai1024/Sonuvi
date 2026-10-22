# 应用内更新

从 0.4.30 开始，菜单栏与设置 → 通用提供「检查更新」。默认每天检查一次，后台发现更新时只在产品内提示；用户点击后才下载，并选择安装和重新打开。可在设置中关闭自动检查。

0.4.29 及更早的 App 不含更新器，需要从官网手动安装 0.4.30 一次。此次从临时签名迁移到固定自签名，macOS 可能要求重新确认系统权限或 API Key 访问。固定自签名不等同 Apple Developer ID 或公证，首次安装安全提示仍按系统流程处理。

轻量版使用 `https://sonuvi.davidai1024.com/updates/appcast.xml`，完整朗读版使用 `appcast-full.xml`。两个列表分别指向 GitHub Releases 的版本固定 DMG，不会让轻量版被动下载完整语音包。完整朗读版更新使用完整 DMG。已准备的语音资源位于 Application Support，更新仅替换 App。

## 构建与签名

`build.sh` 自动准备固定 SHA-256 的官方 Sparkle 2.10.0，保留框架签名与符号链接。默认更新间隔 86400 秒，不自动静默下载或安装。App 内嵌更新公钥，要求更新列表签名，并在解压前验证归档签名。私钥只存维护者本机，不上传网站或代码仓库。

正式构建必须设置 `SONUVI_REQUIRE_FIXED_SIGNING=1`。更新包改动后使用 `Tools/sign_code.py` 重新固定签名；打包阶段不能改用临时签名。预览包不启动更新器。

## 发布

先完成源码提交、构建和两版 DMG。随后运行：

```sh
python3 Tools/package_app_updates.py \
  --light-app /absolute/path/light/Sonuvi.app \
  --full-app /absolute/path/full/Sonuvi.app \
  --light-dmg /absolute/path/Sonuvi-Mac.dmg \
  --full-dmg /absolute/path/Sonuvi-Mac-Offline.dmg \
  --notes /absolute/path/release-notes.txt \
  --output /absolute/path/prepared-updates
```

工具从包内读取版本、构建号与最低系统要求，验证固定签名、公钥和双版本配置。使用本机现有私钥签署 DMG，并生成、签署及复核两个 appcast。缺失密钥必须停止，不能生成替代身份。

先上传并验证 GitHub Release 的安装包，再把生成的 XML 原样复制到官网 `sonuvi/dist/updates/`，提交到网站仓库 main 触发腾讯云部署。签名后不能格式化或修改 XML。部署完成后，验证对应 deployment 文件，并逐字节核对线上 XML 与本机签署文件，再复核安装包大小及签名。

## 实测

`python3 Tools/test_app_updates.py` 使用隔离 bundle ID、临时目录、固定签名和 Sparkle 的真实安装器验证：正常下载/替换/重启、模型标记保留、篡改安装包拒绝、篡改 appcast 拒绝及已是最新版。不修改正式 Sonuvi、不重置 TCC、不读取真实 API Key。

固定自签名升级的钥匙串、辅助功能和屏幕录制已在维护者 macOS 26.6.2 单机实测；不能据此承诺所有系统或旧临时签名迁移均无需重新授权。
