<p align="center">
  <img src="assets/icon.png" alt="Mac微信多开助理" width="180" />
</p>

# Mac微信多开助理

在 macOS 上为**本人合法持有**的多个微信账号创建相互隔离的独立应用实例（双开 / 三开 / 四开）的 WorkBuddy Skill。

> 全程本地操作：不修改微信客户端代码、不拦截网络请求、不破解协议、不绕过官方风控。仅适用于用户本人合法持有并有权使用的账号，不用于批量营销、骚扰或规避平台限制。

## 原理

macOS 以 `CFBundleIdentifier` 区分应用。直接复制微信而不改 Bundle ID，副本会和原版共用同一个数据容器，导致串号。本 Skill 为每个副本设置唯一 Bundle ID（`com.tencent.xinWeChat2`、`...3`……）与显示名，重新做 ad-hoc 签名，并校验签名与数据目录隔离。

## 环境要求

- macOS（Apple Silicon / Intel 均可），微信已安装在 `/Applications/WeChat.app`
- 当前用户对 `/Applications` 有写权限（admin 组即可）
- **不需要 sudo**；脚本设计上刻意不依赖管理员密码

## 用法（让 Agent 执行）

安装为 WorkBuddy Skill 后，直接说：

- 「帮我微信双开」
- 「在这台 Mac 上开三个微信窗口，分别登不同账号」
- 「检查一下我已经建了几个微信实例，有没有冲突的」
- 「微信升级了，我的多开副本还能用吗」

Agent 会按 SKILL.md 的流程：检查现状 → 预览 → 创建 → 校验 → 交付。

## 手动运行脚本

```bash
# 查看现状（副本、Bundle ID、进程、冲突副本）
bash scripts/wechat_multi_open.sh --list

# 预览计划，不改动任何东西
bash scripts/wechat_multi_open.sh --total 2 --dry-run

# 双开（总数 2 = 原版 + 1 个副本）
bash scripts/wechat_multi_open.sh --total 2

# 三开 / 四开
bash scripts/wechat_multi_open.sh --total 3
bash scripts/wechat_multi_open.sh --total 4
```

`--total` 表示期望的同时在线实例总数（含原版）；脚本自动尝试槽位 `WeChat2.app` 到 `WeChat12.app`，遇到 Bundle ID 不符的现有目录会拒绝覆盖并退出。

## 目录结构

```
.
├── SKILL.md                        # Agent 执行说明
├── manifest.json                   # SkillHub 发布清单
├── scripts/wechat_multi_open.sh    # 预检/创建/校验/启动一体化脚本
└── references/troubleshooting.md   # 排错与合规说明
```

## 已知限制

- 副本不随原版自动升级；微信升级后需删除旧副本重建（脚本会提示版本不一致）。
- ad-hoc 签名会丢失原版沙盒 entitlement，麦克风 / 相机 / 通知等权限可能需要重新授权。
- 多开可能触发平台安全验证；出现风险提示时请停止使用副本，改用官方客户端。
- Windows 不适用。

## 发布信息

- SkillHub code：`wechat-multi-open-assistant`
- 显示名称：Mac微信多开助理
- 版本：`0.1.0`

## 许可

MIT
