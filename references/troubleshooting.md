# 微信多开：排错与补充说明

本文件只在主流程失败或需要判断边界情况时读取。

## 1. 核心原理

macOS 通过 `CFBundleIdentifier` 区分 App。直接复制 WeChat.app 而不改 Bundle ID，副本会和原版共用同一个沙盒容器（`~/Library/Containers/com.tencent.xinWeChat`），导致数据串号甚至互相踢下线。因此每个副本必须：

1. 拥有唯一 Bundle ID：`com.tencent.xinWeChat2`、`com.tencent.xinWeChat3`……
2. 修改 `CFBundleName` / `CFBundleDisplayName` 便于区分；
3. 修改后原签名失效，必须 ad-hoc 重签：`codesign --force --deep --sign - <app>`；
4. 用 `open <app>` 启动，不要用 `nohup ... &`。

## 2. 常见失败与处理

### `/Applications is not writable`

本机 sudo 不可用，方案**故意不依赖 sudo**。`ls -ld /Applications` 正常应为 `drwxrwxr-x root admin`，当前用户需在 admin 组。

- 若当前用户不在 admin 组：改用 `~/Applications` 作为目标目录，把脚本里的 `/Applications` 路径替换掉；但 LaunchServices 对 `~/Applications` 的识别稍弱，需手动从 Finder 打开一次。
- 不要试图用 `sudo` 绕过；这台机器上 sudo 会失败。

### `source app not found`

用下面命令定位真实路径，再通过 `--source` 传入：

```bash
mdfind "kMDItemCFBundleIdentifier == 'com.tencent.xinWeChat'"
```

若微信是从 App Store 安装或放在 `~/Applications`，路径会不同。

### `ERROR: <app> exists but its Bundle ID is 'com.tencent.xinWeChat'`

说明目标槽位被一个"假分身"占用了——只复制、没改 Bundle ID。典型名字是 `微信_2.app`、`WeChat 2.app`。

- **不要删除或强退它**：里面可能有未发出的消息。
- 先向用户报告，询问是保留它作为其中一个号，还是用户自己清理后再重跑。
- 若用户确认保留，改用更大的槽位号（脚本自动尝试 2..12），或手动改名后再执行。

### 副本启动后闪退

按顺序排查：

1. 签名校验：`codesign --verify --deep --strict <app>`，无输出即通过。
2. 隔离属性：`xattr -dr com.apple.quarantine <app>` 后重开。
3. 版本不匹配：`--list` 查看副本版本号，若低于当前微信版本，删除该槽位重建。
4. 权限弹窗：ad-hoc 重签会丢掉原版的沙盒 entitlement，麦克风/相机/通知等可能要重新授权。

### 升级微信后分身失效

副本不会跟随 App Store 自动升级。处理：升级原版微信 → 删除旧的 `WeChatN.app` → 重跑脚本。脚本对版本不一致的已有槽位会打印 WARNING，但不会自作主张删除。

### 账号被要求重新验证 / 被踢下线

多开本身常见，但可能触发平台风控。建议：

- 不要在分身里做批量群发、营销自动化；
- 不要在同一 IP 下频繁切换大量账号；
- 出现风险提示时停止使用分身，改用官方客户端。

## 3. Windows 用户怎么办

本脚本是 macOS 专属，Windows 不适用。可告知用户 Windows 官方没有多开能力，常见做法是：

- 使用微信自带的"切换账号"（不能同时在线）；
- 使用第三方多开工具（存在账号安全风险，不推荐）；
- 使用 Windows 沙盒 / 虚拟机安装第二套微信（资源开销大）。

不要向 Windows 用户承诺本脚本可用。

## 4. 手动兜底流程（脚本不可用时使用）

```bash
cp -R /Applications/WeChat.app /Applications/WeChat2.app
xattr -dr com.apple.quarantine /Applications/WeChat2.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.tencent.xinWeChat2" /Applications/WeChat2.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleName 微信分身2" /Applications/WeChat2.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 微信分身2" /Applications/WeChat2.app/Contents/Info.plist
codesign --force --deep --sign - /Applications/WeChat2.app
codesign --verify --deep --strict /Applications/WeChat2.app
open /Applications/WeChat2.app
```

三开、四开只需把上面所有 `2` 递增为 `3`、`4`。

## 5. 绝对禁止

- 未经明确许可结束任何正在运行的微信进程；
- 覆盖已存在但 Bundle ID 不符的 App；
- 把账号密码、二维码、登录凭证写进 Skill 或日志；
- 对 Windows 用户运行此脚本。
