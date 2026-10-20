# macOS 27 屏幕捕获提醒屏蔽脚本

[English](README.en.md) · [验证与原理](docs/verification.md)

关闭这类已经授权录屏后仍可能重复出现的系统提醒：

> “某应用”正在请求绕过系统无痕浏览窗口选择器，直接访问屏幕和音频。

**适用于 macOS 27；目前仅在 macOS 27.0.1（26A434）、Apple 芯片、未加入 MDM 的 Mac 上实测。** 其他 27.x 版本尚待验证。脚本默认拒绝其他大版本，也不声称已经验证“永久、任何升级后都不会再弹”。

这不是删除系统组件或篡改签名。它为指定用户写入一项本地强制偏好，让系统 `replayd` 走已有的跳过提醒分支。

## 作用范围

- 关闭**所选用户下所有应用**的这类屏幕捕获提醒，不能只针对某一个应用。
- 不授予屏幕录制权限；应用仍需要原有的“屏幕与系统音频录制”授权。
- 不隐藏菜单栏录屏指示器，不关闭其他隐私提示。
- 不加入 MDM，不关闭 SIP，不修改 TCC 数据库，不修改系统二进制。
- 不安装后台服务、不定时改日期、不联网。管理员权限只用于写入/撤销本地偏好和备份。
- 已加入 MDM/DEP 的机器会被拒绝；这类机器应由管理员下发正式策略。

这是利用本地管理偏好的实测方法，**不是 Apple 对个人 Mac 承诺支持的设置界面**。系统更新、其他管理程序重写偏好或删除该文件都可能改变效果。

## 要求

- macOS 27、普通本地用户、管理员授权。
- 脚本只使用 macOS 自带 Bash、`plutil`、`PlistBuddy` 和 JXA/CoreFoundation，无需安装 Python、Homebrew、REA 或 Xcode。
- 在 Terminal 中进入下载/解压后的项目目录。建议先阅读脚本；不要把远程脚本直接管道交给 `sudo` 执行。

## 安装

先预览和检查：

```bash
bash ./screen-capture-alert.sh plan
bash ./screen-capture-alert.sh status
```

确认作用范围后安装：

```bash
sudo bash ./screen-capture-alert.sh install
```

默认选择运行 `sudo` 的原用户。要明确选择用户：

```bash
sudo bash ./screen-capture-alert.sh install --user YOUR_SHORT_USERNAME
```

写入位置：

```text
/Library/Managed Preferences/<用户名>/com.apple.applicationaccess.plist
    forceBypassScreenCaptureAlert = true
```

若原文件已有其他偏好，脚本先保留完整备份，再只改变这个键；恢复原文件时保留原文件权限和组。备份和安装摘要位于：

```text
/var/db/macos27-screen-capture-alert/<用户 UID>/
```

如果发现该键已经由其他方式设为 `true`，脚本会报告现状并不接管它，也不会创建撤销凭据。

## 验证生效

**以目标用户、不加 sudo** 运行：

```bash
bash ./screen-capture-alert.sh status
```

应得到：

```json
{"forced":true,"value":true,"valid":true,"effective":true}
```

仅看到 plist 里的 `true` 不够；`forced` 也必须是 `true`。状态检查读取 CoreFoundation 的有效偏好，而不是只读磁盘文件。

如果正在运行的系统服务仍使用旧设置，先停止录屏/屏幕共享和依赖截图的自动操作，再执行：

```bash
bash ./screen-capture-alert.sh refresh
```

这会向当前用户的 `replayd` 发 HUP，**可能中断正在进行的屏幕捕获/屏幕共享**；安装和卸载均不会自动执行这一步。通常无需退出 ChatGPT 或其他整个应用。

然后用你实际使用的应用截图或共享屏幕。可辅助查看本次系统日志：

```bash
/usr/bin/log show --last 2m --style compact \
  --predicate 'process == "replayd" AND (eventMessage CONTAINS "client has MDM profile" OR eventMessage CONTAINS "userAcknowledgementAlertWithBundleID")'
```

`client has MDM profile` 是此分支内部使用的日志文本；出现它**不代表**机器被本脚本加入 MDM。可另运行 `profiles status -type enrollment` 核验。

## 撤销

```bash
sudo bash ./screen-capture-alert.sh uninstall
# 停止所有捕获工作后，再按需刷新：
bash ./screen-capture-alert.sh refresh
bash ./screen-capture-alert.sh status
```

卸载只在当前偏好文件与安装时保存的摘要一致时进行：原来有文件则原样恢复；原来没有文件则移除本次新建的文件。备份会保留为 `.removed-<时间>-<进程号>` 目录。

如果提示文件后来被改过，脚本不会覆盖，也不会删除备份。请比较原始备份和现有偏好，手动合并需要恢复的键。外部方式安装的策略也不会被本脚本擅自删除。

如果安装中断后留下锁或不完整凭据，先确认没有安装/卸载进程还在运行，再检查备份与目标文件；不要盲删备份后反复安装。

## 为什么改未来日期不一定有效

本次调查观察到：短命的 `screencapture` 进程退出后，`replayd` 才继续核验其身份，出现 `No such process` / `Error resolving binary path and audit token`。身份解析失败分支直接要求弹窗，绕过正常日期判断，因此即使提醒日期仍在未来也可能再次弹出。

静态分析还发现，本机版本的策略关闭分支检查的是 `CFPreferencesAppValueIsForced` 和有效的 `true` 值，并没有在这个方法里直接查询 MDM 入网状态。本地 root 所有的管理偏好在本机满足了该条件。

这解释了本次复现，不意味着所有机器、所有历史提醒都由同一个问题引起。完整证据边界见[验证说明](docs/verification.md)。

## 已验证与未验证

| 项目 | 结果 |
| --- | --- |
| macOS 27.0.1 / 26A434 / Apple 芯片 | 已实测 |
| CoreFoundation 有效强制偏好 | `forced/value/valid` 全为 `true` |
| 刷新 `replayd` 后真实应用截图 | 连续 3 次成功 |
| 测试窗口系统日志 | 6 次策略跳过分支；0 次弹窗构造函数调用 |
| MDM 入网 | 未加入，安装前后均为 No |
| 退出/重开整个应用 | 本次不需要 |
| 完整系统重启、系统升级后 | 尚未验证 |
| 其他 27.x、Intel、macOS 26/15 | 尚未验证 |

其他大版本研究用途可显式添加 `--allow-untested`；它只解除版本检查，不代表兼容性承诺，也不会绕过 MDM、文件冲突或权限检查。

## 测试与许可证

开发测试需要 Python 3，仅在临时目录测试偏好写入/恢复，不修改系统策略、不发送 HUP：

```bash
python3 -m unittest discover -s tests -v
bash -n screen-capture-alert.sh
```

MIT License。逆向分析使用 [REA](https://github.com/morluto/rea) 与 Rizin；它们不是运行本脚本的依赖。Apple 官方的受管理设备策略参考：[Restrictions](https://developer.apple.com/documentation/devicemanagement/restrictions)。
