const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8')

const OLD = `	const hideMainWindow = (window) => {
		if (process.platform === "darwin" && window.isFullScreen()) {
			window.once("leave-full-screen", () => {
				if (!window.isDestroyed()) window.hide();
			});
			window.setFullScreen(false);
		} else window.hide();
	};`

// v2 补丁：修正"唤回后任务栏没图标、叉号关不掉"的问题。
// 关键点：插件用 ShowWindow(SW_RESTORE) 唤回，**不会触发 Electron 的 show 事件**，
// 所以恢复逻辑不能挂在 "show" 上；改用 "focus"（窗口被激活时由系统触发）。
const NEW = `	// [dsh-float-ball patch v2] 把"关闭到托盘"从 window.hide() 改成"最小化 + 收起任务栏图标"。
	// 为什么不用 window.hide()：它会触发 Chromium 的 WebContents::WasHidden()，销毁网页内容子窗口
	// (Chrome_RenderWidgetHostHWND)，之后外部进程无法让内容复活（点悬浮球只能得到一帧死画面）。
	// 最小化不会销毁 WebContents，所以唤回后立刻可用。
	// 托盘语义：最小化的同时 setSkipTaskbar(true)，窗口不会留在任务栏/Alt-Tab 里。
	// 恢复：窗口重新获得焦点时（用户点任务栏、点悬浮球、Alt-Tab 回来）把任务栏图标放回去，
	//       并且如果还处于最小化则还原 —— 否则会出现"唤回后任务栏没图标、叉号关不掉"。
	const hideMainWindow = (window) => {
		if (process.platform === "darwin" && window.isFullScreen()) {
			window.once("leave-full-screen", () => {
				if (!window.isDestroyed()) hideMainWindow(window);
			});
			window.setFullScreen(false);
			return;
		}
		if (process.platform === "win32") {
			try { window.__floatBallHiding = true; } catch (error) { /* 忽略 */ }
			try { window.setSkipTaskbar(true); } catch (error) { /* 忽略 */ }
			try { window.minimize(); } catch (error) { /* 忽略 */ }
			setTimeout(() => { try { window.__floatBallHiding = false; } catch (error) { /* 忽略 */ } }, 700);
			return;
		}
		window.hide();
	};`

if (!src.includes(OLD)) { console.error('❌ 未找到 hideMainWindow 原始片段'); process.exit(1) }
let out = src.replace(OLD, NEW)

// 恢复逻辑：从 "show" 改成 "focus"（+ 最小化兜底），并加隐藏期标志位避免自己触发自己
const ANCHOR = `		window.on("closed", () => {
			if (mainWindow === window) mainWindow = void 0;
		});`
const REPL = `		// [dsh-float-ball patch v2] 唤回时恢复任务栏图标 + 如仍最小化则还原。
		// 挂在 "focus" 上（而不是 "show"）：插件/系统用 ShowWindow 唤回的路径不会触发 show 事件。
		const floatBallUnpark = () => {
			try {
				if (window.__floatBallHiding) return;         // 正在隐藏自己，别拆自己的台
				if (window.isDestroyed()) return;
				window.setSkipTaskbar(false);
				if (window.isMinimized()) window.restore();
			} catch (error) { /* 忽略 */ }
		};
		window.on("focus", floatBallUnpark);
		window.on("restore", floatBallUnpark);
		window.on("closed", () => {
			if (mainWindow === window) mainWindow = void 0;
		});`
if (!out.includes(ANCHOR)) { console.error('❌ 未找到 show/closed 锚点'); process.exit(1) }
out = out.replace(ANCHOR, REPL)

fs.writeFileSync(process.argv[3], out, 'utf8')
console.log('✅ 补丁 v2 已生成: ' + process.argv[3])
console.log('   原大小 ' + Buffer.byteLength(src) + ' -> 新大小 ' + Buffer.byteLength(out) + ' (delta ' + (Buffer.byteLength(out) - Buffer.byteLength(src)) + ')')
console.log('   window.hide() 剩余: ' + (out.match(/window\.hide\(\)/g) || []).length + ' （应只保留 darwin 分支与退出路径）')
console.log('   含 floatBallUnpark: ' + out.includes('floatBallUnpark'))
console.log('   含 setSkipTaskbar(false): ' + out.includes('setSkipTaskbar(false)'))
