<div align="center">

<img src="docs/assets/app-icon.png" width="112" alt="Sonuvi icon" />

# Sonuvi

### 划词即译，自然朗读。

一款为 macOS 打造的中英划词翻译与本地英文朗读工具。<br />
读懂眼前的文字，也听见它自然的声音。

![macOS](https://img.shields.io/badge/macOS-13%2B-111111?style=flat-square&logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-555555?style=flat-square)
![Version](https://img.shields.io/badge/version-0.4.3-6b7280?style=flat-square)
![License](https://img.shields.io/badge/license-GPL--3.0-111111?style=flat-square)

[功能](#读译听在当前场景完成) · [开始使用](#开始使用) · [快捷键](#常用快捷键) · [源码构建](#从源码构建) · [致谢](#开源致谢)

</div>

---

## 少一次切换，多一点专注

在浏览器、文档或其他应用里遇到不认识的英文，选中它，查看中文释义；想知道一句中文用英语怎么说，选中它，得到英文表达。需要听发音时，直接播放。

Sonuvi 把这几个动作放在文字旁边：**翻译交给 DeepSeek，英文朗读交给本机的 Kokoro 82M。**

> 当前为个人使用的早期版本。应用使用 ad-hoc 签名，尚未公证，也未提供自动更新；跨应用取词能力取决于目标应用是否开放相应接口。

## 读、译、听，在当前场景完成

| 能力 | 体验 |
| :--- | :--- |
| **跨应用划词** | 选中文字后显示翻译、朗读入口，也支持全局快捷键。 |
| **中英自动互译** | 中文译成英文，英文译成中文，无需每次切换方向。 |
| **单词与句子分开呈现** | 单词、短语展示释义、词性、音标和例句；句子展示流式译文。 |
| **自然英文朗读** | Kokoro 82M 在 Apple Silicon Mac 上运行，支持五种美音／英音音色与 0.5–2 倍语速。 |
| **轻量播放浮条** | 跨应用朗读不打开翻译窗口；浮条可拖动、可停止，播放结束自动收起。 |
| **窗口内朗读** | 在翻译窗口播放时，点阵和停止按钮直接出现在窗口底部。 |
| **声音驱动的点阵** | 朗读状态读取播放器实时音量，随语音起伏变化。 |
| **截图翻译** | 主动框选区域后，在本机 OCR，再发送识别文字进行翻译。 |
| **系统文本服务** | 支持的应用可通过右键 → 服务调用翻译和朗读。 |
| **复制与编辑** | 原文、译文、例句支持复制；原文支持常用编辑快捷键和自适应高度。 |
| **原生 macOS 界面** | 深浅色、可调整窗口、菜单栏入口；macOS 26 使用原生液态玻璃，旧系统使用原生材质。 |
| **本地使用统计** | 查看翻译、朗读、词数、活跃记录与成就进度。 |

## 开始使用

### 1. 准备应用

当前仓库提供完整源码，可按下方步骤构建。生成的 `Sonuvi.app` 建议放入「应用程序」，并始终从同一路径运行。

**系统要求：Apple Silicon Mac，macOS 13 或更高版本。**

### 2. 配置翻译

打开 **设置 → 模型**，填写自己的 DeepSeek API Key。Key 保存在 macOS 钥匙串，翻译需要网络以及有效的 API 额度。

默认模型为 `deepseek-flash`，关闭思考并流式返回；可在设置中修改模型名称，具体可用性以 API 账号为准。

### 3. 准备本地朗读

在 **设置 → 模型** 下载独立 Kokoro 环境，或导入已经安装的 Speak11 环境。完成准备后，英文朗读可以离线使用。

模型、Python 运行环境与依赖按需安装，**没有打包进应用源码**。首次准备建议至少预留 **2.5 GB** 空间；下载需要访问 Python、PyPI 和模型托管服务。实际占用会随依赖、缓存变化。

### 4. 开启需要的权限

| 权限 | 用途 |
| :--- | :--- |
| 辅助功能 | 跨应用读取你主动选中的文字。 |
| 屏幕录制 | 仅在你主动发起截图翻译时截取指定区域。 |

在 **设置 → 通用** 按需授权。已授权项目显示状态，不再显示授权按钮。ad-hoc 签名的应用升级后，系统可能要求重新授权。

## 常用快捷键

以下为初始默认值，可在 **设置 → 快捷键** 修改；已有配置以应用内显示为准。

| 操作 | 快捷键 |
| :--- | :--- |
| 翻译选中文字 | <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>T</kbd> |
| 朗读选区／再次按下停止 | <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>R</kbd> |
| 截图翻译 | <kbd>Control</kbd> + <kbd>Option</kbd> + <kbd>O</kbd> |
| 在翻译窗口发起翻译 | <kbd>Command</kbd> + <kbd>Return</kbd> |
| 隐藏翻译窗口 | <kbd>Command</kbd> + <kbd>W</kbd> |

**中文选区朗读**会先联网翻译成英文，再使用本地模型朗读；目前本地语音模型仅支持英文。

## 两条清楚的数据路径

| 操作 | 数据如何处理 |
| :--- | :--- |
| 选中文字 | 本机显示操作入口；仅选中不会发起翻译请求。 |
| 主动翻译 | 原文发送至 DeepSeek 官方 API。 |
| 英文朗读 | 环境准备完成后，在本机合成和播放。 |
| 截图翻译 | 本机识别文字，再发送识别文字至 DeepSeek。 |
| 使用统计 | 本机保存聚合计数，不上传统计记录。 |
| API Key | 存储于 macOS 钥匙串。 |

AI 生成的释义、音标和例句可能有误。对准确性要求较高时，请结合权威词典或原始资料核对。

## 从源码构建

需要 Apple Silicon Mac 与支持 macOS 26 SDK 的 Xcode Command Line Tools／Xcode。构建产物的最低运行系统为 macOS 13。

```bash
git clone https://github.com/davidai1024/Sonuvi.git
cd Sonuvi

# 编译应用
bash build.sh

# 构建产物
open build
```

构建脚本会编译 Swift 源码、复制资源、签名并运行核心检查。默认使用 ad-hoc 签名。首次构建会从 Astral 官方 GitHub Release 下载固定版本 `uv 0.12.5`；已有 `Resources/uv` 时直接复用。许可证随源码提供，**构建应用时无需下载语音模型**。

如需在多次构建间使用固定的本机签名身份：

```bash
MUSE_SIGNING_IDENTITY="你的代码签名身份" bash build.sh
```

更多操作说明见 [使用说明](docs/使用说明.txt)。

## 源码导览

| 目录／文件 | 内容 |
| :--- | :--- |
| `Sources/TranslateView.swift` | 紧凑翻译界面与词典卡片。 |
| `Sources/Selection.swift` | 跨应用取词。 |
| `Sources/SpeechPlayback.swift` | 原生音频播放与实时音量。 |
| `Sources/ReadingBar.swift` | 可拖动朗读浮条。 |
| `Sources/FlowingDots.swift` | 统计与朗读中的点阵表现。 |
| `Sources/Runtime.swift` | 本地语音环境管理。 |
| `Resources/*.py` | Kokoro 服务、桥接与环境准备。 |
| `Tests/` | 核心、编辑、OCR、网络和语音桥接检查。 |
| `build.sh` | 本机构建入口。 |

## 开源致谢

Sonuvi 使用 SwiftUI 与 AppKit 独立实现界面和取词流程。它受以下项目启发，也使用了其中注明的代码或组件：

- **[Easydict](https://github.com/tisfeng/Easydict)**：翻译提示词复用并修改，词典／句子流程与紧凑查询布局参考。GPL-3.0。
- **[Speak11](https://github.com/smcantab/speak11)**：本地自然朗读的参考项目，支持导入用户现有环境；完成独立环境准备后不再依赖 Speak11。
- **[Kokoro 82M](https://huggingface.co/hexgrad/Kokoro-82M)** 与 **[MLX conversion](https://huggingface.co/mlx-community/Kokoro-82M-bf16)**：本地英文语音合成。
- **[uv](https://github.com/astral-sh/uv)**：Python 环境准备。MIT OR Apache-2.0。

上游来源、固定版本与许可证边界详见 [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt)。Sonuvi 不是 Easydict 或 Speak11 的官方发行版。

---

<div align="center">

**让阅读更连贯，让语言更自然。**

源代码采用 [GPL-3.0](LICENSE) 许可。

</div>
