# Sonuvi 0.4.14 — Chrome 划词与设置交互

## Chrome 兼容性

已知反馈：M2 MacBook Air、8 GB、macOS 26.6.2，OA 可划词而 Chrome 网页均无菜单。设备满足安装包的要求；还不能仅凭截图确认现场根因。

本版补足此前只针对 Electron 的初始化路径：
- 已知 Chromium 浏览器通过 AXEnhancedUserInterface 请求提供网页辅助功能数据，Electron 保留 AXManualAccessibility。
- 切换到允许显示划词菜单的应用时提前初始化，仅在已有辅助功能授权时执行。
- Chrome 首次激活可能延迟约 2 秒；浏览器专用重试窗口覆盖该延迟，已有选区读到后立即返回。
- 支持 AXSelectedTextMarkerRange / AXStringForTextMarkerRange，以读取跨节点选区。
- 浏览器最多检查 8 层祖先，每轮 AX 读取仍保留超时限制；不扫描整棵应用树，不轮询或自动复制剪贴板。
- 新选择、切换应用、关闭划词或取消操作仍会使旧请求失效。

依据：Chromium 源码 chrome/browser/chrome_browser_application_mac.mm 与 content/browser/accessibility/browser_accessibility_cocoa.mm。
https://chromium.googlesource.com/chromium/src/+/refs/heads/main/chrome/browser/chrome_browser_application_mac.mm

上述路径通过策略与回归检查，尚未在反馈者的 Mac / Chrome 版本上实测。更新后请在“通用 → 各应用的划词菜单”确认 Chrome 为开启；如果仍失败，需提供 Chrome 版本继续定位。

## 默认快捷键

- 翻译：Option + Shift + T
- 朗读／停止：Option + Shift + S
- 截图翻译：Option + Shift + R

新安装使用这些默认值；已有自定义快捷键保留，可点击“恢复默认”切换。

## 快捷键录制

录制时显示高亮背景、2 pt 描边、“按下组合键…”及明确的状态提示；实时显示组合键，松开保存。按 Esc、点击外部或焦点离开时取消。输入缺少修饰键时给出提示，录制期间暂停应用全局快捷键，避免录制时误触发。

## 各应用的划词菜单

替换原“应用例外”的反向表达：开表示显示，关表示隐藏。底层已有排除配置原样保留，仅转换 UI 语义；修改即时保存。快捷键不受影响。全局开关关闭时显示说明，非运行应用的开关在当前设置会话中保持可见。
