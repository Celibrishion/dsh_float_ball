// asar 重打包器 v3（最终）
// 关键事实（实测）：
//   - 数据区 **没有对齐**：每个文件的 offset 严格等于前一个文件的 offset+size，连续无间隙
//   - header 的 JSON 长度 == headerSize（无 padding），dataStart = 16 + headerSize
// 因此：offset 一律用"累加 size"计算；header 允许重新序列化（长度变化则同步更新 headerSize）。
const fs = require('fs')
const crypto = require('crypto')

const BLOCK = 4194304
const arg = (n) => { const i = process.argv.indexOf(n); return i >= 0 ? process.argv[i + 1] : undefined }
const srcPath = arg('--src'), outPath = arg('--out')
const setPath = arg('--set'), contentPath = arg('--content')
if (!srcPath || !outPath) { console.error('need --src --out [--set --content]'); process.exit(1) }

function openAsar(p) {
  const size = fs.statSync(p).size
  const fd = fs.openSync(p, 'r')
  const h16 = Buffer.alloc(16)
  fs.readSync(fd, h16, 0, 16, 0)
  const headerSize = h16.readUInt32LE(12)
  const jsonBuf = Buffer.alloc(headerSize)
  fs.readSync(fd, jsonBuf, 0, headerSize, 16)
  const header = JSON.parse(jsonBuf.toString('utf8'))
  const leaves = []
  ;(function walk(node, prefix) {
    for (const name of Object.keys(node.files || {})) {
      const f = node.files[name]
      const rel = prefix ? prefix + '/' + name : name
      if (f.files) walk(f, rel)
      else leaves.push({ rel, m: f })
    }
  })(header, '')
  return { fd, size, headerSize, jsonText: jsonBuf.toString('utf8'), dataStart: 16 + headerSize, header, leaves }
}
// 注意：官方 asar 解析器要求 integrity 里 **必须** 有 blockSize（正数）和 blocks（数组），
// 小文件也不能省 —— 小文件的 blocks 就是"单元素数组"。
// 实测原始包：{"algorithm":"SHA256","hash":"<整文件>","blockSize":4194304,"blocks":["<每块SHA256>"]}
function integrityFor(buf) {
  const hash = crypto.createHash('sha256').update(buf).digest('hex')
  const blocks = []
  for (let off = 0; off < buf.length; off += BLOCK) {
    blocks.push(crypto.createHash('sha256').update(buf.subarray(off, Math.min(off + BLOCK, buf.length))).digest('hex'))
  }
  if (blocks.length === 0) blocks.push(hash)   // 空文件兜底
  return { algorithm: 'SHA256', hash, blockSize: BLOCK, blocks }
}

const A = openAsar(srcPath)
const packed = A.leaves.filter((l) => !l.m.unpacked)
// 记录原始 offset（后面会被覆盖）
for (const l of packed) l.origOffset = parseInt(l.m.offset, 10)
// 自检原始布局
let cur = 0, gaps = 0
for (const l of packed) { const off = parseInt(l.m.offset, 10); if (off !== cur) gaps++; cur += l.m.size }
console.log(`原始: headerSize=${A.headerSize} dataStart=${A.dataStart} 数据区(累加)=${cur} 实际=${A.size - A.dataStart} 间隙=${gaps}`)

const newContent = setPath ? fs.readFileSync(contentPath) : null
const target = setPath ? A.leaves.find((l) => l.rel === setPath) : null
if (setPath && !target) { console.error('未找到 ' + setPath); process.exit(1) }
if (target) console.log(`替换 ${setPath}: ${target.m.size} -> ${newContent.length} 字节 (delta ${newContent.length - target.m.size})`)

// 计算新布局（无对齐，严格累加）
let cursor = 0
for (const l of packed) {
  l.newOffset = cursor
  cursor += (l.rel === setPath ? newContent.length : l.m.size)
}
const newDataSize = cursor
console.log(`新数据区 = ${newDataSize}`)

// 更新 header 元数据
for (const l of packed) {
  l.m.offset = String(l.newOffset)
  if (l.rel === setPath) { l.m.size = newContent.length; l.m.integrity = integrityFor(newContent) }
}
// 官方解析器对整个 headerString 直接 JSON.parse，所以尾部**不能有多余字节**。
// 原始包的做法就是：headerString.length === headerSize（实测 3392048 === 3392048）。
// 因此这里用空格把 JSON 补齐到 4 字节倍数，headerSize 就等于补齐后的长度。
let jsonText = JSON.stringify(A.header)
const padLen = (4 - (Buffer.byteLength(jsonText, 'utf8') % 4)) % 4
if (padLen > 0) jsonText += ' '.repeat(padLen)
const newJson = Buffer.from(jsonText, 'utf8')
const newHeaderSize = newJson.length
console.log(`JSON: ${A.headerSize} -> ${newJson.length}（+${padLen} 空格补齐；尾部无额外字节），headerSize -> ${newHeaderSize}`)

async function main() {
  const out = fs.createWriteStream(outPath)
  const w = (b) => new Promise((res, rej) => out.write(b, (e) => (e ? rej(e) : res())))
  // Electron 的 asar 头是 V8 Pickle 结构：4 个 uint32。
  // 实测原始包：04 00 00 00 | headerSize+8 | headerSize+4 | headerSize
  // 必须四个都写，只写最后一个会让 Electron 解析头部失败（表现为启动后只剩欢迎页）。
  const h16 = Buffer.alloc(16)
  h16.writeUInt32LE(4, 0)
  h16.writeUInt32LE(newHeaderSize + 8, 4)
  h16.writeUInt32LE(newHeaderSize + 4, 8)
  h16.writeUInt32LE(newHeaderSize, 12)
  await w(h16)
  await w(newJson)

  const buf = Buffer.alloc(BLOCK)
  let written = 0
  for (const l of packed) {
    if (l.newOffset !== written) throw new Error(`错位 ${l.rel}: 需要 ${l.newOffset} 当前 ${written}`)
    if (l.rel === setPath) { await w(newContent); written += newContent.length }
    else {
      let remaining = l.m.size
      let pos = A.dataStart + l.origOffset
      while (remaining > 0) {
        const n = Math.min(BLOCK, remaining)
        fs.readSync(A.fd, buf, 0, n, pos)
        await w(buf.subarray(0, n))
        pos += n; written += n; remaining -= n
      }
    }
  }
  await new Promise((res, rej) => out.end((e) => (e ? rej(e) : res())))
  const expSize = 16 + newHeaderSize + newDataSize
  const gotSize = fs.statSync(outPath).size
  console.log(`写出: 数据区 ${written}（期望 ${newDataSize}） 文件 ${gotSize}（期望 ${expSize}）`)
  if (gotSize !== expSize) { console.error('❌ 大小不符'); process.exit(1) }
  console.log('✅ 重打包完成')
}
main().catch((e) => { console.error('失败:', e.message); process.exit(1) })
