# Sonuvi 浏览器右键菜单

支持 Chrome / Edge。在浏览器主右键菜单中增加 **Sonuvi → 翻译所选文字 / 朗读所选文字**，无需进入 macOS 的“服务”子菜单。

首次配置：

1. 安装 Sonuvi 0.4.27 或更高版本，将应用拖入“应用程序”。
2. 打开 Sonuvi → 设置 → 通用 → 浏览器右键菜单，点击“启用连接”。
3. 解压浏览器扩展包。Chrome 打开 `chrome://extensions`，Edge 打开 `edge://extensions`；开启“开发者模式”，点击“加载已解压的扩展程序”，选择含 `manifest.json` 的 `Sonuvi-Browser-Extension` 文件夹。
4. 在网页选中文字，右键 → Sonuvi，选择翻译或朗读。

这是尚未上架商店的开发版扩展，需要首次手动加载一次。扩展文件夹应放在固定位置，加载后不要删除。以后上架商店后可改为商店安装。

扩展仅请求 `contextMenus` 和 `nativeMessaging` 两项权限；不会请求“读取所有网站数据”，不会注入网页脚本，不会读取 API Key。只有你点击右键功能时，选中的文字才会通过本机连接交给 Sonuvi。翻译仍由 Sonuvi 使用你配置的 DeepSeek API；英文朗读使用本地模型。

若扩展图标出现“!”，点击图标查看连接提示；确认已安装最新 Sonuvi 并在设置中启用连接后，点击“重新检测”。

# Sonuvi browser context menu

Chrome / Edge: install Sonuvi 0.4.27+, move it to Applications, and enable the browser connection in Settings → General. Extract the extension archive, open `chrome://extensions` or `edge://extensions`, enable Developer mode, and load the extracted `Sonuvi-Browser-Extension` folder.

Select text, right-click → Sonuvi → Translate Selected Text / Read Selected Text. This development extension is not yet in the extension store. It requests only context menu and native messaging permissions, accesses no other page contents or API keys, and sends only text you explicitly choose to Sonuvi on this Mac.
