# DSH 悬浮球热补丁（保留托盘语义版）

## 它解决什么问题

DSH 的「关闭到托盘」走的是 Electron 的 `win.hide()`。`hide()` 会触发 Chromium 的
`WebContents::WasHidden()`，**销毁网页内容子窗口** `Chrome_RenderWidgetHostHWND`。
之后窗口只剩最后一帧旧画面：外部进程无论怎么 `ShowWindow` / 发消息 / 再启动 exe，
都**无法让内容复活**（详见 [PROVENANCE.md 第 13 节](../PROVENANCE.md)）。

唯一能恢复的路径是**让 DSH 自己再调一次 `window.show()`** —— 而这是外部做不到的。

所以本补丁改的是 **DSH 自己**：把 `hideMainWindow()` 从「隐藏窗口」改成
「**移出屏幕 + 收起任务栏图标**」：

| | 原来的 `window.hide()` | 补丁后 |
|---|---|---|
| 窗口可见性 | `WS_VISIBLE` 清除（`IsWindowVisible=false`） | 保持可见，坐标移到 `-32000,-32000` |
| WebContents | **被销毁** → 唤回是死帧 | **保持活跃** → 唤回立刻可用 |
| 任务栏 / Alt-Tab | 不出现 | 不出现（`setSkipTaskbar(true)`） |
| 托盘语义 | 保留 | **保留** |

补丁同时给窗口加了 `show` 事件处理：窗口重新显示时把位置搬回原位、恢复任务栏图标。

## 先装依赖（只有官方裁决器需要）

本目录**不含 `node_modules`**（仓库里不放依赖）。官方裁决器用到 `@electron/asar`，
如果缺失，`apply-patch.ps1` 会**自动尝试安装**；装不上（离线 / 没有 pnpm）时会**降级为只用自研校验**
并打印明确警告，而不是中止。

想提前装好（推荐，这样官方裁决一定能跑）：

```powershell
cd work\asar-tool
pnpm install --registry https://registry.npmmirror.com
```

没有 pnpm 也可以用 npm：

```powershell
cd work\asar-tool
npm install --registry https://registry.npmmirror.com
```

> 官方裁决是可选的加强项：它会用 Electron 内部同一套 asar 解析器再验一遍包结构。
> 没有它也能打补丁，只是少一道交叉验证。

---

## 怎么用

**前提：DSH 必须完全退出（含右下角托盘图标）。** 原因：`app.asar` 被 DSH 主进程独占锁定，
运行时无法替换（实测 `File.Replace` / `File.WriteAllBytes` 都被拒）。

1. 右键托盘里的 DSH 图标 → 退出（确认任务管理器里没有 `DeepSeek Harness.exe`）
2. 双击 `apply-patch.cmd`（或手动运行下面的命令）
3. 启动 DSH，把窗口关闭到托盘，单击悬浮球 —— 应当**立刻可用**

命令行用法：

```powershell
# 看状态（可以在 DSH 运行时执行）
powershell -ExecutionPolicy Bypass -File .\apply-patch.ps1 -Action Status

# 打补丁（需要 DSH 已退出）
powershell -ExecutionPolicy Bypass -File .\apply-patch.ps1 -Action Apply

# 回滚
powershell -ExecutionPolicy Bypass -File .\apply-patch.ps1 -Action Rollback

# 只校验当前 app.asar 结构是否完好
powershell -ExecutionPolicy Bypass -File .\apply-patch.ps1 -Action Verify
```

## ⚠️ DSH 更新后会失效

本机 DSH 走 **nightly** 更新通道，每次更新都会**覆盖 `app.asar`**。
更新后请重新运行 `-Action Apply`（`Status` 会明确告诉你当前是否已打补丁）。
如果 DSH 升级后 `hideMainWindow` 的代码结构变了，`gen-patch.cjs` 会因为找不到锚点而报错并中止
（不会产生破坏性结果）。

## 安全设计

打补丁是一个**五步、每步都可验证**的过程，任何一步失败都不会改动你的安装：

1. **备份**：把当前 `app.asar` 复制到 `backup/app.asar.original`，并记录 SHA256
2. **提取**：从 asar 中取出 `lib/main.js`
3. **改写**：只替换 `hideMainWindow` 函数体（找不到锚点就报错退出）
4. **重打包**：按 asar 的真实格式重新打包（数据区**无对齐**、`offset` 严格累加）
5. **严格验证**（关键）：再打开新包，逐个文件比对
   - 结构：`headerSize` / `dataStart` / 数据区跨度一致、无越界、无间隙
   - 完整性：**全部 11470 个 non-unpacked 文件的 SHA256 与 header 里的 `integrity` 自洽**
   - 差异：与原包逐文件比对，**只允许 `lib/main.js` 一个文件不同**
   - 另外对改写后的文件做 `node --check` 语法检查

只有以上全部通过才会替换文件；否则中止且不修改任何东西。

## 🔴 血泪教训：为什么"自己的校验全过"仍然让 DSH 起不来

2026-10-15 第一次尝试时，我自研的校验器报告"结构完整、integrity 全自洽、只有 `lib/main.js` 变化"，
但装上去之后 **DSH 只剩下 Electron 默认欢迎页**（说明 Electron 找不到有效 app），
用户只能重装 DSH 才恢复。

事后用**官方 `@electron/asar` 解析器**当裁判，才发现三处 asar 格式细节全错了 ——
它们都能骗过我自研的校验器（因为它按我写的格式去读，自然"自洽"）：

| # | 我写错的 | 原始包的做法 | 官方解析器的报错 |
|---|---|---|---|
| 1 | 16 字节 **Pickle 头**只写了第 4 个字段，前三个是 `0` | 四个字段全有值：`04 000000 \| headerSize+8 \| headerSize+4 \| headerSize` | `Attempt to access memory outside buffer bounds` |
| 2 | `integrity` 对**小文件**只写 `{algorithm, hash}` | 大文件小文件一律 `{algorithm, hash, blockSize:4194304, blocks:[...]}`（小块就是单元素数组） | `"integrity.blockSize" must be a positive number` |
| 3 | header JSON 尾部**加了 2 字节 0 padding** | `headerString.length === headerSize`，尾部不能有多余字节 | `Unexpected non-whitespace character after JSON at position ...` |

**现在的防线**：`Apply` 在替换前会用官方解析器做第二轮裁决
（`work/asar-tool/check-official.cjs`），必须打印出"官方解析器完全接受这个包"才允许替换；
通不过就中止且不动任何文件。这三类错误以后不可能再溜过去。

**另一个教训**：`extractFile` 只抽查 `package.json` / `lib/main.js` 是不够的 ——
Electron 还会做深度校验。可靠的判据是官方解析器**能完整读完 header 并成功提取入口文件**。

## 目录说明

```
patch/
├── apply-patch.cmd        # 双击入口（自动等待 DSH 退出）
├── run-apply.ps1          # cmd 调用的中文交互脚本
├── rollback.cmd           # ★ 应急回滚双击入口（DSH 起不来时用它）
├── run-rollback.ps1       # rollback 的实现
├── apply-patch.ps1        # 主工具：Status / Apply / Rollback / Verify
├── gen-patch.cjs          # 生成改写后的 lib/main.js（含锚点检查）
├── extract-main.cjs       # 从 asar 提取指定文件
├── repack2.cjs            # asar 重打包器（已修正 Pickle 头 / integrity / padding）
├── verify-asar.cjs        # 自研严格校验器（含 Pickle 头校验）
├── check-official.cjs     # 官方解析器裁决（必须通过）
├── backup/
│   ├── app.asar           # 规范名的原始包
│   ├── app.asar.original  # 同一份备份（回滚脚本用它）
│   ├── app.asar.dsh-original
│   └── app.asar.unpacked  # → 指向安装目录 unpacked 的 junction（供官方工具解包用）
└── work/                  # 中间产物 + asar-tool（官方 @electron/asar）
```
```

## 验证记录（本机实测）

- **无修改重打包**能逐字节复现原包：12967 个条目标目一致、11470 个 integrity 全部自洽、
  `内容不同=0`、文件大小完全相同 —— 证明打包器正确（见 `work/` 里的验证输出）
- **补丁包**验证：`内容不同=1`（仅 `lib/main.js`）、`integrity 自洽=11470`、`越界文件=0`、
  改写后的 `main.js` 通过 `node --check`
- 补丁前后 `lib/main.js`：490173 → 491685 字节

## 性能说明（实测，已优化）

早期版本的校验慢，根因有两个，都已修掉：

| 问题 | 原耗时 | 修复后 |
|---|---|---|
| 逐文件**随机读**整个数据区（11470 次 `fs.readSync` + 每次新分配 1MB 缓冲） | 2.8s | **0.33s**（顺序读 + 复用 8MB 缓冲） |
| 把 3MB 的 asar header JSON **整块回显**到控制台 | 观感上的主要卡顿 | 只输出摘要 |

现在各动作实测：`Status` **0.72s**、`Verify`（校验 11470 个 SHA256）**0.54s**、
单文件操作（读 header + 读 `lib/main.js` + 算哈希）**66ms**。

`verify-asar.slow.cjs` 是原先的随机读版本，仅作对照保留，正常用不到。

## 已知取舍

- 这**不是**官方支持的改法：它直接修改了 DSH 的应用包，**会被更新覆盖**，且官方明确把
  Desktop 内部实现列为不属于第三方契约的部分。风险自负，但有一键回滚。
- 补丁后窗口在「关闭到托盘」状态下坐标是 `-32000,-32000`。悬浮球通过
  `GetWindowRect` + 虚拟屏幕范围判断这种状态（见插件脚本里的 `IsOffscreen`）。
- 若 DSH 之后自己改成用 `minimize()` 或别的隐藏方式，本补丁的锚点会失配并安全中止。
