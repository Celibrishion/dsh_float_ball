# dsh-float-ball —— DSH 托盘悬浮球

**DSH 收进托盘后，桌面上出现一个白色圆形悬浮球，中间是 DSH 的虎鲸图标；左键能把它拖到任意位置（位置会被记住），单击它就把 DSH 唤回前台。**

这是一个标准的 DSH bundle 插件（宿主半区 + 一个自带的窗口进程），**仅 Windows**。

> **当前状态（2026-10-15，v0.1.5）：已安装进这台机器的 `desktop` profile 并正在运行。** 装法是 `plugin_manager` 的 `install_bundle`（等价 `link:` 安装，写进了 profile 的 `dependencies` 与 `dsh.profile.bundles`）；宿主半区**当场加载**（日志里能看到 `plugin loaded` + `floating window started`），**改窗口脚本后结束窗口进程即可让看门狗用新脚本重建**（日志里的 `restart` 行）。README 早前版本提到的 `install-into-desktop-profile.ps1` 在这个工作区里**并不存在**（重装请用 `plugin_manager` 或 `dsh plugin`）；**移动工作区里的插件目录会断链**，移完要重新 `install_bundle`。

---

## 1. 它会做什么

| 你的要求 | 实现方式 | 状态 |
|---|---|---|
| DSH 最小化到托盘后出现悬浮窗 | 窗口进程每 700ms 看一次 DSH 主窗口是否还在（`MainWindowHandle`）；被收进托盘（窗口隐藏）就 `Visibility=Visible`，DSH 回来就 `Hidden` | ✅ |
| 圆形悬浮窗 | WPF `AllowsTransparency + WindowStyle=None`，内容是「白色椭圆 + 圆形裁剪」→ **逐像素透明、边缘抗锯齿**（不是硬边的 `Region` 圆） | ✅ |
| 背景色为白色 | 圆形底是白色 `#FFFFFF`；上面铺的是 DSH 图标本体（`icon.png`，虎鲸 + 一层**接近纯白**的浅色底），整块裁成圆形 | ✅ 见下方「关于底色」 |
| 图标为 DSH 的图标 | 自动用 DSH 安装目录里的 **`resources\icon.png`**（就是那个深色虎鲸标，1024×1024），铺满圆并裁圆；也可用配置项换成别的图 | ✅ |
| 鼠标左键拖动到任意位置 | WPF 原生 `Window.DragMove()`：按下即拖动，**不会吃掉单击事件**；松手后把 `Left,Top` 写进 `position.txt`，下次原地出现 | ✅ |
| 点击悬浮窗后打开 DSH | 拖完后位移 < 3px 判为单击 → 自己 `EnumWindows` 找到 DSH 主窗口句柄（可见 / 最小化 / 已隐藏到托盘都能找到）→ **按原状态**显示（最小化 `SW_RESTORE` / 最大化 `SW_SHOWMAXIMIZED` / 其余 `SW_SHOW`）+ `WM_ACTIVATE` + **`WM_SYSCOMMAND`（最大化 `SC_MAXIMIZE`、其余 `SC_RESTORE`）** + `SetForegroundWindow`，再补 `WM_SIZE` 让 Chromium 重排。**关闭到托盘**时窗口内容被 DSH 销毁过，显示之后 Chromium 会重建它（实测补了 `SC_*` 后 **2~8 s**，不补则 24 s 起甚至不出）；这段时间窗口可切换、标题栏可用，但网页区域是旧画面。找不到句柄才退到"再启动一次 DSH exe"兜底 | ✅ 已实测（真实合成左键点击，判据是"输入是否被处理"，不是"画面是否在变"） |

额外顺手做的：

- **位置持久化**、**自动夹回屏幕内**（换分辨率/拔掉副屏也不会把球丢到屏幕外）；
- **连点保护**（1.2s 内只响应一次唤回）；
- **孤儿自杀**：连续 ~6s 找不到 DSH 主进程就自己退出；
- **看门狗**：窗口进程意外挂掉会按 1s→2s→4s…→30s 退避重启，连续失败 8 次后放弃并写日志（不会疯狂刷进程）；
- **自检路由**（见第 5 节）：不用写代码就能看状态、看日志、改配置、重启窗口；
- 插件卸载 / DSH 退出时**把窗口进程收干净**。

> > **本插件不含任何"重启 / 结束进程"的行为**：`allowRestart` 与 `-NoRestart` 已彻底移除，
> **任何点击都不会结束任何进程**。

### 关于圆形底色（一处取舍）

圆形底是白色 `#FFFFFF`，但上面铺着 **DSH 的 `icon.png` 本体**：那张图标自带一层**非常接近纯白**的浅色底（约 `#F6F8FA`→`#FDFEFF`）。所以球的底色严格说是"图标那层近白底"，肉眼就是白的，但**不是 100% 的 `#FFFFFF`**。

我选择「图标铺满整个圆 + 裁圆」，而不是「纯白底 + 缩小图标」，是因为后者会让图标那张方形/圆角方的浅色底在纯白圆中央露出**一圈可见的边界**，反而更难看。

若要严格纯白，两条路：

- 把 `iconPath` 指向 `<安装目录>\resources\tray.ico`——托盘图标通常是**透明背景**的纯 glyph，压在纯白圆上就没有任何底色（代价：尺寸小，放大到 72px 会偏软）；
- 或者改宿主代码，在载入图标时加一道"近白色 → 纯白"的像素级处理（把亮度高、饱和度低的像素刷成 `#FFFFFF`，只留虎鲸），代价是多一段位图处理代码。

---

## 2. 交互

| 操作 | 结果 |
|---|---|
| 把 DSH 关闭到托盘（点窗口 X） | 悬浮球出现（默认位置：屏幕右侧、约 62% 高度处） |
| 左键按住拖动 | 跟随鼠标移动，可放到任意位置；松手即记住 |
| 左键单击 | DSH 主窗口被唤回前台并恢复。**"关闭到托盘"也有效**：窗口先按原状态显示出来（快捷键/标题栏立刻可用），网页内容由 Chromium 自己重建，实测 3~10 s（偶发更久）后画面恢复，插件在后台观察并写日志。**单击不会重启或结束任何进程** |
| 最小化到任务栏（不是托盘） | 默认**也算"收起来了"**，同样出球。想只在真正收进托盘时出球，把 `includeMinimized` 设为 `false` |
| DSH 退出 | 悬浮球随之消失（宿主卸载插件时杀掉窗口进程） |

悬浮球带一行 tooltip：`左键拖动移动位置 · 单击打开 DSH`。

---

## 3. 安装

### 方式一：一条命令（推荐）

在 DSH 里（侧边栏「插件」页，或直接对 agent 说一句话）安装市场包：

> 用 plugin_manager 安装 bundle：dsh-float-ball

装完**完全退出 DSH（含右下角托盘图标）再重新打开**即可。

同一个入口也支持其他来源：

| 来源 | 填什么 |
|---|---|
| registry（npm） | `dsh-float-ball` |
| git 仓库 | `https://github.com/Celibrishion/dsh_float_ball` |
| tarball | `https://.../dsh-float-ball-0.1.6.tgz` |
| 本地目录 | 绝对路径 |

命令行等价写法（用于 `web` profile 自检）：

```powershell
dsh plugin --profile web add link:"<本目录绝对路径>"
```

> 桌面端（`desktop` profile）由 Electron 应用独占管理，命令行 `dsh plugin` 会拒绝 `--profile desktop`，
> 所以桌面端请走上面的插件页 / `plugin_manager`。

### 可选增强：热补丁（修「关闭到托盘后点球是死画面」）

不打补丁插件也能用，但**点窗口 X 关闭到托盘后**，单击悬浮球虽然能把窗口唤回来，
里面却是一帧死画面、点不动（要等十几秒到几十秒）。

原因在 DSH 一侧：`win.hide()` 会触发 Chromium 的 `WebContents::WasHidden()`，
销毁网页内容子窗口 `Chrome_RenderWidgetHostHWND`，外部进程无法让它复活。

补丁把 `hideMainWindow()` 从「隐藏窗口」改成「最小化 + 收起任务栏图标」——
**仍然是托盘语义**（不在任务栏、不在 Alt-Tab），但网页内容不会销毁，唤回后**立刻可用**。

因为它是**修改 DSH 应用包**（`resources\app.asar`）的外部工具，所以**不随市场包分发**，
需要单独下载并使用（详见补丁包内的说明）：

1. 完全退出 DSH
2. 运行补丁包里的 `apply-patch.cmd` → 按 `Y`
3. 出问题就运行 `ROLLBACK.cmd` 一键还原

> ⚠️ DSH 每次自动更新会覆盖 `app.asar`，补丁失效后重新运行一次即可。

## 4. 最快自检（30 秒，不用真去最小化）

默认情况下悬浮球只在 DSH 不可见时出现。为了让你**先看外观、先试拖动**，插件提供了 `alwaysVisible` 开关：打开后 DSH 可见时也一直显示。

**方式 A（浏览器里点一下）** —— 在装好并重启后，用本机浏览器打开：

```
http://127.0.0.1:<DSH Web 端口>/dsh-float-ball/settings.json
```

看到 JSON 就说明宿主半区已加载。改配置用 POST（例如把 `alwaysVisible` 打开）：

```powershell
# 端口就是你平时访问 DSH 界面的那个（dsh web 默认 3080；桌面端看日志里的 hostUrl）
curl.exe -X POST http://127.0.0.1:3080/dsh-float-ball/settings.json ^
  -H "Content-Type: application/json" ^
  -H "Host: 127.0.0.1:3080" ^
  -d "{\"alwaysVisible\":true}"
```

> 这些路由带**回环信任栅栏**：只接受 `127.0.0.1/localhost/[::1]`，拒跨站标记与非同源 Origin。所以务必用 `http://127.0.0.1:...`（不要用局域网地址），并且别忘 `Host` 头一致。

**方式 B（直接改文件，然后重启 DSH）** —— 编辑：

```
%USERPROFILE%\.dsh\dsh-float-ball\settings.json
```

把 `"alwaysVisible": true`，重启 DSH。看到球后：拖它、点它；确认没问题再把 `alwaysVisible` 关掉，然后按第 1 节验证"收进托盘才出球"。

**看日志**（宿主半区与窗口进程写同一份）：

```powershell
Get-Content "$env:USERPROFILE\.dsh\dsh-float-ball\float-ball.log" -Tail 40
```

或 `http://127.0.0.1:<端口>/dsh-float-ball/log.txt`。

---

## 5. 自检路由（全部只允许本机回环）

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/dsh-float-ball/status.json` | 一把梭状态：安装目录、解析到的图标/exe、目标 pid、窗口进程 pid、失败次数、设置、最近 30 行日志 |
| GET | `/dsh-float-ball/settings.json` | 读当前设置 |
| POST | `/dsh-float-ball/settings.json` | 合并写入设置（写入 `settings.json`，会影响窗口进程的参数会自动重启它） |
| POST | `/dsh-float-ball/restart.json` | 重启悬浮球窗口进程（改完脚本想立刻看效果时用） |
| GET | `/dsh-float-ball/icon.png` | 返回"实际解析到的图标"——用来确认插件找到的是不是你想要的那张图 |
| GET | `/dsh-float-ball/log.txt` | 最近 400 行日志 |

---

## 6. 配置项

| 键 | 类型 / 取值 | 默认 | 说明 | 何时生效 |
|---|---|---|---|---|
| `enabled` | boolean | `true` | 总开关。`false` = 完全不起悬浮球进程 | 立即 |
| `size` | 40–160 | `72` | 悬浮球直径（DIP，会随系统缩放变物理尺寸） | 重启窗口进程 |
| `pollMs` | 150–5000 | `700` | 轮询 DSH 主窗口状态的间隔 | 重启窗口进程 |
| `alwaysVisible` | boolean | `false` | 调试用：DSH 可见时也一直显示 | 重启窗口进程 |
| `includeMinimized` | boolean | `true` | `true` = 最小化到任务栏也出球；`false` = 只在被收进托盘（窗口隐藏）时出球 | 重启窗口进程 |
| `startDelayMs` | 0–60000 | `1500` | 插件加载后延迟多久起窗口进程（避免和 DSH 启动抢资源） | 下次启动 |
| `iconPath` | string | `''` | 覆盖图标路径；留空 = 自动用 `<安装目录>\resources\icon.png`，找不到就退到 `tray.ico`，再不行画一个 `DSH` 文字兜底 | 重启窗口进程 |
| `appExePath` | string | `''` | 覆盖 DSH 可执行文件路径（唤回 DSH 用）；留空 = 自动解析 | 重启窗口进程 |
| `targetPid` | number | `0` | 覆盖"DSH 主进程 pid"；留空 = 用 `process.ppid`，同时窗口进程自己也会扫描同 exe 的进程 | 重启窗口进程 |

> v0.1.4 起**不再有 `allowRestart`**（双击重启已整体移除）。旧的 `settings.json` 里若留着这个键，会被直接忽略。

运行时数据都在 `%USERPROFILE%\.dsh\dsh-float-ball\`：

| 文件 | 用途 |
|---|---|
| `settings.json` | 上面的配置（原子写：tmp + rename） |
| `position.txt` | 悬浮球坐标 `left,top`（窗口进程自己写） |
| `float-ball.log` | 宿主半区 + 窗口进程的日志（超过 1MB 自动重开）。⚠️ 两个半区一个用 UTF-8 写、一个用 `Add-Content -Encoding UTF8` 追加，**同一份文件里中文会一段正常一段乱码**（实测：含中文的安装路径 `D:\新建文件夹` 在 host 行里显示成 `D:\鏂板缓鏂囦欢澶?`）。纯属日志可读性问题，不影响功能 |

---

## 7. 工作原理

DSH 的 Desktop 端把插件装在 `desktop` profile 里，**插件代码跑在 DSH 的 Node 宿主进程内**。那个进程里没有任何窗口 API，所以本插件走的是生态里已经跑通的路子：**宿主半区 spawn 一个自带窗口的进程**（社区同类插件 `dsh-float-chat` 的做法是自带 WinForms + WebView2 的 `.exe`；本插件改成 **PowerShell + WPF**，好处是**不需要随包发任何编译产物**）。

```
DSH 桌面端（Electron 主进程）
  └─ DSH 宿主进程（DeepSeek Harness.exe + ELECTRON_RUN_AS_NODE=1）
       └─ dsh-float-ball 宿主半区  lib/index.js
            │  ① 解析安装目录 / 图标 / DSH exe / 目标 pid
            │  ② spawn：powershell.exe -File assets/floating-window.ps1 ...
            │  ③ 看门狗 + 配置持久化 + 自检路由
            └─ 悬浮球窗口进程（Windows PowerShell + WPF）
                 · 白圆 + 虎鲸图标（裁圆、抗锯齿）
                 · DragMove 拖动 → 写 position.txt
                 · 单击 → ShowWindow(原状态)+WM_ACTIVATE+SetForegroundWindow，
                          拿不到句柄就再启动一次 DSH exe（单实例 → focusOwner）
                 · 唤回后在后台等网页内容重建 + 开始出帧（DispatcherTimer）
                 · DispatcherTimer 轮询 DSH 主窗口状态 → Show/Hide 自己
```

关键点解释：

- **"被收进托盘"是怎么判断的**：.NET 的 `Process.MainWindowHandle` 只认 `WS_VISIBLE` 的顶层窗口，所以 DSH 窗口被 `hide()` 到托盘时它是 `0`。Electron 桌面端有多个同路径进程（主进程/GPU/渲染/utility），只有主进程拥有可见顶层窗口 —— 于是"任一候选进程有非零 MainWindowHandle"就是可靠的"DSH 还看得见"判据。
- **为什么要 `SeenVisible` 门闩**：DSH 刚启动时窗口还没建好，句柄也是 0。如果一上来就信"不可见 = 收进托盘"，托盘球会在 DSH 启动过程中乱闪。所以只有**曾经见过一次可见窗口**之后，才把"不可见"解释为"收进托盘"。
- **"关闭到托盘"怎么真正唤回（v0.1.4 的关键结论）**：隐藏的窗口只是被 `ShowWindow(SW_HIDE)` 藏起来，**句柄一直在**，所以自己 `EnumWindows`（`pid + Chrome_WidgetWin_1 + 无 owner + 非工具窗`）就能找到并显示出来。麻烦在于 DSH 关闭到托盘走的是 Electron 的 `win.hide()`，它会把 **Chromium 的网页内容子窗口 `Chrome_RenderWidgetHostHWND` 一起销毁** —— 刚显示出来时窗口只有"最后一帧旧画面"，点不动。**但这并不是"无法恢复"**：窗口重新可见后 Chromium 会自己把这个子窗口重建回来，实测 **3~10 s（偶发 20 s+）** 画面就活了。所以插件显示窗口后在后台等它重建，而不是立刻下结论。
- **v0.1.3 为什么误判成"恢复不了"**：老代码在显示窗口后只等 ~0.3 s 就检查"内容在不在"，此时 Chromium 还没重建完，于是写下 `STILL FROZEN`，并据此得出"外部无法恢复、只能重启 DSH"的结论 —— "双击重启"兜底就是建立在这个误判上的。实测只要**多等几秒**内容就会自己回来（见 PROVENANCE 第 11 节）。
- **`WM_ACTIVATE` 那一下**：外部 `ShowWindow` 不走 Electron 的 `NativeWindow::Show()`，窗口的"激活"状态不会跟着回来；补发 `WM_ACTIVATE(WA_ACTIVE)` + `WM_NCACTIVATE`（再加 `SetForegroundWindow`）更接近"用户真的点了托盘图标"。
- **配置项 `includeMinimized` 依赖一段可选的原生小助手**：脚本用 `Add-Type` 编一个含 `IsIconic/ShowWindow/ActivateWindow/SetForegroundWindow/HasRenderWidget/FrameSample` 的小 C# 类（.NET Framework 自带 csc）。编不出来就自动降级：只有"托盘隐藏"路径生效，日志里会写 `native helper unavailable, degraded mode`。

### 为什么不用 Electron `BrowserWindow`（重要）

DSH 官方《插件开发》文档里明确写了**不要依赖的接口**：

> `desktopRuntime`、`desktopPnpmBootstrap`、Electron `BrowserWindow`、托盘注册表、private Node helper、`ELECTRON_RUN_AS_NODE` 和生成的 shim 都是 Desktop 内部实现。即使它们出现在 declaration 或运行时上下文中，也不属于第三方兼容 contract。

再加上插件半区本来就在**没有窗口 API 的 Node 宿主进程**里，所以：

- 不用 `BrowserWindow` 自己开窗（会在 DSH 升级后随时碎掉，而且当前进程根本拿不到）；
- 不自己注册托盘、不劫持 DSH 的托盘图标；
- 不碰 `desktop` profile 的 `package.json` / `cordis.patch.yml`（那是宿主 `plugin_manager` 的事）。

本插件只用了公开契约：**profile bundle**（`package.json` 的 `dsh.bundle` + `cordis.patch.yml`）、宿主服务 **`webServer`**、以及可选服务 `connection` 的请求栅栏。

---

## 8. 已知限制

1. **仅 Windows**。窗口是 PowerShell + WPF（.NET Framework）画的，macOS / Linux 没有对应实现；非 Windows 上插件会加载但不出球，日志里写明 `win32 only`。
2. **有一个常驻的 PowerShell 窗口进程**（约 40–70MB 内存）。为了"一收进托盘就立刻出球"，它是插件加载后 ~1.5s 起、一直活着的；不用就设 `enabled: false`。想更省内存可以把 `enabled` 关掉，或后续改成"检测到隐藏再起进程"（需要客户端半区上报，见下）。
3. **UI 在 DSH 里的入口暂时没有**。本版本不带客户端半区（不在 DSH 页面里塞按钮），自检/调参走第 5 节的本地路由或直接改 `settings.json`。加一个客户端半区（`dsh.client` + `webServer.tapIndex`/`webserver/index-inject` 注入）就能做成"设置页里一个开关"，但那会给页面注入脚本，改动面更大，所以先不做。
4. **`includeMinimized` 需要 `Add-Type` 能编译**（.NET Framework 自带 csc，Win10/11 正常都有）。编译不了只影响"最小化到任务栏也出球"，托盘隐藏路径不受影响。
5. **位置在跨 DPI 缩放的多显示器间移动后可能略有偏移**：位置按 DIP 存，同一个缩放比例下精确，混用不同缩放比例的显示器时可能差几像素。
6. **"关闭到托盘"后点球的画面恢复有几秒延迟（补 `SC_*` 后 2~8 s）**：窗口本身（标题栏、快捷键、任务栏条目）瞬间就回来了，但**网页内容**要等 Chromium 把被销毁的 `Chrome_RenderWidgetHostHWND` 重建完才出画。这段时间窗口是"旧画面、点不动"，属 DSH（Electron `win.hide()`）的行为，外部只能缩短、无法消除；日志里会写 `content: web contents back and repainting (~Ns after the click)`。**"最小化到任务栏"没有这个问题**（WebContents 没被销毁，点击即用）。**想要"点一下立刻能用"就用最小化，不要用关闭到托盘。**
7. **"再启动一次 DSH exe"这条兜底路径在本机不生效**：实测 `second-instance` → `focusPrimaryWindow()` 不会把已隐藏的窗口显示回来，所以它只是找窗口失败时的最后一道保险，不要指望它。
8. **判断"窗口恢复没有"不能看画面是否在动**：DSH 页面有闪烁光标/计时/动画，死帧也会变。要看输入是否被处理（屏幕指纹 + 合成点击），否则会把"渲染色了一块"误判成"已经可用"—— 本项目 v0.1.4 就是这样误报过一次。

---

## 9. 排错

| 现象 | 先查什么 |
|---|---|
| 装完什么都没有 | ① 是不是装到了 `desktop` profile（桌面端读的不是 `web`）；② **重启过 DSH 桌面端没有**（宿主半区不热重载）；③ 看 `float-ball.log` 有没有 `plugin loaded` |
| 有 `plugin loaded` 但一直没有球 | 日志里看 `installRoot` / `icon` / `appExe` 是不是 `null`；把 `alwaysVisible` 打开强制显示，确认窗口本身能不能出来 |
| 一直不出球，但 DSH 确实收进托盘了 | 日志里应该有 `hide ... / show ...` 交替。若只看到 `hide floating ball`，说明判断成"DSH 还可见"：把 `targetPid` 手动填成 DSH **主进程**的 pid（任务管理器 → 详细信息 → 找那个占内存最多的 `DeepSeek Harness.exe`）再看 |
| 单击没反应 | 日志里应有 `activate: bring DSH back`。若写 `app executable unknown` → 用 `appExePath` 手动指定 `DeepSeek Harness.exe` 的绝对路径 |
| 点了球，窗口出来了但里面点不动 | **正常现象、会自愈**：DSH 关闭到托盘时销毁了 Chromium 的网页内容，需要几秒重建（补 `SC_RESTORE/SC_MAXIMIZE` 后实测 2~8 s）。日志里会看到 `content: web contents back and repainting (~Ns after the click)`。**想要点一下立刻能用，请改用"最小化"而不是"关闭到托盘"**（最小化不销毁 WebContents） |
| 想确认"到底恢复了没有" | 别只看画面：DSH 页面有动画，死帧也会变。看日志里的 `content: ...` 行，或手工在窗口里点一下标题/按钮，看有没有响应 |
| 图标不对 / 空白 | `http://127.0.0.1:<端口>/dsh-float-ball/icon.png` 看解析到的是哪张；不是想要的就用 `iconPath` 指定 |
| 球太大/太小 | 改 `size`（DIP，72 在 100% 缩放下是 72px，150% 缩放下是 108px） |
| 想把球彻底关掉 | `settings.json` 里 `"enabled": false` 然后重启 DSH；或直接卸载插件 |
| 改了 `floating-window.ps1` 不生效 | POST `/dsh-float-ball/restart.json` 重启窗口进程（该脚本每次启动都重新读盘） |
| 改完 `lib/index.js` 不生效 | 宿主半区**不热重载**，重启 DSH（或按生态惯例改文件名/目录后重装，那是为了绕过 ESM 路径缓存） |
| 端口是多少 | `dsh web` 默认 `3080`；桌面端看宿主日志里的 hostUrl，或在 DSH 设置里看服务地址 |

---

## 10. 文件清单

```
dsh-float-ball/
├── package.json                     # DSH bundle 插件元数据（dsh.bundle.patch 指向 cordis.patch.yml）
├── cordis.patch.yml                 # 挂载声明：把宿主半区插进当前 profile
├── lib/
│   └── index.js                     # 宿主半区：解析路径 / 起窗口进程 / 看门狗 / 路由 / 生命周期
├── assets/
│   └── floating-window.ps1          # 悬浮球窗口本体（PowerShell + WPF：白圆 + DSH 图标 + 拖动 + 单击唤回）
├── README.md                        # 本文件
└── PROVENANCE.md                    # 结论是怎么得出来的（读了哪些来源、验证到什么程度）
```

---

## 11. 附录：设计与实测记录

开发过程中在 Windows 11 + DSH Desktop 上逐项实测过（数据见下面各版本小节与 `PROVENANCE.md`）：宿主半区能被 profile 正常解析加载、窗口脚本在 PowerShell 5.1 下语法通过、WPF 白圆 + 真 DSH 图标可显示、**最小化 → 点球 → 窗口立刻可用**（合成鼠标点击验证，含先最大化再最小化的前置状态），以及 **v0.1.4 起"关闭到托盘 → 点球 → 窗口显示 → 网页内容几秒后自己恢复"**（合成左键点击真实悬浮球窗口验证）。

> 本文档里的"安装位置 / 实测日志"若提到具体目录，都只是开发机上的样例；插件本身**不含任何硬编码路径**：安装目录、图标、DSH 可执行文件、目标进程都在运行时解析（见 `lib/index.js` 的 `resolveRuntime()`）。

### 卸载 / 回滚

用 `plugin_manager` 的 `remove_bundle`（或 `dsh plugin --profile web remove dsh-float-ball`）卸载，然后**完全退出 DSH（含托盘）再打开**。运行时数据（`%USERPROFILE%\.dsh\dsh-float-ball\`）可以整个删掉。

### 已经实测通过的部分（不是推断）

| 项 | 实测结果 |
|---|---|
| 宿主半区 ESM 合法性 | `IMPORT_OK name=dsh-float-ball hasApply=true` |
| loader 等价解析（从 profile 用 `require.resolve` 找 bundle 名） | `RESOLVE_OK …\dsh-float-ball\lib\index.js` + `LOAD_OK` |
| 窗口脚本 5.1 语法 | `PS_PARSE_OK`（并已给脚本补 UTF-8 BOM，否则 5.1 会把中文读成乱码） |
| WPF 窗口 + 真 DSH 图标 | 日志 `icon loaded` → `show floating ball` → `floating ball ready`，窗口存活 |
| 原生小助手 `Add-Type`（最小化检测 / 立即还原） | `native helper ready` |
| **窗口消失→出球 / 窗口回来→收球** | 诱饵窗口测试：`18:03:27 show floating ball`（诱饵隐藏后约 0.7s）→ `18:03:32 hide floating ball`（诱饵回来后）。同期普查确认只有诱饵窗口有 `MainWindowHandle`，测试有效 |
| DSH 可见时**不会**乱出球 | 真插件窗口进程的日志里始终没有 `show`（候选 pid 是 DSH 各进程） |
| 单击唤回兜底路径的安全性 | 再次启动 DSH exe：新进程 `exited=True`、DSH 进程数 7→7（单实例交接，不会开出第二个窗口）。**注意：它并不会把已隐藏的窗口显示回来**，v0.1.4 已把它降级为"找不到窗口句柄时的最后保险" |

### v0.1.6（当前版本）：承认失败 —— 外部无法可靠唤醒 WebContents，问题需要改 DSH 本身

**用户复测反馈**：加了 `SC_RESTORE` 之后**还是会死帧**；另外"最小化后再弹回会变回普通尺寸"。

**1) `SC_RESTORE` 不是修复，只是偶发**（5 轮用户视角对照，每轮独立"关闭到托盘 → 点球"）：

| 轮次 | 起点 render | 结果 |
|---|---|---|
| 1 | True | **FAIL**，15s 内内容没回来 |
| 2 | False | 成功，但用了 **23949ms** |
| 3 | True | **FAIL** |
| 4 | False | **FAIL** |
| 5 | False | **FAIL** |

⇒ 上一轮那次 2.7s 是运气。**不要把偶发当修复**（这已经是本项目第二次踩同一个坑：v0.1.4 把"画面在动"当可用，这次把"一次 2.7s"当稳定）。

**2) 穷尽所有外部手段，全部无法可靠唤醒**（本轮实测）：

| 手段 | 结果 |
|---|---|
| `ShowWindow` + `WM_ACTIVATE` / `WM_NCACTIVATE` / `WM_SETFOCUS` | 无效 |
| `WM_SYSCOMMAND(SC_RESTORE / SC_MAXIMIZE)` | **偶发**（1/5） |
| 隐藏后 0/150/600ms 立刻叫回 | 无效（内容在 `hide()` 那刻就被销毁） |
| 再启动 DSH exe（`second-instance` → `focusPrimaryWindow()`） | 11.5s 后窗口才出现，无法归因；不是可靠唤醒 |
| UIA `Invoke` 任务栏的 `DeepSeek Harness` 按钮 | 不支持 `InvokePattern`，坐标点击也失败 |
| UIA `Invoke` 托盘"显示隐藏的图标" → 找 DSH 托盘图标 | 溢出面板窗口报在 `2097,1528`（屏幕只有 1707×1067），**找不到该窗口** |
| `SwitchToThisWindow` / `AttachThreadInput`+`SetForegroundWindow` / `WM_SHOWWINDOW` | 无效 |

**结论**：DSH 的 `win.hide()` 把 WebContents 销毁后，**唯一能真正恢复它的只有 DSH 自己再调 `window.show()`**（= 用户手动点它自己的托盘图标）。外部进程做不到 —— 这需要改 DSH 的代码，不是插件能修的。**悬浮球在这种状态下只能"把窗口摆出来"，做不到"让它活过来"。**

**3) 修掉的真 bug（本版本唯一确定有效的改动）**：`SW_RESTORE` 会取消最大化，导致"最大化 → 最小化 → 点球"后窗口变回普通尺寸。改为读 `WINDOWPLACEMENT.flags` 的 `WPF_RESTORETOMAXIMIZED(0x0002)`，必要时补 `SW_MAXIMIZE` + `SC_MAXIMIZE`。实测前置 `zoomed=True` → 最小化 → 唤回后 `zoomed=True` ✅

**4) 建议**：如果"点球必须立刻能用"是你的硬需求，**日常请用"最小化到任务栏"而不是"关闭到托盘"**（最小化不销毁 WebContents，点完即用）。若必须用关闭到托盘，目前可靠的恢复手段只有 **DSH 自己的托盘图标**。

### v0.1.5：v0.1.4 的修复是错的 —— 窗口"看着回来了"但输入完全不通

> ⚠️ 本节提出的 `SC_RESTORE` "修复"经 v0.1.6 的 5 轮对照证明**不可靠**（1/5），保留原文仅作记录。

**用户反馈**：关闭到托盘后单击悬浮球，窗口回来了，但里面**点不动**，只是"一帧画面摆在那里"。

**v0.1.4 错在哪**：当时用"网页内容子窗口回来了 **且** 像素帧在变"当作"已经可用"。但 DSH 页面本身有闪烁光标/计时/动画，**冻结的死帧也会逐秒变化**，所以那个判据根本不成立 —— 我把"渲染色了一块"当成了"窗口能用"。这是本次最该记住的教训：**判据必须是"输入是否被处理"，不是"画面是否在变"**。

**正确判据（本轮采用）**：从屏幕抓取窗口客户区像素 → 两个时刻的指纹全等 = 死帧；再合成一次真实左键点击 → 指纹仍全等 = 输入没被处理。用 `WindowFromPoint` 确认点击确实落在 `Chrome_RenderWidgetHostHWND` 上。

**由此得到的实测事实**：

| 事实 | 数据 |
|---|---|
| 冻结确实存在，且与"焦点"无关 | `GetForegroundWindow` 已经是 DSH（`fgIsDsh=True`）时，画面 30 多秒指纹恒定、点击无反应 |
| 只做 `ShowWindow(SW_SHOW)`（v0.1.4 的做法） | 内容重建 **24.3 s** 才出现，甚至 40 s 都不出现 |
| 补发 `WM_SYSCOMMAND(SC_RESTORE)` 之后 | 内容重建 **~2.7 s**（两次 2704/2744 ms），实测反复出现子窗口并在 ~3 s 开始出帧 |
| "抢时间"没用 | 隐藏后 0 ms / 150 ms / 600 ms 就叫回来，`render` 立刻仍是 `False` —— 内容是在 `hide()` 那一刻被销毁的，抢不回来 |
| 焦点手段全部无效 | `WM_ACTIVATE` / `WM_NCACTIVATE` / `WM_SETFOCUS` / `SetActiveWindow` / `SwitchToThisWindow` / `AttachThreadInput`+`SetForegroundWindow` 都改不了"不可用"这个事实 |

**v0.1.5 改了什么**：唤回时在 `ShowWindow` 之后**再走一遍系统的"还原/最大化"路径**：

- 原状态是**最大化** → 发 `WM_SYSCOMMAND(SC_MAXIMIZE)`（否则 `SC_RESTORE` 会把最大化窗口降级成普通尺寸）；
- 其余 → 发 `WM_SYSCOMMAND(SC_RESTORE)`。

实测效果（关闭到托盘 → 合成真实左键点击真实悬浮球）：

```
t=1s  visible=True  render=False  ink 不变      ← 死帧
t=2s  visible=True  render=False  ink 不变      ← 死帧
t=3s  visible=True  render=True   hash 变化     ← 内容重建完成
...
输入测试：点击命中 Chrome_RenderWidgetHostHWND → 画面响应 = True
```

**仍然做不到"点一下立刻能用"**：内容重建是 Chromium 的异步过程，最快 ~2 s，实测波动 **2~8 s**（偶发更久）。这段时间窗口已经显示、标题栏/快捷键/任务栏都正常，但网页区域是旧画面。**这是 DSH（Electron `win.hide()` 销毁 WebContents）的行为，外部只能缩短、无法消除。**想要"点一下立刻可用"，日常请用**最小化到任务栏**，而不是关闭到托盘。

### v0.1.4：删掉"双击重启"，让单击真正唤回"关闭到托盘"的窗口

> ⚠️ 本节的"修复"经 v0.1.5 实测**判定为无效**（判据错误），实现已被 v0.1.5 取代。保留原文仅作记录。

**目标**：不要"双击重启 DSH"这个破坏性兜底，只要"单击悬浮球就把关闭到托盘的窗口弹回来并可用"。

**做法与结论**：

1. **移除双击重启**：`AllowRestart` / `-NoRestart` / `Invoke-RestartDsh` 全部删除；悬浮球现在**任何点击都不会结束任何进程**（脚本里已无 `Stop-Process`）。
2. **推翻 v0.1.3 的"外部无法恢复"结论**：v0.1.3 是在显示窗口后只等 ~0.3 s 就检查网页内容子窗口，那时 Chromium 还没重建完，于是写下 `STILL FROZEN`。**实测多等几秒内容就会自己回来**：
   - 先按原状态 `ShowWindow`（最小化 `SW_RESTORE` / 最大化 `SW_SHOWMAXIMIZED` / 其余 `SW_SHOW`）；
   - 补 `WM_ACTIVATE(WA_ACTIVE)` + `WM_NCACTIVATE`，再 `SetForegroundWindow`，最后 `WM_SIZE` 让 Chromium 重排；
   - 之后**在后台**（`DispatcherTimer`，不阻塞球的 UI 线程）轮询"网页内容子窗口回来了 **且** 像素帧在变"，判定真的活了才写成功日志（最长 24 s）。
3. **实测数据（真实"关闭到托盘"路径 = 向主窗口发 `WM_CLOSE`，等价用户点 X）**：

   | 场景 | 结果 |
   |---|---|
   | 关闭到托盘 → 调插件唤回（连跑 5 次） | 5/5 成功：窗口显示后网页内容在 **~3.2s / ~4.8s / ~5.7s / 8.1s / 9.5s** 恢复；最坏一次 25s+ 才出画 |
   | 关闭到托盘 → **合成真实左键点击真实悬浮球窗口** | 窗口立刻显示（`visible=True`），内容 **~4s** 恢复（`render=True`，画面逐秒在变） |
   | 最小化到任务栏 → 调插件唤回 | `iconic=True → False`，内容立即可用（WebContents 没被销毁） |
   | DSH 正常可见时唤回 | 正确跳过（no-op），不动窗口 |
   | 每次唤回能否输入 | 内容子窗口 `Chrome_RenderWidgetHostHWND` 确实重建（`render=False → True`），且像素指纹逐秒变化 = 渲染器在出帧 |

4. **顺带修掉的坑**：`-RestoreOnly` 之前不看状态就动手，自检会平白显示一次窗口；现在它默认只在"DSH 不可见 / 最小化"时执行，需要强制时加 `-ForceShow`。
5. **仍然存在的客观限制**（DSH 侧行为，不是插件能修的）：关闭到托盘后，窗口本身瞬间回来，但**网页画面要 3~10 s（偶发更久）**才恢复，这段时间窗口里是旧画面、点了没反应；最小化到任务栏则没有这个延迟。
6. **装进真实 desktop profile 后的验收（合成点击，日志为准）**：

   ```
   [host]   plugin loaded: installRoot=D:\… icon=…\resources\icon.png appExe=…\DeepSeek Harness.exe targetPid=35316
   [host]   floating window started: powershell.exe pid=40500 (startup)
   [window] icon loaded / floating ball ready            ← DSH 可见，球保持隐藏
   [window] show floating ball                           ← 关闭到托盘后球自己出现
   [window] activate: bring DSH back                     ← 合成左键点击悬浮球
   [window] restore: hwnd=330322 visible=False … contentAlive=False
   [window] restore: after hwnd=330322 visible=True …    ← 窗口按原状态（最大化）回来了
   [window] activate: window is shown; web content is still rebuilding (waiting in the background)
   [window] hide floating ball                           ← 球自己收起
   ```

   `plugin_manager install_bundle` → 宿主半区当场加载（无需重启 DSH）、球进程由宿主拉起、`show/hide` 与唤回全部按预期走通。

### v0.1.3：关闭到托盘后"窗口回来了但点什么都没反应" —— 根因在 DSH 自己，插件改为分层处理

> ⚠️ 本节的**结论部分已被 v0.1.4 修正**：当时认为"外部无法恢复、只能重启 DSH"，实测证明只是**等待时间不够**。下面保留原文作为记录，请结合 v0.1.4 一起看。

**现象**：关闭到托盘后点悬浮球，窗口是出现了，但**窗口里任何操作都没反应**。

**根因（实测确认，不是推断）**：DSH 关闭到托盘走的是 Electron 的 `win.hide()`，它会把 **Chromium 的网页内容子窗口 `Chrome_RenderWidgetHostHWND` 一起销毁**：

```
窗口可见时：  子窗口 329766 Chrome_RenderWidgetHostHWND  vis=True   ← 真正接收输入的那个窗口
应用 hide() 后： 该子窗口消失，只剩 Intermediate D3D Window          ← 只剩一帧旧画面
```

于是我们看到的其实是**旧画面**（所以"显示不全"那次看起来像左上角一块，就是旧的最大化画面被裁进了更小的窗口），而**输入没有任何接收者**。能用 Win32 唤起的只有那个空壳窗口，网页内容必须由 Electron 自己 `WebContents::WasShown()` 重建 —— 这一点外部代码做不到。

**这一轮逐一实测、全部无效的手段**（每种都跑在真实 WM_CLOSE 关闭到托盘的窗口上）：

| 手段 | 结果 |
|---|---|
| `ShowWindow(SW_SHOW/SW_SHOWMAXIMIZED)` + 发 `WM_SIZE` 让 Chromium 重排 | 窗口可见，内容仍冻结（截图哈希在点击前后完全一致） |
| 补发 `WM_SHOWWINDOW(TRUE)` | 无效 |
| 最小化→还原一个来回 | 无效 |
| `SetWindowPos(SWP_FRAMECHANGED)` | 无效 |
| `WM_ACTIVATE(WA_ACTIVE)` | 无效 |
| 再启动一次 DSH exe（单实例 `second-instance` → `focusPrimaryWindow`） | **窗口根本没被显示**（实测最小化后重启 exe，窗口依旧 `iconic=True` → 说明该回调在本机不执行） |
| `dsh://open` 协议启动 | 同上，窗口没被显示 |
| 直接向 `Electron_NotifyIconHostWindow` 发托盘回调消息（v3/v4 两种布局、id 0–8、`WM_APP+0…511` 与 `WM_USER+0…255` 全扫） | 无命中（该消息号应是运行时注册的） |
| 用 `Shell_NotifyIconGetRect` 找到托盘图标坐标后合成真实点击 | 坐标正确（落在 `TrayNotifyWnd` 内），但窗口未恢复 |
| 显式显示网页内容子窗口 | 子窗口已被销毁，没得可显 |

**v0.1.3 改成了什么**（都实跑验证过）：

1. **进程改为 DPI 感知**：之前 PowerShell 进程 DPI 不感知，`SetCursorPos` 的坐标会被系统再缩放 1.5 倍 → 合成点击会点到屏幕外（这是"点托盘没反应"的测试侧原因）。现在坐标与 `Shell_NotifyIconGetRect` 同一套物理像素，悬浮球渲染也更清晰（日志会写 `DPI aware`）。
2. **冻结检测**：`Test-DshFrozen` 用"网页内容子窗口还在不在"判断窗口是不是成了空壳（实测：可见时 `HasRenderWidget=True`，应用 hide 后 `False`），日志里会明确写出来。
3. **唤回顺序**：先按原状态显示窗口（最小化 → `SW_RESTORE`，最大化 → `SW_SHOWMAXIMIZED`，其余 → `SW_SHOW`，再补 `WM_SIZE`）→ 若检测到**冻结**，就去**点 DSH 自己的托盘图标**（`Shell_NotifyIconGetRect` + 合成真实点击，等于用户手动点托盘那一下）→ 仍冻结就在日志里明确写 `STILL FROZEN`。
4. **单击只做非破坏性的唤回**：按原状态显示窗口 → 若检测到冻结就去点 DSH 自己的托盘图标 → 仍冻结则在日志里写明"请用 DSH 托盘图标恢复"（**单击不会结束任何进程**）。
   **双击**才是兜底的"重启 DSH"，而且**默认关闭**：要它生效需在 `settings.json` 里显式设 `"allowRestart": true`（并重启一次 DSH）。理由：重启会结束所有 `DeepSeek Harness.exe` 进程、中断正在跑的一轮对话，对分发给别人用的插件来说不该默认开启。

**结论 / 建议**（已过时，见 v0.1.4）：

- ~~关闭到托盘的窗口外部无法恢复输入~~ → **实测可以恢复，只是要等 3~10 s**；最小化到任务栏则是点完即用。
- ~~双击球重启 DSH 回到可用状态~~ → v0.1.4 已删除这条路径，单击即可。

### v0.1.2 修复：最小化点击失效 + 最大化后隐藏再唤回"只显示左上角一块"（已修 + 已实测）

v0.1.1 把"最小化"和"隐藏到托盘"合并进 `EnumWindows` 后，引入两个新问题：

| 症状 | 根因 |
|---|---|
| **最小化**后点球不回来 | `FindMainWindows` 用 `GetWindowRect` 做"尺寸像主窗口"的过滤，而**最小化时 `GetWindowRect` 返回的是"图标矩形"**（约 160×28，坐标还在 -32000），于是最小化的主窗口被自己的过滤器漏掉了 |
| 关闭到托盘后点球回来了，但**只显示最大化情况下的左上角一块** | 之前一律 `ShowWindow(h, SW_RESTORE)`，而 SW_RESTORE 会把"隐藏前已最大化"的窗口**降级成普通尺寸**；渲染器还按最大化尺寸出图 ⇒ 只能看到左上角一块（同时外部调用 `ShowWindow` 不走 Electron 的 `NativeWindow::Show()`，WebContents 也没拿到新的可见性/尺寸通知） |

**修法**：

1. 尺寸判据改读 `GetWindowPlacement().normalPosition`（最小化窗口也有正确的常规尺寸），并且**最小化的窗口直接放行**，不做尺寸过滤；
2. 显示时**先读状态再决定**：`IsIconic`/`showCmd==2` → `SW_RESTORE`；`IsZoomed`/`showCmd==3` → `SW_SHOWMAXIMIZED`；否则 `SW_SHOW`（按原样显示，不改最大化/普通状态）；
3. 显示后给窗口发一记 `WM_SIZE(SIZE_RESTORED, 当前客户区大小)` + `RedrawWindow`，让 Chromium 按现在的尺寸重新排版重画（`NudgeRelayout`）。

**实测结果**（合成鼠标点击，两个用例都 PASS）：

```
=== A) minimized -> click ball ===
before click: visible=True iconic=True
A: clicked ball at 1644,277
  restore: hwnd=395272 visible=True iconic=True zoomed=False showCmd=2
  restore: after  hwnd=395272 visible=True iconic=False
A result: visible=True iconic=False  => PASS

=== B) maximized then hidden -> click ball ===
maximized: zoomed=True showCmd=3 client=1706x1018
before click: visible=False iconic=False zoomed=True showCmd=3
B: clicked ball at 1644,277
  restore: hwnd=395272 visible=False iconic=False zoomed=True showCmd=3
  restore: after  hwnd=395272 visible=True iconic=False zoomed=True
B result: visible=True zoomed=True showCmd=3 client=1706x1018 (was 1706x1018)  => PASS
```

用例 B 还截了图逐像素确认**画面完整**（左侧栏 / 顶栏 / 对话区全部正常铺满，不是左上角一块）。

### v0.1.1 修复：关闭到托盘后点击回不去（已修 + 已实测）

**现象**：最小化到任务栏时点悬浮球能回窗口；**关闭到托盘后点了没反应**。

**根因**（拿日志和实测确认，不是猜）：

1. 收进托盘的窗口只是被 `ShowWindow(SW_HIDE)` 藏起来，**句柄仍然有效**；
2. 但 `.NET Process.MainWindowHandle` 只认**可见**的顶层窗口 —— 窗口隐藏时它返回 `0`（实测：`SW_HIDE` 之后 `MainWindowHandle=0`），于是代码以为"没有窗口"，走了兜底；
3. 兜底"再启动一次 DSH exe"依赖 DSH 的 `second-instance` → `focusOwner`，而**它并不会把已隐藏的主窗口 `show()` 回来** —— 实测把窗口隐藏后启动 DSH exe、等 7 秒：`visible = False`。

**修法**：不再依赖 `.NET` 的判断，自己 `EnumWindows` 按
`进程 pid + 类名 Chrome_WidgetWin_1 + GW_OWNER==0 + 非 WS_EX_TOOLWINDOW + 尺寸≥200×150`
把主窗口找出来（**可见与否都找**），再 `ShowWindow(h, SW_RESTORE)`，若仍不可见补一发 `SW_SHOW`，最后 `SetForegroundWindow`。

**实测结果**（合成鼠标事件真的点了球）：

```
DSH hidden: visible=False
ball window handle = 3016024  rect=1608,241,1680,313
left click synthesised on the ball
DSH visible after the click = True
--- 球自己的日志 ---
activate: bring DSH back
restore: handles=395272 visibleBefore=False     ← 找到了隐藏窗口的句柄
activate: ShowWindow + SetForegroundWindow
hide floating ball                             ← 球自己收起
```

顺带修掉一个隐雷：**`floating-window.ps1` 一旦丢掉 UTF-8 BOM，PowerShell 5.1 就会按 ANSI 读，中文注释会被读坏、甚至被当成代码而报语法错误**（本次就踩了：编辑文件后 BOM 被抹掉，球直接崩在解析阶段）。现在宿主半区在每次起窗口进程前都会检查并补上 BOM（`ensureUtf8Bom`）。

### 还没有端到端验证的部分

- **真手点一次悬浮球 / 真切一次"关闭"按钮**：已用合成鼠标事件完整点过（最小化 → 点击恢复；最大化+隐藏 → 点击恢复成最大化且画面完整），但真人的手感、双击/连点、以及点 DSH 自己的关闭按钮走一遍没测（"收进托盘"是用 `ShowWindow(SW_HIDE)` 等价复现的）。
- **真把 DSH 收进托盘**：已用 `ShowWindow(SW_HIDE)` 把**你真实的 DSH 主窗口**隐藏来复现（多次，每次几秒，随后都自动/兜底恢复了），等价于"关闭到托盘"；也实测过**最小化**（`SW_MINIMIZE`）与**先最大化再隐藏**两种前置状态。
- **手感与视觉细节**（白圆边缘、图标大小、是否抢焦点、拖动是否跟手）：需要你自己看一眼。
- **`includeMinimized=true` 的下半条**（最小化到任务栏出球）已实测：`SW_MINIMIZE` 后球确实出现，点击后 `iconic` 从 `True` 变 `False`。

排错入口：`%USERPROFILE%\.dsh\dsh-float-ball\float-ball.log`（UTF-8；含解析到的路径、候选 pid、`restore: handles=… visibleBefore=…`、每次 show/hide 与 activate 走的分支），或第 5 节的 `/dsh-float-ball/log.txt`。

已经**读盘确认过**的事实（不是猜的）：

- DSH 桌面端的 profile 与插件契约：`~/.dsh/profiles/desktop/package.json`（`dsh.profile.bundles`）、已装插件 `dsh-whale-widget` 的 `package.json` / `cordis.patch.yml` / `lib/index.js`（宿主半区形状：`export default { name, apply(root) }`、`root.inject(['webServer'], …)`、`ctx.webServer.register({ kind:'exact', path, handler })`、`root.effect` 清理）；
- DSH 桌面端把宿主进程起成 `DeepSeek Harness.exe` + `ELECTRON_RUN_AS_NODE=1`，并注入 `DSH_DESKTOP_NODE_EXECUTABLE`（`app.asar` 内可搜到这两处）；
- 主窗口有 `hide()` 到托盘的路径、有 `app.requestSingleInstanceLock()` + `second-instance` → `focusOwner`（JSDoc：*focus or recreate the primary window after a later launch*）；
- 图标确实存在：`<安装目录>\resources\icon.png`（1024×1024 深色虎鲸标，我看过图）、`<安装目录>\resources\tray.ico`；
- 官方文档把 `BrowserWindow` / 托盘注册表列为**非公开契约**（见第 7 节引用）。

**另外还没验过**：第 5 节那几条 `/dsh-float-ball/*` 自检路由（安装后没有实际请求过）、`/dsh-float-ball/settings.json` 的写入与随之而来的窗口重启。

想快速看一眼外观（不必真去最小化）：把 `%USERPROFILE%\.dsh\dsh-float-ball\settings.json` 里的 `alwaysVisible` 设为 `true`，然后 POST `/dsh-float-ball/restart.json`（或重启 DSH）即可。
