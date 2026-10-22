# 0.4.33 划词兼容修复

## 诊断

当前用户安装 0.4.32，划词开启，排除列表为空。0.4.32 仅新增更新提醒，没有修改选区读取逻辑；不能据此把本次问题归因为签名或系统授权。

本机微信 4.1.15（com.tencent.xinWeChat）在前台仅暴露窗口、标准窗口按钮等少数 AX 节点，没有可用的焦点选区。ChatGPT 新版（com.openai.codex）使用 Codex Framework 内的 Chromium，引擎未被原有浏览器名单及 Electron 文件检测覆盖。Chrome 已在专用兼容名单内。

## 行为

- ChatGPT Chromium 版本加入已有 Chromium 激活策略和最长约三秒的首次就绪重试；Electron 版本仍优先使用 Electron 策略。
- 所有读取仍只检查命中元素、焦点元素和最多八层父级；不扫描整个聊天树，不把完整控件内容当作选区。
- 微信及 ChatGPT 的选区读取失败时，在真实鼠标划词或明确的键盘选区手势后保留原样的小菜单。点击翻译或朗读后，复用显式取词路径；仅当直接读取失败才模拟复制，保留并恢复剪贴板格式。显示菜单本身不会复制或翻译。
- 前台 PID 在点击时再次校验；关闭复制取词、关闭划词、排除应用、进行截图、未完成引导、检测到密码框或请求已取消时，不启用后备路径。
- 不重置 macOS 权限，不改 API Key、本地模型或签名身份。

## 验证边界

真实微信、ChatGPT 前台通过生产手势处理函数验证菜单出现、保持焦点、剪贴板不变、关闭/排除开关和过期 PID 拦截。手势由测试程序构造，未读取或发送用户聊天内容；这不是对用户实际聊天文字拖选到翻译的完整验收。

独立不提供 AX 选区的测试控件和专用测试剪贴板模拟延迟 700ms 返回长选区，用原生菜单按钮点击验证复制取词及多格式剪贴板恢复，不改动用户的通用剪贴板。已有状态、键盘选区、取消、密码框、长选区和 Chrome 兼容测试继续执行。具体结果记录在工作目录测试日志。

## 参考

- Chromium 的 AXEnhancedUserInterface 激活逻辑：https://chromium.googlesource.com/chromium/src/+/main/content/browser/accessibility/browser_accessibility_state_impl_mac.mm
- Apple 的选区属性：https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute

当前进度：109 项核心检查、80 项选区回归及 17 项真实应用菜单流程已通过。首次复制测试因按钮尚未可访问失败；已改为等待布局后原生点击，并切换专用测试剪贴板。修改后的点击取词验证尚待解锁 Mac 执行，不应据此宣称完整链路已经通过，0.4.33 暂不发布。
