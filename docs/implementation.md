# Q2C 实现说明

## 当前运行路径

`Main.swift` 创建菜单栏入口和设置弹窗；`AssistantModel` 管理配置、异步复制、防重复和转交任务。`SystemSelection` 只发送来源复制事件及观察版本，`CopiedContent` 只保存版本和时间，不保存载荷。

`ShortcutInteraction` 冻结目标选择，按有效标星优先顺序呈现，支持触发键切换、松键确认和鼠标选择。`PickerClickGuard` 只在目标浮层期间过滤外部取消点击；`AppDelegate` 另为设置弹窗提供外部点击/失活关闭监听，关闭即清理。

`CodexClipboardPaster` 打开线程链接，等待 200ms、检查前台 PID 和剪贴板版本，松键后发送一次原样粘贴。不读取 AX 控件树/输入正文，不输入头尾，不自动发送。

`ShortcutRecorder` 仅在本地控件录制时接收按键；`GlobalShortcut` 注册配置中的全局快捷键。构建本身不注册快捷键，应用启动时注册。

## 配置、资源与日志

`ConfigurationStore` 保存多配置、备注、标星与快捷键，兼容旧设置。旧头尾字段保留但不转交，旧目录只读迁移；原文件不覆盖。配置和日志位置及权限见 README。

`DiagnosticLog` 记录结构化流程元数据、耗时和原因，按 1MiB 轮换。`Q2CIcon` 自绘图标；资源生成器和构建脚本不引入第三方素材或 Swift 包依赖。

## 构建和验证

```sh
swift test
zsh scripts/build-app.sh
```

测试使用合成目标和模拟复制/粘贴，不向真实任务发送消息。历史 AX 策略、DeliverySession、App Server/proxy 等代码与测试保留作历史实现，不由当前快捷键转交流程调用。

历史开发记录保存在 verification.md；其中旧功能、时序和测试数量不作为当前行为说明。
