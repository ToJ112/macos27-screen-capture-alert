# 验证记录与结论边界

日期：2026-10-19。以下是去除用户名、个人路径、游戏内容和原始截图后的验证摘要。

## 环境

- macOS 27.0.1，build 26A434，Apple silicon。
- `profiles status -type enrollment`：DEP No，MDM enrollment No。
- REA 6.7.0，Rizin 0.9.1；只读分析本机 `/usr/libexec/replayd` 的 arm64e 切片。
- 原始系统二进制 SHA-256：`471218d0849d6f177bf62036d2d7e2aca89ea4333b7398d9b72d3b1cb3ee1e2b`。
- 本仓库不分发 Apple 二进制、完整反汇编或个人日志。

## 静态观察

| 方法 | 本机 arm64e 地址 | 观察 |
| --- | --- | --- |
| `SCAlertStatsManager requireAlertWithCanonicalBundleID:auditToken:` | `0x100004b18` | 返回状态先初始化为要求提醒；身份解析失败时不进入日期比较路径 |
| 日期比较 block | `0x100004d00` | 正常路径使用最近使用时间与 2,592,000 秒比较 |
| `RPFeatureFlagUtility screenCaptureAlertEnabled` | `0x100048814` | 该版本直接返回 true |
| `RPClient hasAlertDefaultOverrideEnabled` | `0x10006bcb0` | 普通隐藏偏好受内部安全策略条件限制 |
| `RPClient hasMDMBypassProfile` | `0x10006bd9c` | 要求 `CFPreferencesAppValueIsForced`，再要求偏好为有效 true；本方法未直接查询入网状态 |
| `SCAlert userAcknowledgementAlertWithBundleID:` | `0x100033424` | 构造所讨论的系统弹窗 |

这些地址属于这一份二进制；不能拿去修改其他系统版本，也不是补丁偏移。

## 运行时观察

安装前的一次复现：

1. 短命的截图客户端先退出。
2. 稍后系统身份/权限核验报 `No such process`。
3. `replayd` 报 `Error resolving binary path and audit token`。
4. 随后调用弹窗构造函数。

这是同一事件的日志与静态分支相互印证，并非对所有历史事件的证明。把磁盘提醒日期改到未来、单独重启服务都未排除这条失败路径。

## 本地强制策略试验

用户在 macOS 系统窗口完成管理员授权后，新建当前用户的 root 所有、0644 管理偏好，设置 `forceBypassScreenCaptureAlert=true`。

CoreFoundation 读取结果：

```json
{"forced":true,"value":true,"valid":true,"effective":true}
```

在没有在途输入/截图的边界刷新 `replayd` 后，用实际项目原有截图入口连续截图三次，全部成功。约 34 秒的日志窗口中：

```json
{
  "successful_capture_tests": 3,
  "policy_bypass_log_entries": 6,
  "acknowledgement_alert_constructor_calls": 0,
  "acknowledgement_responses": 0,
  "identity_resolution_errors": 0,
  "mdm_enrolled": false,
  "whole_application_restarted": false,
  "replayd_restarted": true
}
```

跳过分支的内部日志文本是 `client has MDM profile`。它描述内部判断结果，本次机器没有被加入 MDM。旧的定时改日期试验随后停用，其辅助程序的完全磁盘访问权限也已撤销。

## 尚未证明

- 整机重启、注销/重新登录、升级后的持续效果。
- 其他 macOS 27.x 版本、Intel、macOS 26/15 的适用性。
- 所有应用、所有弹窗都经过同一段代码。
- “永远有效”的承诺。

原型只处理一个空白目标文件。本仓库的通用安装器另加了备份、恢复、摘要冲突检查和版本检查；这些通用文件操作通过临时目录测试，未在生产系统反复安装/卸载。

参考：[REA](https://github.com/morluto/rea)、[Apple Restrictions](https://developer.apple.com/documentation/devicemanagement/restrictions)。
