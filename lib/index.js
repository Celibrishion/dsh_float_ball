/**
 * dsh-float-ball —— DSH 桌面端「托盘悬浮球」插件（宿主半区）
 *
 * 做什么：
 *   把 DSH 最小化/收进托盘后，桌面上出现一个**白色圆形悬浮球**，中间是 DSH 的虎鲸图标；
 *   左键可拖动到任意位置（位置会被记住）；**单击**它就把 DSH 主窗口唤回前台。
 *
 * 怎么做的（一句话）：
 *   本文件只负责「找路径 → 起窗口进程 → 守进程 → 存配置 → 暴露自检路由」，
 *   真正的窗口是 assets/floating-window.ps1（PowerShell + WPF）画出来的。
 *
 * 为什么窗口不在这个进程里建：
 *   DSH 官方《插件开发》文档明确把 Electron `BrowserWindow`、托盘注册表、private Node helper、
 *   `ELECTRON_RUN_AS_NODE` 都列为**不属于第三方契约**的 Desktop 内部实现；插件半区跑在 DSH 的
 *   Node 宿主进程里，也没有窗口 API。所以这里用「宿主半区 spawn 一个自带窗口的进程」这条
 *   已被生态验证过的路子（dsh-float-chat 用的是 WinForms+WebView2 exe，这里用免编译的 WPF）。
 *
 * 只用公开契约：profile bundle（package.json 的 dsh.bundle + cordis.patch.yml）、
 * 宿主服务 `webServer`、以及可选服务 `connection` 的请求栅栏。
 */

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

// ─────────────────────────────────────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────────────────────────────────────
const PACKAGE_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const WINDOW_SCRIPT = path.join(PACKAGE_ROOT, 'assets', 'floating-window.ps1')

const DSH_HOME = process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
const DATA_DIR = path.join(DSH_HOME, 'dsh-float-ball')
const SETTINGS_FILE = path.join(DATA_DIR, 'settings.json')
const LOG_FILE = path.join(DATA_DIR, 'float-ball.log')
const LOG_MAX_BYTES = 1024 * 1024

const DEFAULT_SETTINGS = {
  /** 总开关：false = 完全不起悬浮球进程 */
  enabled: true,
  /** 悬浮球直径（DIP） */
  size: 72,
  /** 轮询 DSH 主窗口是否可见的间隔（毫秒） */
  pollMs: 700,
  /** 调试用：DSH 可见时也一直显示（用来快速验证外观/拖动，不必真去最小化） */
  alwaysVisible: false,
  /** true = "最小化到任务栏"也出球；false = 只在被收进托盘（窗口隐藏）时出球 */
  includeMinimized: true,
  /** 插件加载后延迟多久再起窗口进程（毫秒），避免和 DSH 启动抢资源 */
  startDelayMs: 1500,
  /** 覆盖图标路径（默认自动用 <安装目录>\resources\icon.png） */
  iconPath: '',
  /** 覆盖 DSH 可执行文件路径（唤回 DSH 时用） */
  appExePath: '',
  /** 覆盖"DSH 主进程 pid"（默认用 process.ppid） */
  targetPid: 0,
}

const ROUTE_PREFIX = '/dsh-float-ball'

// ─────────────────────────────────────────────────────────────────────────────
// 日志
// ─────────────────────────────────────────────────────────────────────────────
function ensureDataDir() {
  try {
    fs.mkdirSync(DATA_DIR, { recursive: true })
  } catch (err) {
    /* 只读环境：忽略，日志会退化成 console */
  }
}

let logSink = null

function appendLog(message) {
  const line = '[' + new Date().toISOString() + '] [host] ' + message
  try {
    ensureDataDir()
    try {
      if (fs.statSync(LOG_FILE).size > LOG_MAX_BYTES) fs.rmSync(LOG_FILE, { force: true })
    } catch (err) {
      /* 文件还不存在 */
    }
    fs.appendFileSync(LOG_FILE, line + os.EOL)
  } catch (err) {
    /* ignore */
  }
  try {
    if (typeof logSink === 'function') logSink(line)
  } catch (err) {
    /* ignore */
  }
  return line
}

function readLogTail(maxLines) {
  try {
    const text = fs.readFileSync(LOG_FILE, 'utf8')
    const lines = text.split(/\r?\n/).filter((s) => s.length > 0)
    return lines.slice(Math.max(0, lines.length - maxLines))
  } catch (err) {
    return []
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 配置
// ─────────────────────────────────────────────────────────────────────────────
function clampInt(value, min, max, fallback) {
  const n = Number(value)
  if (!Number.isFinite(n)) return fallback
  const rounded = Math.round(n)
  if (rounded < min) return min
  if (rounded > max) return max
  return rounded
}

function normalizeSettings(raw) {
  const source = raw && typeof raw === 'object' ? raw : {}
  return {
    enabled: source.enabled === undefined ? DEFAULT_SETTINGS.enabled : source.enabled !== false,
    size: clampInt(source.size, 40, 160, DEFAULT_SETTINGS.size),
    pollMs: clampInt(source.pollMs, 150, 5000, DEFAULT_SETTINGS.pollMs),
    alwaysVisible: source.alwaysVisible === true,
    includeMinimized:
      source.includeMinimized === undefined ? DEFAULT_SETTINGS.includeMinimized : source.includeMinimized !== false,
    startDelayMs: clampInt(source.startDelayMs, 0, 60000, DEFAULT_SETTINGS.startDelayMs),
    iconPath: typeof source.iconPath === 'string' ? source.iconPath : '',
    appExePath: typeof source.appExePath === 'string' ? source.appExePath : '',
    targetPid: clampInt(source.targetPid, 0, 0x7fffffff, DEFAULT_SETTINGS.targetPid),
  }
}

function readSettings() {
  try {
    const text = fs.readFileSync(SETTINGS_FILE, 'utf8')
    return normalizeSettings(JSON.parse(text))
  } catch (err) {
    return normalizeSettings(null)
  }
}

function writeSettings(settings) {
  ensureDataDir()
  const tmp = SETTINGS_FILE + '.tmp'
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + '\n', 'utf8')
  fs.renameSync(tmp, SETTINGS_FILE)
}

// ─────────────────────────────────────────────────────────────────────────────
// 找 DSH 安装目录 / 图标 / 可执行文件
//   DSH 桌面端把宿主进程起成 `DeepSeek Harness.exe` + ELECTRON_RUN_AS_NODE=1，
//   并会在环境里留下 DSH_DESKTOP_NODE_EXECUTABLE（就是那个 exe 的绝对路径）。
// ─────────────────────────────────────────────────────────────────────────────
function fileExists(p) {
  try {
    return Boolean(p) && fs.existsSync(p)
  } catch (err) {
    return false
  }
}

/**
 * Windows PowerShell 5.1 把**没有 BOM 的 .ps1 当作 ANSI（本机代码页）**读：
 * 脚本里的中文注释/字符串会被读坏，注释甚至可能被读成代码而抛语法错误（踩过一次）。
 * 所以起窗口进程前兜一道：缺 BOM 就补上。这样以后任何编辑器/工具重写脚本都不会再踩。
 */
function ensureUtf8Bom(file) {
  try {
    const bytes = fs.readFileSync(file)
    if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return false
    fs.writeFileSync(file, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), bytes]))
    appendLog('window script had no UTF-8 BOM; added one (required by PowerShell 5.1)')
    return true
  } catch (err) {
    appendLog('could not ensure UTF-8 BOM on window script: ' + String(err && err.message))
    return false
  }
}

function findAppExe(root, envExe) {
  if (fileExists(envExe) && /\.exe$/i.test(envExe)) return envExe
  if (!root) return ''
  const exec = process.execPath || ''
  if (exec && /\.exe$/i.test(exec) && path.dirname(exec) === root && fileExists(exec)) return exec
  try {
    const skip = /^(node|elevate|unins|uninstall|setup|update|squirrel|crashpad)/i
    const names = fs
      .readdirSync(root)
      .filter((name) => /\.exe$/i.test(name) && !skip.test(name))
      .sort()
    if (names.length > 0) return path.join(root, names[0])
  } catch (err) {
    /* ignore */
  }
  return ''
}

function resolveRuntime(settings) {
  const envExe = String(process.env.DSH_DESKTOP_NODE_EXECUTABLE || '')

  const roots = []
  const pushRoot = (dir) => {
    if (dir && !roots.includes(dir)) roots.push(dir)
  }
  // 线索一：DSH 桌面端给宿主注入的 exe 绝对路径
  if (envExe) pushRoot(path.dirname(envExe))
  // 线索二：宿主进程本身就是 `DeepSeek Harness.exe`（ELECTRON_RUN_AS_NODE=1）
  if (process.execPath) pushRoot(path.dirname(process.execPath))
  // 线索三：宿主的入口脚本在 app.asar 里，祖先链同样指向安装根
  //   （实测命令行：`"…\DeepSeek Harness.exe" --expose-internals …\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js …\app.asar\dsh …`）
  for (const arg of process.argv.slice(1, 5)) {
    if (typeof arg === 'string' && arg.length > 0 && arg.includes(path.sep)) pushRoot(path.dirname(arg))
  }
  if (process.resourcesPath) pushRoot(String(process.resourcesPath))
  // 每条线索都往上找若干层（argv 里的路径埋得比较深）
  for (const dir of roots.slice()) {
    let cursor = dir
    for (let i = 0; i < 8; i += 1) {
      const parent = path.dirname(cursor)
      if (parent === cursor) break
      cursor = parent
      pushRoot(cursor)
    }
  }

  let root = ''
  let icon = ''
  for (const dir of roots) {
    const png = path.join(dir, 'resources', 'icon.png')
    const ico = path.join(dir, 'resources', 'tray.ico')
    const asar = path.join(dir, 'resources', 'app.asar')
    if (fileExists(png) || fileExists(ico) || fileExists(asar)) {
      root = dir
      icon = fileExists(png) ? png : fileExists(ico) ? ico : ''
      break
    }
  }

  const appExe = settings.appExePath && fileExists(settings.appExePath)
    ? settings.appExePath
    : findAppExe(root, envExe)

  const iconPath = settings.iconPath && fileExists(settings.iconPath) ? settings.iconPath : icon

  return { root, icon: iconPath, appExe, script: WINDOW_SCRIPT, envExe }
}

// ─────────────────────────────────────────────────────────────────────────────
// 悬浮球进程管理
// ─────────────────────────────────────────────────────────────────────────────
function powerShellCandidates() {
  const list = []
  const sysRoot = process.env.SystemRoot || process.env.windir || 'C:\\Windows'
  list.push(path.join(sysRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'))
  list.push('powershell.exe')
  list.push('pwsh.exe')
  return list
}

function createWidgetManager() {
  const manager = {
    child: null,
    disposed: false,
    restartTimer: null,
    startTimer: null,
    generation: 0,
    failures: 0,
    startedAt: 0,
    lastError: '',
    settings: normalizeSettings(null),
    runtime: { root: '', icon: '', appExe: '', script: WINDOW_SCRIPT, envExe: '' },

    targetPid() {
      const override = Number(this.settings.targetPid)
      if (Number.isInteger(override) && override > 0) return override
      const ppid = Number(process.ppid)
      return Number.isInteger(ppid) && ppid > 0 ? ppid : 0
    },

    args() {
      const list = [
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        WINDOW_SCRIPT,
        '-StateDir',
        DATA_DIR,
        '-TargetPid',
        String(this.targetPid()),
        '-Size',
        String(this.settings.size),
        '-PollMs',
        String(this.settings.pollMs),
      ]
      // 空字符串参数在 `powershell -File` 下可能被吞掉，所以留空时直接不传
      // （脚本里对应参数本来就有 '' 默认值）
      if (this.runtime.icon) list.push('-IconPath', this.runtime.icon)
      if (this.runtime.appExe) list.push('-AppExe', this.runtime.appExe)
      if (this.settings.alwaysVisible) list.push('-AlwaysVisible')
      if (this.settings.includeMinimized) list.push('-IncludeMinimized')
      return list
    },

    scheduleStart(delayMs, reason) {
      if (this.disposed || !this.settings.enabled) return
      if (this.child || this.startTimer) return
      this.startTimer = setTimeout(() => {
        this.startTimer = null
        this.start(reason)
      }, Math.max(0, delayMs))
      if (this.startTimer.unref) this.startTimer.unref()
    },

    scheduleRestart(reason) {
      if (this.disposed || this.restartTimer || !this.settings.enabled) return
      this.failures += 1
      if (this.failures > 8) {
        appendLog('floating window kept failing (' + this.failures + 'x, last: ' + reason + '), giving up')
        return
      }
      const delay = Math.min(30000, 1000 * Math.pow(2, Math.min(this.failures - 1, 5)))
      appendLog('restart floating window in ' + delay + 'ms (' + reason + ')')
      this.restartTimer = setTimeout(() => {
        this.restartTimer = null
        this.start('restart')
      }, delay)
      if (this.restartTimer.unref) this.restartTimer.unref()
    },

    start(reason) {
      if (this.disposed || this.child || !this.settings.enabled) return
      if (!fileExists(WINDOW_SCRIPT)) {
        this.lastError = 'window script missing: ' + WINDOW_SCRIPT
        appendLog(this.lastError)
        return
      }
      ensureUtf8Bom(WINDOW_SCRIPT)

      // 每一轮 start 有自己的 generation：stop()/dispose 会让它失效，
      // 于是"被我们主动杀掉"不会再触发自动重启、也不会累计失败次数。
      const generation = (this.generation += 1)
      const candidates = powerShellCandidates()
      let index = 0

      const attempt = () => {
        if (this.disposed || this.child || this.generation !== generation) return
        if (index >= candidates.length) {
          this.lastError = 'no usable PowerShell host found'
          appendLog(this.lastError)
          this.scheduleRestart('no powershell')
          return
        }
        const exe = candidates[index]
        index += 1

        let proc = null
        try {
          proc = spawn(exe, this.args(), {
            cwd: DATA_DIR,
            windowsHide: true,
            stdio: ['ignore', 'pipe', 'pipe'],
            env: { ...process.env },
          })
        } catch (err) {
          this.lastError = 'spawn failed: ' + String(err && err.message)
          appendLog(this.lastError)
          attempt()
          return
        }

        let started = false

        proc.once('error', (err) => {
          if (started) {
            appendLog('floating window error: ' + String(err && err.message))
            return
          }
          this.lastError = 'spawn error (' + String(err && err.code) + '): ' + String(err && err.message)
          appendLog('cannot start ' + exe + ': ' + this.lastError)
          if (err && err.code === 'ENOENT') {
            attempt()
            return
          }
          this.scheduleRestart('spawn error')
        })

        proc.once('spawn', () => {
          started = true
          if (this.generation !== generation || this.disposed) {
            try {
              proc.kill()
            } catch (err) {
              /* ignore */
            }
            return
          }
          const startedAt = Date.now()
          this.child = proc
          this.startedAt = startedAt
          this.lastError = ''
          appendLog('floating window started: ' + exe + ' pid=' + proc.pid + ' (' + reason + ')')
          try {
            proc.stdout.on('data', () => {})
          } catch (err) {
            /* ignore */
          }
          try {
            proc.stderr.on('data', (chunk) => {
              const text = String(chunk).trim()
              if (text) appendLog('window stderr: ' + text.slice(0, 800))
            })
          } catch (err) {
            /* ignore */
          }
          proc.once('exit', (code, signal) => {
            if (this.child === proc) this.child = null
            appendLog('floating window exited: code=' + code + ' signal=' + signal)
            if (this.generation !== generation || this.disposed) return
            if (Date.now() - startedAt > 60000) this.failures = 0
            this.scheduleRestart('exited')
          })
        })
      }

      attempt()
    },

    stop() {
      // 让这一轮 start 的 exit 回调失效（否则会被当成"意外退出"而自动重启）
      this.generation += 1
      if (this.restartTimer) {
        clearTimeout(this.restartTimer)
        this.restartTimer = null
      }
      if (this.startTimer) {
        clearTimeout(this.startTimer)
        this.startTimer = null
      }
      const proc = this.child
      this.child = null
      if (!proc) return
      appendLog('stopping floating window pid=' + proc.pid)
      try {
        proc.kill()
      } catch (err) {
        /* ignore */
      }
      const hardKill = setTimeout(() => {
        try {
          proc.kill('SIGKILL')
        } catch (err) {
          /* ignore */
        }
      }, 2500)
      if (hardKill.unref) hardKill.unref()
    },

    /** 配置变了：路径/尺寸/轮询等参数要靠重启窗口进程生效 */
    applySettings(next) {
      const restartNeeded =
        Boolean(this.child) &&
        (next.size !== this.settings.size ||
          next.pollMs !== this.settings.pollMs ||
          next.alwaysVisible !== this.settings.alwaysVisible ||
          next.includeMinimized !== this.settings.includeMinimized ||
          next.iconPath !== this.settings.iconPath ||
          next.appExePath !== this.settings.appExePath ||
          next.targetPid !== this.settings.targetPid)
      const wasDisabled = !this.settings.enabled
      this.settings = next
      if (!next.enabled) {
        this.failures = 0
        this.stop()
        return
      }
      if (wasDisabled || restartNeeded) {
        this.failures = 0
        this.stop()
        this.scheduleStart(wasDisabled ? 0 : 200, wasDisabled ? 'enabled' : 'settings-changed')
        return
      }
      // 之前放弃过 / 进程正好不在：给一次重新起来的机会
      if (!this.child) {
        this.failures = 0
        this.scheduleStart(200, 'settings-changed-idle')
      }
    },

    status() {
      return {
        running: Boolean(this.child),
        pid: this.child ? this.child.pid : null,
        failures: this.failures,
        lastError: this.lastError,
        startedAt: this.startedAt ? new Date(this.startedAt).toISOString() : null,
      }
    },
  }

  return manager
}

// ─────────────────────────────────────────────────────────────────────────────
// 请求栅栏：只接受本机（回环）来源；有宿主栅栏就委托它
// ─────────────────────────────────────────────────────────────────────────────
function isLoopbackHostname(hostname) {
  const h = String(hostname || '').toLowerCase().replace(/^\[/, '').replace(/\]$/, '')
  if (!h) return false
  if (h === 'localhost' || h.endsWith('.localhost')) return true
  if (h === '::1') return true
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h)
  if (!m) return false
  if (Number(m[1]) !== 127) return false
  return [m[2], m[3], m[4]].every((part) => Number(part) <= 255)
}

function createRejection(ctx) {
  return function rejected(req, res) {
    const deny = (code) => {
      try {
        res.statusCode = code
        res.end()
      } catch (err) {
        /* ignore */
      }
      return true
    }
    try {
      const headers = (req && req.headers) || {}
      let hostUrl = null
      try {
        hostUrl = new URL('http://' + String(headers.host || ''))
      } catch (err) {
        return deny(403)
      }
      // 这个插件的路由纯粹是本机自检用：一律只认回环
      if (!isLoopbackHostname(hostUrl.hostname)) return deny(403)
      if (String(headers['sec-fetch-site'] || '').toLowerCase() === 'cross-site') return deny(403)
      const origin = headers.origin
      if (typeof origin === 'string' && origin && origin !== 'null') {
        let originUrl = null
        try {
          originUrl = new URL(origin)
        } catch (err) {
          return deny(403)
        }
        if (originUrl.host.toLowerCase() !== hostUrl.host.toLowerCase()) return deny(403)
      }
      let connection = null
      try {
        connection = typeof ctx.get === 'function' ? ctx.get('connection') : null
      } catch (err) {
        connection = null
      }
      if (connection && typeof connection.requestRejection === 'function') {
        let code
        try {
          code = connection.requestRejection(req)
        } catch (err) {
          return deny(403)
        }
        if (code !== undefined && code !== null && code !== false) {
          return deny(typeof code === 'number' ? code : 403)
        }
      }
      return false
    } catch (err) {
      return deny(403)
    }
  }
}

function readJsonBody(req, limitBytes) {
  return new Promise((resolve) => {
    let size = 0
    const chunks = []
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      resolve(value)
    }
    try {
      req.on('data', (chunk) => {
        size += chunk.length
        if (size > (limitBytes || 65536)) {
          finish(null)
          try {
            req.destroy()
          } catch (err) {
            /* ignore */
          }
          return
        }
        chunks.push(chunk)
      })
      req.on('end', () => {
        if (chunks.length === 0) return finish({})
        try {
          finish(JSON.parse(Buffer.concat(chunks).toString('utf8')))
        } catch (err) {
          finish(null)
        }
      })
      req.on('error', () => finish(null))
    } catch (err) {
      finish(null)
    }
  })
}

function sendJson(res, code, value) {
  const body = Buffer.from(JSON.stringify(value, null, 2), 'utf8')
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': String(body.length),
  })
  res.end(body)
}

// ─────────────────────────────────────────────────────────────────────────────
// 插件本体
// ─────────────────────────────────────────────────────────────────────────────
export default {
  name: 'dsh-float-ball',

  apply(root) {
    ensureDataDir()

    if (root && root.logger && typeof root.logger.info === 'function') {
      logSink = (line) => {
        try {
          root.logger.info(line)
        } catch (err) {
          /* ignore */
        }
      }
    }

    const manager = createWidgetManager()
    manager.settings = readSettings()
    manager.runtime = resolveRuntime(manager.settings)

    appendLog(
      'plugin loaded: platform=' + process.platform +
      ' dshHome=' + DSH_HOME +
      ' installRoot=' + (manager.runtime.root || '<unknown>') +
      ' icon=' + (manager.runtime.icon || '<none>') +
      ' appExe=' + (manager.runtime.appExe || '<none>') +
      ' targetPid=' + manager.targetPid(),
    )

    if (process.platform !== 'win32') {
      appendLog('not windows: floating ball is disabled (win32 only)')
    } else if (!manager.settings.enabled) {
      appendLog('disabled by settings (enabled=false)')
    } else {
      manager.scheduleStart(manager.settings.startDelayMs, 'startup')
    }

    // 生命周期：插件卸载（DSH 退出 / 热重载 / 被禁用）时把窗口进程收干净
    if (typeof root.effect === 'function') {
      root.effect(() => () => {
        manager.disposed = true
        manager.stop()
        appendLog('plugin disposed')
      })
    }

    // 路由（自检 / 调参用；全部只允许本机回环访问）
    root.inject(['webServer'], (ctx) => {
      const rejected = createRejection(ctx)
      const disposers = []

      const registerRoute = (route) => {
        const inner = route.handler
        return ctx.webServer.register({
          kind: 'exact',
          path: route.path,
          handler: async (req, res) => {
            if (rejected(req, res)) return
            return inner(req, res)
          },
        })
      }

      disposers.push(
        registerRoute({
          path: ROUTE_PREFIX + '/status.json',
          handler: (req, res) => {
            sendJson(res, 200, {
              ok: true,
              version: 1,
              platform: process.platform,
              supported: process.platform === 'win32',
              dshHome: DSH_HOME,
              dataDir: DATA_DIR,
              installRoot: manager.runtime.root,
              icon: manager.runtime.icon,
              appExe: manager.runtime.appExe,
              windowScript: manager.runtime.script,
              targetPid: manager.targetPid(),
              settings: manager.settings,
              process: manager.status(),
              positionFile: path.join(DATA_DIR, 'position.txt'),
              logFile: LOG_FILE,
              logTail: readLogTail(30),
            })
          },
        }),
      )

      disposers.push(
        registerRoute({
          path: ROUTE_PREFIX + '/settings.json',
          handler: async (req, res) => {
            const method = String((req && req.method) || 'GET').toUpperCase()
            if (method === 'GET') {
              sendJson(res, 200, { ok: true, settings: manager.settings })
              return
            }
            if (method !== 'POST' && method !== 'PUT' && method !== 'PATCH') {
              sendJson(res, 405, { ok: false, error: 'method not allowed' })
              return
            }
            const body = await readJsonBody(req, 8192)
            if (body === null) {
              sendJson(res, 400, { ok: false, error: 'invalid json body' })
              return
            }
            const next = normalizeSettings({ ...manager.settings, ...body })
            try {
              writeSettings(next)
            } catch (err) {
              appendLog('write settings failed: ' + String(err && err.message))
              sendJson(res, 500, { ok: false, error: 'write settings failed: ' + String(err && err.message) })
              return
            }
            manager.runtime = resolveRuntime(next)
            manager.applySettings(next)
            appendLog('settings updated: ' + JSON.stringify(next))
            sendJson(res, 200, { ok: true, settings: next })
          },
        }),
      )

      disposers.push(
        registerRoute({
          path: ROUTE_PREFIX + '/restart.json',
          handler: (req, res) => {
            const method = String((req && req.method) || 'GET').toUpperCase()
            if (method !== 'POST') {
              sendJson(res, 405, { ok: false, error: 'use POST' })
              return
            }
            manager.runtime = resolveRuntime(manager.settings)
            manager.failures = 0
            manager.stop()
            manager.scheduleStart(150, 'manual-restart')
            appendLog('manual restart requested')
            sendJson(res, 200, { ok: true, restarting: true })
          },
        }),
      )

      disposers.push(
        registerRoute({
          path: ROUTE_PREFIX + '/icon.png',
          handler: (req, res) => {
            const icon = manager.runtime.icon
            if (!icon) {
              res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
              res.end('no icon resolved')
              return
            }
            try {
              const bytes = fs.readFileSync(icon)
              const type = /\.ico$/i.test(icon) ? 'image/x-icon' : 'image/png'
              res.writeHead(200, {
                'Content-Type': type,
                'Cache-Control': 'no-store',
                'Content-Length': String(bytes.length),
              })
              res.end(bytes)
            } catch (err) {
              res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' })
              res.end('icon read failed: ' + String(err && err.message))
            }
          },
        }),
      )

      disposers.push(
        registerRoute({
          path: ROUTE_PREFIX + '/log.txt',
          handler: (req, res) => {
            const lines = readLogTail(400)
            const body = Buffer.from(lines.join('\n') + '\n', 'utf8')
            res.writeHead(200, {
              'Content-Type': 'text/plain; charset=utf-8',
              'Cache-Control': 'no-store',
              'Content-Length': String(body.length),
            })
            res.end(body)
          },
        }),
      )

      if (typeof root.effect === 'function') {
        root.effect(() => () => {
          for (const dispose of disposers) {
            try {
              dispose()
            } catch (err) {
              /* ignore */
            }
          }
        })
      }
    })
  },
}
