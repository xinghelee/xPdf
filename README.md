# xPdf

基于 SwiftUI + PDFKit 的原生 macOS PDF 阅读与编辑工具。

## 功能

**阅读**
- 侧边栏：页面缩略图、文档目录（书签）、搜索结果
- 全文搜索，结果列表高亮关键词，点击跳转
- 缩放（适合窗口 / 实际大小 / 预设比例）
- 单页、单页连续、双页、双页连续四种显示方式
- 打开加密 PDF（输入密码解锁）、打印

**页面编辑**
- 旋转、删除页面，支持多选
- 在缩略图中拖动调整页面顺序
- 插入其他 PDF 或图片（可用于合并文件），也可直接把文件拖进窗口
- 插入空白页
- 将所选页面导出为新的 PDF 或 PNG 图片

**批注**
- 高亮、下划线、删除线：选中工具后划选文字即自动添加，可选颜色
- 文字批注
- 画笔手绘，可调颜色与粗细；橡皮擦点击或拖过即可删除批注
- 手写签名：一次书写、保存后重复使用，点击页面放置
- 手绘与签名可拖动移动，拖右下角等比缩放
- 右键菜单可删除批注或对选中文字添加标记

**文字识别（OCR）**
- 识别扫描件和图片中的中文、英文、日文、韩文，基于系统 Vision 框架，完全离线
- 在页面中加入隐藏文字层，识别后可搜索、选择、拷贝，页面外观不变
- 可选当前页、所选页面或全部页面，默认跳过本身已有文字的页面；显示进度，可中途停止
- 打开扫描件时提示条一键开始识别；整次识别可撤销

**表单**
- 直接填写 PDF 中的文本框、复选框、单选框和下拉框，Tab 键切换字段
- 打开带表单的文档时显示提示条，可一键清除表单内容
- 填写内容支持撤销，并随文档一起保存

所有编辑都支持撤销 / 重做，并直接保存回 PDF 文件。手绘和签名以标准 Ink 批注（矢量）写入，在其他 PDF 阅读器中同样可见。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 放大 / 缩小 / 实际大小 / 适合窗口 | ⌘= / ⌘- / ⌘0 / ⌘9 |
| 上一页 / 下一页 | ⌥⌘↑ / ⌥⌘↓ |
| 向左 / 向右旋转页面 | ⌘L / ⌘R |
| 删除所选页面 | ⌘⌫ |
| 插入文件中的页面 / 插入空白页 | ⇧⌘I / ⇧⌘B |
| 切换批注工具（选择、高亮、下划线、删除线、画笔、橡皮擦） | ⌃⌘1 – ⌃⌘6 |
| 添加文字批注 | ⌥⌘T |
| 新建签名 | ⌥⌘S |
| 识别文字（OCR） | ⇧⌘O |
| 取消放置签名 | Esc |
| 打印 | ⌘P |

## 构建

**环境要求**
- macOS 15 或更高版本
- Xcode 16 或更高版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（仅在修改工程配置或增删文件时需要）

**使用 Xcode**

```sh
git clone git@github.com:xinghelee/xPdf.git
cd xPdf
open xPdf.xcodeproj
```

然后在 Xcode 中按 ⌘R 运行。

**命令行**

```sh
xcodebuild -project xPdf.xcodeproj -scheme xPdf -configuration Release -derivedDataPath build build
open build/Build/Products/Release/xPdf.app
```

**重新生成工程**

`xPdf.xcodeproj` 由 `project.yml` 生成。新增、删除源文件或修改构建设置后，运行：

```sh
brew install xcodegen   # 首次
xcodegen generate
```

默认使用本地临时签名（Sign to Run Locally），只能在本机运行。如需分发，请在 `project.yml` 中配置你的开发团队与签名证书。

## 项目结构

```
xPdf/
├── XPdfApp.swift      # 应用入口（DocumentGroup）
├── PDFFile.swift      # PDF 文档的读取与保存
├── ViewerModel.swift  # 核心逻辑：页面操作、批注、搜索、撤销
├── PDFKitView.swift   # PDFView 封装：划词标记、手绘、橡皮擦、签名放置、拖动/缩放、右键菜单
├── ContentView.swift  # 主界面与工具栏
├── SidebarView.swift  # 侧边栏：缩略图、目录、搜索结果
├── Signature.swift    # 签名数据、本地存储与手写面板
├── OCR.swift          # 文字识别引擎：渲染、Vision 识别、生成带隐藏文字层的页面
├── OCRSheet.swift     # 文字识别面板与扫描件提示条
└── Commands.swift     # 菜单栏命令与快捷键
```

签名保存在应用沙盒内的 `~/Library/Containers/com.xinghelee.xPdf/Data/Library/Application Support/xPdf/signatures.json`。

## 已知限制

- 签名仅支持手写，暂不支持打字或导入图片签名（PDFKit 保存时不会保留自定义绘制的图片批注）
- 不支持修改 PDF 中原有的文字
- 不支持创建新的表单字段，只能填写已有字段
- 系统 PDFKit 会对显示过的扫描页自动做一次识别（质量较低，中文字之间会带空格），保存时这层文字也会写入文件，且没有公开接口可以关闭。xPdf 的 OCR 不受影响：判断页面是否已有文字、生成文字层时都使用未经 PDFKit 处理的原始页面
