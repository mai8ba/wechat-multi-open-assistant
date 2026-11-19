---
name: wechat-multi-open-assistant
description: 在 macOS 上为个人合法持有的多个微信账号创建相互独立的本地应用实例（双开/三开/四开），通过唯一 Bundle ID 与本地签名实现数据隔离，并提供预检、互不影响的多实例管理、校验与排错。适用于需要在同一台 Mac 上同时使用自己名下多个微信账号的场景。当用户提到「微信多开」「微信双开」「微信分身」「微信三开」「微信四开」「多个微信号同时登录」「在 Mac 上再开一个微信」等表述时使用本技能。仅限 macOS，仅限用户本人合法持有并有权使用的账号；不破解客户端协议、不绕过平台风控、不用于批量营销或骚扰。
agent_created: true
---

# Mac微信多开助理

## 概述

在 macOS 上把已安装的微信客户端复制为若干独立应用实例，每个实例拥有独立的 Bundle ID 和数据容器，从而可以同时登录多个**本人合法持有**的微信账号。所有操作均在本地完成，无需管理员密码，不修改微信客户端代码、不拦截网络请求、不绕过官方风控。

## 使用边界（每次触发前先确认）

- 仅适用于 macOS。Windows 用户不适用，直接说明并停止，不要尝试运行脚本。
- 仅用于用户本人合法持有并有权使用的多个账号。不要协助批量注册、批量营销、骚扰或规避平台风控。
- 绝不结束任何正在运行的微信进程，除非用户明确要求；可能有未发出的消息。
- 绝不覆盖 Bundle ID 不符的现有 App；先报告并征求用户意见。
- 不把账号、二维码、登录凭证写入任何文件或日志。

## 工作流程

### 1. 确认目标数量

把用户说法映射为脚本参数：`双开` → `--total 2`，`三开` → `--total 3`，`四开` → `--total 4`。未说明时默认 `--total 2`。`--total` 表示期望的同时在线实例总数（含原版），脚本负责创建 `总数 - 1` 个副本。

### 2. 检查现状

在技能目录下运行：

```bash
bash scripts/wechat_multi_open.sh --list
```

向用户报告已有副本、各自的 Bundle ID、运行中的 PID，以及是否存在 Bundle ID 与原版冲突的"假副本"。若发现冲突副本（例如 `微信_2.app` 仍使用 `com.tencent.xinWeChat`），只报告、不处理，询问用户希望保留还是重建。

### 3. 预览计划（建议首次执行时做）

```bash
bash scripts/wechat_multi_open.sh --total N --dry-run
```

### 4. 执行创建

```bash
bash scripts/wechat_multi_open.sh --total N
```

脚本对每个副本依次执行：复制 App → 移除隔离属性 → 设置唯一 `CFBundleIdentifier` / `CFBundleName` / `CFBundleDisplayName` → ad-hoc 重签名 → 严格签名校验 → 启动。遇到槽位已存在但 Bundle ID 不符时会拒绝覆盖并退出。

### 5. 验证并交付

脚本会输出验证表。确认以下内容后向用户交付：

- 每个副本的 Bundle ID 依次为 `com.tencent.xinWeChat2`、`com.tencent.xinWeChat3`……
- 每个副本有运行中的 PID（若用户选择不启动则跳过此项）；
- 数据容器互相隔离（`~/Library/Containers/com.tencent.xinWeChatN`）。

若原版微信未运行，提示用户自行打开；不要替用户结束任何进程。提示用户在每个副本中用另一个账号扫码登录。

## 失败处理

读取 `references/troubleshooting.md`，其中覆盖：`/Applications` 不可写、找不到源 App、副本闪退、签名报错、假副本冲突、微信升级后重建、Windows 替代方案，以及手动兜底命令。

## 已知限制与风险提示

- 副本不会随原版自动升级。微信升级后需删除旧副本并重建；脚本对版本不一致的槽位会打印 WARNING，但不会自作主张删除。
- ad-hoc 签名会丢失原版的沙盒 entitlement，麦克风、相机、通知等权限可能需要重新授权。
- 多开可能触发平台安全验证。出现风险提示时应停止使用副本，改用官方客户端。不要把本技能用于批量群发或营销自动化。

## 资源

- `scripts/wechat_multi_open.sh` — 预检、创建、校验、启动一体化脚本。
- `references/troubleshooting.md` — 排错与合规说明，仅在失败或边界情况时读取。
