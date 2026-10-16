# PROVENANCE —— 结论是怎么来的

本文记录 `dsh-float-ball` 的**每一条关键设计决定**分别基于什么证据，以及哪些只是推断。
目的：让后来的人（或下一个 agent）能复核、能推翻，而不是继承一堆"看起来对"的假设。

调查发生在 **2026 年、Windows 11 + DSH Desktop（安装于 `<DSH 安装目录>\`）** 的环境上，安装目录下文都记作 `<DSH 安装目录>`。

调查分两段：**前半段**宿主 `pwsh` 在受限沙箱下起不来（`0xC0000142` = `STATUS_DLL_INIT_FAILED`），完全无法执行命令（没有 `node` / `powershell` / `pnpm`），证据只来自「读文件 + 读 asar 文本 + 公开资料」；**后半段**发现把同一条命令放宽到 `danger-full-access` 就能跑（是沙箱导致的进程初始化失败，不是权限拒绝），于是补做了大量实测 —— 见第 6 节及其后的各节。

---

## 1. 环境事实（读盘确认）

| 事项 | 证据 |
|---|---|
| DSH 桌面端安装根目录 | `<DSH 安装目录>\`（含 `DeepSeek Harness.exe`、`resources\`） |
| DSH 运行时在 asar 内 | `resources\app.asar`；native 模块在 `resources\app.asar.unpacked\` |
| 桌面端 profile | `%USERPROFILE%\.dsh\profiles\desktop\`，`package.json` 的 `dsh.profile.bundles` = `["@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","dsh-whale-widget"]` |
| 已装第三方插件实例 | `desktop\node_modules\dsh-whale-widget\`（v0.4.2，含 `package.json` / `cordis.patch.yml` / `lib/index.js` / `assets/`） |
| 应用图标 | `resources\icon.png`，1024×1024 PNG，深色虎鲸标（白底圆角方块）—— 已用图像读取确认 |
| 托盘图标 | `resources\tray.ico` 存在 |

## 2. 插件契约（来自可读的真实插件，不是文档推测）

`dsh-whale-widget\lib\index.js`（4926 行，实际在跑）给出了宿主半区的全部形状：

| 结论 | 证据位置 |
|---|---|
| 插件导出形状 `export default { name, apply(root) }` | 该文件 L723–L731、L4926 |
| 清理用 `root.effect(() => () => { … })` | L4919–L4923、L733 |
| 服务等待用 `root.inject(['webServer', …], (ctx) => { … })` | L749 |
| 可选服务用 `ctx.get('connection')`，**不能**写进 `inject` | L805、L1181–L1189 的显式注释 |
| 路由注册形状 `ctx.webServer.register({ kind: 'exact', path, handler })`，返回 disposer | L876–L885、L3548–L3565 |
| 宿主请求栅栏是 `connection.requestRejection(req)` | L750–L874 的长注释 |
| 桌面端页面注入通道是 `webserver/index-inject` 的结构化行（`tapIndex` 在桌面端无效） | L735–L746、L4903–L4917 的长注释 |
| 包的挂载声明是 `package.json` 的 `dsh.bundle.patch` → `cordis.patch.yml` 里 `- insert: [{ id, name }]` | 该插件 `package.json` L31–L35、`cordis.patch.yml` L13–L15 |

`dsh-float-ball` 只使用上表中标注为公开的部分（bundle patch、`webServer`、可选 `connection` 栅栏）。

## 3. Desktop 内部实现（读 `app.asar` 的文本内容）

`app.asar` 可以被 grep 当文本读（`read` 工具因文件过大失败）。以下行号是 asar 内的文本行号：

| 结论 | 证据 |
|---|---|
| 桌面壳是 Electron 主进程（窗口/托盘/IPC 都在这里） | `import { BrowserWindow, Menu, Notification, Tray, WebContentsView, app, clipboard, dialog, ipcMain, nativeImage, … } from "electron"`；`new Tray(nativeImage.createFromPath(options.iconPath))`；`ipcMain.handle(DESKTOP_IPC.…)` 一大批 |
| 托盘路径解析 | `const trayIconPath = development ? join(app.getAppPath(), "resources", "tray-windows.ico") : join(process.resourcesPath, "tray.ico")`；`const applicationIconPath = … : join(process.resourcesPath, "icon.png")` ← **本插件图标路径的依据** |
| 主窗口确实会"隐藏"（而不是销毁） | `else mainWindow?.hide();`、`if (mainWindow !== void 0 && !mainWindow.isDestroyed()) mainWindow.hide();` |
| 单实例 + 二次启动回调 | `if (!application.requestSingleInstanceLock()) {…}`、`application.on("second-instance", focusOwner);`，JSDoc：`@param focusOwner - focus or recreate the primary window after a later launch.` ← **"单击唤回"的依据** |
| 最小化会被 restore 而不是丢弃 | `if (window.isMinimized()) window.restore();`（两处） |
| 宿主进程是「Electron 可执行文件 + `ELECTRON_RUN_AS_NODE=1`」 | 启动子进程处同时设置 `ELECTRON_RUN_AS_NODE: "1"` 与 `DSH_DESKTOP_NODE_EXECUTABLE: executable`（asar 内 ≥3 处） |
| 宿主进程入口是 `dsh-desktop-host/lib/index.js` | `const entry = join(this.runtimeDir, "node_modules", "@deepseek-ai", "dsh-desktop-host", "lib", "index.js")`，同处一个把 `node / runtimeDir / inspectPort / environment / …` 交给子进程的 launcher 类 |
| 宿主代码在进程外、不受工作区沙箱限制 | DSH 自带文档文本：安装 bundle 会「在宿主进程内运行插件代码」 |
| 官方**明确不保证** `BrowserWindow` 等接口 | 见第 4 节 |

## 4. 官方文档（公开来源）

- [DSH Desktop《插件开发》](https://github.com/anywhere-labs/dsh-desktop/blob/master/docs/plugin-development.md) —— 关键段落：
  - Desktop 只公开两个 Host service：`desktopProfiles`、`desktopPnpm`；
  - **「不要依赖的接口」**：`desktopRuntime`、`desktopPnpmBootstrap`、Electron `BrowserWindow`、托盘注册表、private Node helper、`ELECTRON_RUN_AS_NODE` 和生成的 shim **都是 Desktop 内部实现，不属于第三方兼容 contract**。
  - → 这条直接否决了"插件里 `new BrowserWindow()` 开悬浮窗"的做法，是本插件改用「宿主半区 spawn 自带窗口的进程」的原因。
- 社区同类实现 [`dsh-float-chat`](https://github.com/cyh3436332528/dsh-float-chat)（dsh-market 收录）—— 它的 README 明确写着：
  - 「**A genuinely separate window** — not an overlay painted into the DSH page, but an independent native process」；
  - 「The host half runs inside DSH's Node process」（宿主半区不热重载，改完要重启 DSH；改文件名的原因是 ESM 按路径缓存）；
  - 「The window process inherits the host's environment variables. The only one explicitly removed is `ELECTRON_RUN_AS_NODE`」；
  - 它自带的是 **WinForms + WebView2 的预编译 `.exe`**（还带三个 WebView2 DLL）。
  - → 证明「宿主半区 spawn 独立窗口进程」这条技术路线在真实生态里可用；也说明**为什么它必须随包发二进制**。本插件改成 PowerShell + WPF，就是为了**免编译、不随包发二进制**。
- 生态里另一个名字相近的包 [`dsh-float-window`](https://www.npmjs.com/package/dsh-float-window) 是 **DSH Web 插件用的 React 浮窗外壳组件**（在 DSH 页面内部渲染浮窗），与"托盘后仍存在的桌面级窗口"不是一回事 —— 记在这里避免后来者混淆。

## 5. 推断（未直接证实，已在 README 标注）

| 推断 | 置信度 | 影响 / 兜底 |
|---|---|---|
| 宿主半区**没有** Electron 窗口 API（它是 `ELECTRON_RUN_AS_NODE=1` 的 Node 进程） | 高（启动代码 + dsh-float-chat 的旁证） | 本插件不依赖它；真拿到了也不是必需 |
| `process.execPath` / `DSH_DESKTOP_NODE_EXECUTABLE` 指向 `DeepSeek Harness.exe` | 高 | 代码里做了 4 层候选目录回溯 + `resources\icon.png` 探针；解析不到就写日志并降级 |
| `process.ppid` 是 Electron 主进程 | 中 | 只是**线索**：窗口进程还会自己扫描"同 exe 且有可见顶层窗口"的进程，并用"曾见过一次可见窗口"门闩锁定 |
| `.NET Process.MainWindowHandle` 在窗口 `hide()` 后为 0、在"最小化到任务栏"时非 0 | 高（`WS_VISIBLE` 语义） | 这是"收进托盘"判据的核心；不成立则表现为"该出球时不出/不该出时出"，日志可判 |
| `Add-Type` 能用 .NET Framework 自带 csc 编出那段原生小助手 | 高 | 失败即降级：只保留托盘隐藏路径，日志写明 `degraded mode` |
| `webServer.register` 在本机 DSH 版本上仍是该形状 | 中高（同版本已装插件在用） | 若形状变了，症状是插件加载即报错，日志可见 |

## 6. 后续实测补充（沙箱放宽后真的跑了一遍）

会话前期 `pwsh` 在受限沙箱下无法启动（`0xC0000142` = `STATUS_DLL_INIT_FAILED`），所以最初的结论全部来自读盘。后来把同一条命令放到 `danger-full-access` 下重跑就正常了（**这是沙箱导致的进程初始化失败，不是权限拒绝**），于是补做了实测：

| 实测项 | 结果 |
|---|---|
| 宿主进程真实启动形态 | `"<DSH 安装目录>\DeepSeek Harness.exe" --expose-internals <DSH 安装目录>\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js <DSH 安装目录>\resources\app.asar\dsh <profileDir> <runtimeDir> …` → 印证了「宿主 = DSH exe + `ELECTRON_RUN_AS_NODE=1`」以及「argv 里带 asar 路径」两条线索（`resolveRuntime()` 因此补了 argv 兜底） |
| 真实 node 路径 | `<安装目录>\resources\runtime\primary-runtime\dependencies\node\bin\node.exe` |
| 进程关系 | Electron 主进程 54644；DSH 宿主 48188（命令行含 `app.asar`）；GUI 端口 19387 属宿主 |
| 宿主半区 ESM | `IMPORT_OK name=dsh-float-ball hasApply=true` |
| 窗口脚本（PowerShell 5.1） | `PS_PARSE_OK`；`Add-Type` 原生助手可用；WPF 窗口 + `resources\icon.png` 真图标可显示 |
| 触发逻辑 | 诱饵窗口测试跑通「窗口消失 → 出球」「窗口回来 → 收球」（并普查确认只有诱饵窗口有 `MainWindowHandle`，测试有效） |
| 单实例交接 | 再次启动 DSH exe 后新进程立刻退出、DSH 进程数 7→7 不变 |
| 安装 | junction + `dependencies` + `bundles` 三步写入 desktop profile；`require.resolve('dsh-float-ball')` 从 profile 解析成功；profile 有 HMR，插件当场加载 |

## 7. 仍然**没有**做的（诚实边界）

- **没有**修改 DSH 安装目录（`<DSH 安装目录>\**` 全程只读）。
- 安装**确实**改了 desktop profile：新增 `node_modules\dsh-float-ball` 链接、`package.json` 的 `dependencies` 与 `dsh.profile.bundles`（原文件已备份为 `package.json.bak-dsh-float-ball`）。**没有**使用 `plugin_manager`（本会话没有这个工具），也**没有**触碰 `desktopPnpm` 那套安装的 WAL / receipt 内部机制。
- **没有**依赖 `desktopRuntime` / `desktopPnpmBootstrap` / `BrowserWindow` / 托盘注册表 / private Node helper 这些非契约接口（只用 bundle patch 与 `webServer`）。
- **没有**随包发任何二进制（图标直接从 DSH 安装目录读）。
- **没有**请求过 `/dsh-float-ball/*` 路由、**没有**截图。

## 8. v0.1.1：关闭到托盘后点击回不去（问题定位与修复记录）

用户反馈：最小化到任务栏时点球能回到窗口，**关闭到托盘的窗口点了没反应**。

定位过程（全部有实测支撑，没有靠推测）：

| 步骤 | 实测输出 | 结论 |
|---|---|---|
| 看球自己的日志 | 最小化时：`activate: ShowWindow(SW_RESTORE) + SetForegroundWindow`（立刻成功）；托盘隐藏时：只有 `activate: launched DSH executable (single-instance handoff)` | 托盘状态下走的是"再启动一次 exe"这条兜底 |
| 直接隐藏主窗口再启动 DSH exe、等 7s | `visible after launching DSH exe for 7s = False` | **兜底路径根本无效**：`second-instance` → `focusOwner` 不会把已隐藏的主窗口 `show()` 回来 |
| `ShowWindow(SW_HIDE)` 后读 `.NET` | `mainWindowHandle after SW_HIDE=0` | 隐藏窗口的句柄**还在**，只是 `Process.MainWindowHandle` 只认可见窗口 → 老代码以为"没有窗口" |
| 改用 `EnumWindows` 找隐藏窗口的句柄 | `found handles = 395272 visible = True`（隐藏前）/`restore: handles=395272 visibleBefore=False`（隐藏后） | 按 `pid + Chrome_WidgetWin_1 + GW_OWNER==0 + 非 WS_EX_TOOLWINDOW + 尺寸≥200×150` 能稳定找到 |
| 生产路径 `-RestoreOnly` 实测 | `restore-only exit code = 0`、`visible after production restore = True` | 修复有效 |
| 合成鼠标事件真的点一次球 | `DSH visible after the click = True`；球日志 `restore: handles=395272 visibleBefore=False` → `activate: ShowWindow + SetForegroundWindow` → `hide floating ball` | **端到端闭环**（隐藏 → 出球 → 点击 → 窗口恢复 → 球收起） |

附带发现的坑（值得记住）：**用工具重写 `floating-window.ps1` 会把 UTF-8 BOM 抹掉**，而 PowerShell 5.1 对无 BOM 的 `.ps1` 按 ANSI 读 —— 中文注释被读坏后甚至会被当成代码，直接抛 `MissingExpressionAfterToken` 让窗口进程崩在解析阶段（本次就把球搞成崩溃重启循环了）。现在 `lib/index.js` 在每次起窗口进程前用 `ensureUtf8Bom()` 检查并补 BOM，任何编辑器/工具再抹掉也能自愈。

另外两个测试脚本层面（非插件）的经验：`Start-Process -ArgumentList` **不会**为含空格的参数加引号（形如 `D:\Some Dir\...` 的路径会被拆成两个参数，导致窗口进程秒退）；WPF 窗口在 `ShowInTaskbar=false` 时会被系统设一个**隐藏 owner**，所以"按 `GW_OWNER==0` 找悬球窗口"会找不到（插件里找的是 Electron 窗口，那条路不受影响）。

## 9. v0.1.2：最小化点击失效 + 最大化后隐藏再唤回"只显示左上角一块"

v0.1.1 把"最小化"和"隐藏到托盘"合并进 `EnumWindows` 之后引入的两个回归，以及定位/修复/验证记录：

| 症状 | 定位证据 | 根因 |
|---|---|---|
| 最小化后点球不回来 | 用与插件相同的过滤器枚举时，最小化窗口不在结果里 | 尺寸过滤用的是 `GetWindowRect`，而**最小化时它返回"图标矩形"**（约 160×28、坐标 -32000）→ 主窗口被自己的过滤器漏掉（`FindMainWindows` 尺寸判据错误） |
| 关闭到托盘后回来了，但**只显示最大化布局的左上角一块** | 实测 `maximized: zoomed=True showCmd=3 client=1706x1018`，而旧代码一律 `SW_RESTORE` → 窗口被降级为普通尺寸；渲染器仍按最大化尺寸出图 | `SW_RESTORE` 会**取消最大化**；且外部 `ShowWindow` 不走 Electron 的 `NativeWindow::Show()`，WebContents 既没被告知可见性恢复、也没拿到新尺寸 |

修复：① 尺寸改读 `GetWindowPlacement().normalPosition`，最小化窗口直接放行；② 先读状态再显示（`IsIconic`/`showCmd==2` → `SW_RESTORE`，`IsZoomed`/`showCmd==3` → `SW_SHOWMAXIMIZED`，否则 `SW_SHOW`）；③ 显示后 `NudgeRelayout`（发 `WM_SIZE(SIZE_RESTORED, 当前客户区)` + `RedrawWindow`）让 Chromium 重新排版重画。

验证（合成鼠标点击，同一套生产代码路径）：

```
A) minimized -> click ball
   before: visible=True iconic=True
   restore: hwnd=395272 visible=True iconic=True zoomed=False showCmd=2
   after : visible=True iconic=False                                  => PASS
B) maximized then hidden -> click ball
   maximized: zoomed=True showCmd=3 client=1706x1018
   before: visible=False iconic=False zoomed=True showCmd=3
   restore: hwnd=395272 visible=False iconic=False zoomed=True showCmd=3
   after : visible=True zoomed=True client=1706x1018 (was 1706x1018)   => PASS
```

用例 B 另外截屏逐像素确认**渲染完整**（左侧栏 / 顶栏 / 对话区铺满，不是左上角一块）—— 尺寸相同只说明几何对了，截图才能证明 Chromium 真的重排了。

> 教训：跨进程操作另一个应用的窗口时，**不要用 `GetWindowRect` 判断"这是不是主窗口"**（最小化/隐藏状态下它的语义会变），要用 `GetWindowPlacement`；也**不要无条件用 `SW_RESTORE`**，它带着"取消最大化"的副作用。这两点都属于"只有在最小化/最大化状态下才会暴露"的坑。

## 10. v0.1.3：关闭到托盘后"窗口回来了但点什么都没反应"

用户反馈：关闭到托盘后点悬浮球，窗口出现了，但窗口内无法进行任何操作。

**根因（用窗口树实测确认）**：DSH 的关闭到托盘走 Electron 的 `win.hide()`，它会把 **Chromium 的网页内容子窗口 `Chrome_RenderWidgetHostHWND` 销毁**：

```
可见时：      hwnd=329766 Chrome_RenderWidgetHostHWND  vis=True
                            hwnd=329768 Intermediate D3D Window  vis=True
应用 hide() 后： 只剩 Intermediate D3D Window（网页内容子窗口消失）
```

⇒ 外部 `ShowWindow` 显示出来的只是一个**空壳窗口加最后一帧旧画面**，输入没有任何接收者；要恢复必须由 Electron 自己 `WebContents::WasShown()`（只有 `BrowserWindow.show()` 会调）重建该子窗口。

顺带解释了 v0.1.2 的"只显示左上角一块"：那是**旧的最大化画面**被裁进了被 `SW_RESTORE` 缩小后的窗口，而不是渲染器重排错了。

**逐一实测、全部无效的手段**（每一种都跑在由 `WM_CLOSE` 触发的真实关闭到托盘状态上；输入是否生效用"点页签后内容区截图哈希是否变化"判定）：

| 手段 | 结果 |
|---|---|
| `ShowWindow(SW_SHOWMAXIMIZED)` + `WM_SIZE(SIZE_RESTORED,客户区)` + `RedrawWindow` | 窗口可见，内容冻结，`INPUT WORKS = False` |
| 上面的基础上补 `WM_SHOWWINDOW(TRUE)` | 无效 |
| 上面的基础上最小化→还原一个来回 | 无效 |
| 上面的基础上 `SetWindowPos(SWP_FRAMECHANGED|NOSIZE\|NOMOVE\|NOZORDER)` | 无效 |
| 上面的基础上 `WM_ACTIVATE(WA_ACTIVE)` | 无效 |
| 启动 `DeepSeek Harness.exe`（`second-instance` → `focusPrimaryWindow`） | 窗口没被显示；**并且**用"先最小化再重启 exe"验证：窗口仍 `iconic=True` ⇒ 该回调在本机根本没执行 |
| 启动 `dsh://open` | 同上 |
| 向 `Electron_NotifyIconHostWindow` 发托盘回调消息（v3: `wParam=id,lParam=WM_LBUTTONUP`；v4: `wParam=(id<<16)\|msg`；id 0–8；消息号扫 `0x8000–0x81FF` 与 `0x0400–0x04FF`） | 无命中 |
| `Shell_NotifyIconGetRect` 取到图标矩形（id=3, 2097,1528,2145,1600）后合成点击（含 `mouse_event` 与 `SendInput` 两种） | 坐标正确（`WindowFromPoint` = `TrayNotifyWnd`/explorer），窗口未恢复 |
| 显式 `ShowWindow(网页内容子窗口, SW_SHOW)` | 子窗口已被销毁，找不到 |

**测试侧踩到的坑（值得记下）**：PowerShell 进程默认 **DPI 不感知**，`GetWindowRect(Shell_TrayWnd)` 返回的是被虚拟化过的坐标（`0,1019,1707,1067`），而 `Shell_NotifyIconGetRect` 返回的是**物理像素**（`2097,1528`）。两者混用会让 `SetCursorPos` 把鼠标送到屏幕外，看起来像"点击无效"。加 `SetProcessDPIAware()` 后两者一致。

**v0.1.3 的结论与实现**（结论已被下一节推翻，保留原文作为记录）：

1. `SetProcessDPIAware()`：坐标统一为物理像素（顺带让悬浮球按真实 DPI 渲染更清晰）；
2. `Test-DshFrozen()`：以"网页内容子窗口是否还存在"判定窗口是否已成空壳（实测可见时 True、应用 hide 后 False）；
3. 唤回顺序：按原状态显示 → 若冻结则**点 DSH 自己的托盘图标**（等于用户手动那一下）→ 仍冻结则日志明确写 `STILL FROZEN`；
4. **双击悬浮球 = 重启 DSH**（默认开启）：结束所有 `DeepSeek Harness.exe` 进程（悬浮球自身保留、随后主动退出，由新实例接管）再重新启动。这是冻结状态下唯一能保证"回到可用 DSH"的路径，代价是中断正在跑的一轮对话。

**一句话结论**：在 DSH 把窗口 `hide()` 到托盘之后，**外部进程无法让它的网页内容复活**；插件能保证的是"最小化 → 点球 → 立刻可用"，以及"冻结时给出可用的重启出口"。这属于 DSH 自身的行为，建议反馈给 DSH。

---

## 11. v0.1.4：修正上一节的错误结论 —— 网页内容是**会被重建**的，只是要等几秒

**为什么要复查**：用户提出"不要双击重启，我要单击就把关闭到托盘的窗口弹回来"。这把上一节的"外部无法恢复"顶到了台面上，于是按"最小可复现"重做了一遍实测。

### 11.1 先确认现象与根因（复现真实路径）

用 `WM_CLOSE` 驱动 DSH 真实关闭到托盘（已确认存在 `%APPDATA%\@deepseek-ai\dsh-desktop\background-close-confirmed` 标记，所以不会弹确认框），并同时记录三件事：窗口可见性、`Chrome_RenderWidgetHostHWND` 是否存在、`PrintWindow` 画面指纹。

```
baseline          vis=True  render=True   ink=75964/135000 hash=ebe550890eb56174
WM_CLOSE 之后      vis=False render=False  ink=0/135000     hash=e99e3bd5c9bf29a3   ← 截图全黑
只 ShowWindow+SetForegroundWindow：
  +2s             vis=True  render=False  ink=75964/135000 hash=4d85ecca4f6c34d6
  +5s             vis=True  render=False  ink=75964/135000 hash=4d85ecca4f6c34d6   ← 4.8s 仍是同一帧
```

**结论**：上一节描述的"空壳窗口 + 最后一帧旧画面"现象**确实存在**（`ink` 与隐藏前几乎一样、指纹不动）。到此为止和 v0.1.3 一致。

### 11.2 关键差异：v0.1.3 只等了 ~0.3s，而内容是几秒后才回来

改成分辨率更细的时间线（每 400ms 采样一次），在 `ShowWindow` 之后持续观察：

```
+400ms   vis=True  render=False  hash=2241a4b73dcd3a67
+800ms   vis=True  render=False  hash=2241a4b73dcd3a67
...
+2800ms  vis=True  render=False  hash=2241a4b73dcd3a67
+3200ms  vis=True  render=True   hash=ce4a790eec08ea78   ← 子窗口回来了
+3600ms  vis=True  render=True   hash=b06868628b2f0b19   ← 而且画面在逐帧变化
+4000ms  vis=True  render=True   hash=2c0813269be31cdf
```

⇒ **Chromium 会在窗口重新可见后自己重建 `Chrome_RenderWidgetHostHWND`**，只是要 **3~10 s**（另有一次 25 s+）。v0.1.3 在 0.3 s 就下结论，把"正在恢复"误判成"恢复不了"，进而加了一个基于误判的"双击重启 DSH"破坏性兜底。

### 11.3 哪些动作有用、哪些没用（真实关闭到托盘状态下逐个实测）

| 手法 | 结果 |
|---|---|
| 只 `ShowWindow(SW_SHOW)`（+补 `GW_ACTIVATE`、`SetForegroundWindow`、`WM_SIZE`、`RedrawWindow`） | **窗口显示，内容 3~10s 后自己恢复** ✅ |
| 只 `ShowWindow` 然后**立刻**判定 | 判成"冻结"（`render=False`）—— 这正是 v0.1.3 的错处 ❌ |
| 补 `WM_ACTIVATE(WA_ACTIVE)` + `WM_NCACTIVATE` + `SetForegroundWindow` | 与只 `ShowWindow` 等效，恢复同样由 Chromium 自己完成（差别在"激活状态"更接近真实点击）；保留在实现里 |
| `SwitchToThisWindow` | 无效（窗口仍未显示） |
| `SendMessage(WM_SYSCOMMAND, SC_RESTORE/SC_MAXIMIZE)` | 无额外作用 |
| 再启动一次 DSH exe（`second-instance` → `focusPrimaryWindow()`） | **无效**：窗口没被显示（要等 5s 也不显示） |
| 合成点击 DSH 自己的托盘图标 | 本机不可靠：`Shell_NotifyIconGetRect` 返回的是**溢出占位**坐标（`2097,1528`，而屏幕只到 `1707x1067`）——图标在隐藏图标区里，合成点击打不到。**不需要它了**（见 11.4） |

### 11.4 对实现的改动（v0.1.4）

1. **删掉双击重启**：`AllowRestart` / `-NoRestart` / `Invoke-RestartDsh` 全部移除，脚本里不再有任何 `Stop-Process`。
2. `Restore-DshWindow` 保持"按原状态显示"，补 `ActivateWindow`（`WM_ACTIVATE` + `WM_NCACTIVATE`），然后 `NudgeRelayout`（`WM_SIZE` + `RedrawWindow`）+ `SetForegroundWindow`。
3. **不再同步死等**：唤回后在后台用 `DispatcherTimer` 轮询（子窗口存在 **且** 像素指纹在变才算活），既不阻塞悬浮球的 UI 线程，也能把真实恢复耗时写进日志（最长 24s）。
4. 判定函数 `Test-DshContentAlive` = `HasRenderWidget` + 两次 `FrameSample`（`GetDC`/`GetPixel` 稀疏采样）指纹不同 —— 防"子窗口回来了但渲染器还没出帧"又被误判。
5. `-RestoreOnly` 默认只在"DSH 不可见 / 最小化"时执行；要强制跑加 `-ForceShow`。

### 11.5 验收数据（全部为实测）

| 场景 | 结果 |
|---|---|
| 关闭到托盘 → 调插件唤回（连跑 5 次） | 5/5 成功；内容恢复耗时 **~3.2s / 4.8s / 5.7s / 8.1s / 9.5s**（另有一次 25s+） |
| 关闭到托盘 → **合成真实左键点击真实悬浮球窗口**（球在屏幕内） | 窗口 `visible=True`，内容 **~4s** 恢复（`render=False→True`，指纹逐秒变化） |
| 最小化到任务栏 → 唤回 | `iconic=True → False`，内容立即可用 |
| DSH 正常可见 → 唤回 | 正确跳过，不动窗口 |
| 点击是否影响进程 | 不结束任何进程（代码里已无 `Stop-Process`） |

### 11.6 仍然成立的边界（诚实记录）

- **"关闭到托盘"后画面恢复有 3~10s（偶发 20s+）延迟**，这段时间窗口里是旧画面、点了没反应；这是 Electron `win.hide()` 销毁 WebContents 造成的，**外部只能等**，不能加速。
- 合成点击 DSH 托盘图标在这台机器上**不可靠**（图标处于隐藏图标区），因此不作为恢复路径；用户手动点托盘当然仍然有效。
- 恢复耗时的分布样本还很少（同一台机器、同一 DSH 版本），无法给出可靠的上下界；日志里的 `content: web contents back and repainting (~Ns after the click)` 可以持续收集。
- **本版本尚未装进 desktop profile 走一遍完整安装流程**（改动是在直接拉起窗口脚本 + 合成鼠标点击下验证的）。

---

## 12. v0.1.5：推翻第 11 节的修复 —— 判据错了，窗口其实**完全不能操作**

**触发**：用户实测反馈"关闭到托盘后单击悬浮球唤回的窗口是无法操作的，只是一帧画面摆在那里"。

### 12.1 第 11 节的判据为什么不成立

第 11 节把"`Chrome_RenderWidgetHostHWND` 存在 **且** 像素帧在变"当成"已经可用"。但 DSH 页面本身有**闪烁光标、计时、动画**，所以**冻结的死帧也会逐秒变化** —— 那个判据测的是"有没有东西在动"，不是"输入通不通"。结论：**判据必须是"输入是否被处理"**。

本轮采用的判据（可靠版）：

1. 从屏幕抓取窗口客户区像素（`Graphics.CopyFromScreen`）算指纹；
2. 相隔 1.2~1.4 s 两次指纹**全等** → 死帧；
3. 在全等的前提下，在客户区中央合成一次真实左键点击，再取指纹；
4. 指纹仍然全等 → **输入没被处理**（不可用）；
5. 用 `WindowFromPoint` 确认点击点落在 `Chrome_RenderWidgetHostHWND` 上，排除"点到别处"。

### 12.2 复现（把结论钉死）

```
baseline（DSH 可见，可操作）: 点(1280,200) windowClass=Chrome_RenderWidgetHostHWND
关闭到托盘(WM_CLOSE):        visible=False render=False
只 ShowWindow(SW_SHOW) 唤回:
  +8s   render=False  hash=1475180391924222
  +9.6s               hash=26ccab816102ad07   ← 变了！但这是页面自身动画，不是输入
  => 这一次被我错判为"输入生效"
严格版（改用"点击后再比 + 点击点确认"）:
  t=4.3s..31.5s render=False  hash=dd20f94ad3f8d280（31 秒纹丝不动）
  fgIsDsh=True（DSH 已经是前台窗口）  点击多次 → 画面无任何变化
  => 窗口可见、在前台，但**输入完全不通**、内容是死帧
```

⇒ 用户描述完全正确。**焦点不是根因**（`fgIsDsh=True` 时依旧不可用）。

### 12.3 逐个手段实测（每轮独立"关闭到托盘"，判据同上）

| 手段 | 内容重建 | 说明 |
|---|---|---|
| 只 `ShowWindow(SW_SHOW)` + `WM_ACTIVATE`（v0.1.4 做法） | **24319 ms** | A/B 对照里的 A 组 |
| `ShowWindow` + `WM_SYSCOMMAND(SC_RESTORE)` | **2704 / 2744 ms** | B 组，两次都 ~2.7 s |
| `ShowWindow` → `SW_MINIMIZE` → `SW_RESTORE` | 6454 ms | 有效但更慢 |
| `SW_SHOW` → `SW_MINIMIZE` → `SW_MAXIMIZE` | 无效 | 状态被改坏 |
| `SwitchToThisWindow` | 无效 | |
| `WM_SHOWWINDOW(TRUE)` / `WM_SETFOCUS` / `WM_SIZE` / `RedrawWindow` | 无效 | 都改不了"不可用" |
| 隐藏后 0 ms / 150 ms / 600 ms 立刻叫回来 | 全部无效（`render` 立刻仍为 `False`） | **抢时间没用**：内容是在 `hide()` 那一刻被销毁的 |
| `WM_ACTIVATE` / `WM_NCACTIVATE` / `SetActiveWindow` / `AttachThreadInput`+`SetForegroundWindow` | 无效 | 焦点类手段一律无效 |

### 12.4 v0.1.5 的实现与验收

唤回时在 `ShowWindow` 之后补 `WM_SYSCOMMAND`：**最大化前置 → `SC_MAXIMIZE`；其余 → `SC_RESTORE`**（后者会把最大化窗口降级，所以必须分支）。

关闭到托盘 → **合成真实左键点击真实悬浮球**（输出重定向到文件，避免控制台窗口遮挡影响判定）：

```
t=1s  visible=True render=False ink 不变     ← 死帧
t=2s  visible=True render=False ink 不变     ← 死帧
t=3s  visible=True render=True  hash 变化    ← 重建完成
...
E) 输入测试：点击点=1280,764 该点窗口类=Chrome_RenderWidgetHostHWND
   静置对比 A/B 不同 → 画面自己在动 = True
   点击后 hash 再变 → 输入生效 = True
   前台窗口=Chrome_WidgetWin_1 是DSH=True
```

最大化分支单测：前置 `zoomed=True` → 隐藏 → 唤回 → `zoomed=True`、`render=True`、判定 `alive` ✅

### 12.5 仍然做不到的事（诚实边界）

- **做不到"点一下立刻可用"**：内容重建是 Chromium 的异步过程，最快 ~2 s，实测波动 **2~8 s**（也见过 >10 s）。这段时间窗口已显示、标题栏/快捷键/任务栏正常，但网页区域是旧画面。
- **不要用"画面在不在动"判断可用性**（第 11 节的教训）：本机实测死帧的 hash 在 1.6 s 间隔下也会变。
- 想要"点一下立刻能用"，唯一可靠做法是**别让 DSH 关闭到托盘**（用最小化到任务栏）——最小化不销毁 WebContents，点击即用。
- `SC_RESTORE` 为什么能显著加速重建：只能确定"它是系统级的窗口恢复路径、且实测有效"，**内部机制未证实**（可能触发 Chromium 的窗口可见性/合成器重新激活）。样本量小（A 组 1 次、B 组 2 次 + 后续若干次），因此不宣称"稳定 3 秒"。

---

## 13. v0.1.6：`SC_RESTORE` 被证伪；穷尽外部手段后的诚实结论

**触发**：用户复测"还是死帧"，并指出"最小化后再弹回会变回普通尺寸"。

### 13.1 5 轮对照（用户视角：关闭到托盘 → 单击悬浮球 → 判 15s 内是否可用）

| 轮次 | 起点 render | render 出现 | 输入可用 |
|---|---|---|---|
| 1 | True | 15s 内没有 | ✗ |
| 2 | False | 23949ms | ✓ |
| 3 | True | 15s 内没有 | ✗ |
| 4 | False | 15s 内没有 | ✗ |
| 5 | False | 15s 内没有 | ✗ |

⇒ **1/5**。第 11 节那次 2.7s 是偶发。教训：单个样本的加速不能当作修复。

### 13.2 外部唤醒手段总表（本轮全部实测）

| 手段 | 结果 |
|---|---|
| `ShowWindow` + `WM_ACTIVATE`/`WM_NCACTIVATE`/`WM_SETFOCUS`/`SetActiveWindow` | 无效（改不了"不可用"） |
| `WM_SYSCOMMAND(SC_RESTORE/SC_MAXIMIZE)` | 偶发 1/5 |
| 隐藏后 0/150/600ms 立即回显 | 无效 |
| 再启动 exe（`second-instance`→`focusPrimaryWindow()`） | 11.5s 后才可见，无法归因，不可复现 |
| UIA `Invoke` 任务栏 DSH 按钮（`Appid: com.deepseek.dsh`） | `Unsupported Pattern`，坐标点击 `BoundingRectangle` 无效 |
| UIA `Invoke` "显示隐藏的图标" → 溢出面板找 DSH 托盘图标 | Invoke 成功但 `NotifyIconOverflowWindow` 找不到（报在 2097,1528，屏幕仅 1707x1067） |
| 屏幕合成点击托盘图标（`Shell_NotifyIconGetRect` 坐标） | 坐标在屏幕外，打不到 |

**机制结论（可确证的部分）**：Electron `win.hide()` → `WebContents::WasHidden()` → Chromium 销毁 `Chrome_RenderWidgetHostHWND`；恢复需要 `WebContents::WasShown()`，而它**只能由应用自己**在 `window.show()` 时触发。此外部不可达。

**因此**：`suggestions` 中"改用 minimize / 移出屏幕 / backgroundThrottling:false" 三条都指向同一个正确方向，但**都需要改 Electron 应用（DSH）的代码**：
- `minimize()` / `setPosition(-10000,-10000)` + `setSkipTaskbar(true)`：要改 DSH 的 `hideMainWindow()`；
- `backgroundThrottling:false` / `webContents.invalidate()`：要在 DSH 创建窗口处改，且插件半区拿不到 `webContents`。

### 13.3 本版本真正修掉的东西

`SW_RESTORE` 会取消最大化 → "最大化 → 最小化 → 点球 → 变普通尺寸"。修法：读 `WINDOWPLACEMENT.flags & WPF_RESTORETOMAXIMIZED(0x0002)`，`SW_RESTORE` 后按需补 `SW_MAXIMIZE`。实测前置 `zoomed=True` → 唤回后 `zoomed=True` ✅

### 13.4 状态

- 保留 `SC_RESTORE/SC_MAXIMIZE`（有比没有好，但**不是修复**），脚本注释里已如实标注。
- 悬空问题：关闭到托盘的窗口，外部只能"摆出来"，不能"弄活"。要真正解决必须改 DSH（或改用最小化）。