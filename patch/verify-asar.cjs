// asar 严格验证器（快版）
// 优化点：
//   1) 顺序读一遍数据区（而非 11470 次随机读），复用同一块缓冲，零额外分配
//   2) 参考包同样只顺读一遍
//   3) 只输出摘要（不打印 JSON）
const fs = require('fs')
const crypto = require('crypto')

const BUF = 8 << 20   // 8MB 顺序读缓冲

function openAsar(p) {
  const size = fs.statSync(p).size
  const fd = fs.openSync(p, 'r')
  const h16 = Buffer.alloc(16)
  fs.readSync(fd, h16, 0, 16, 0)
  const headerSize = h16.readUInt32LE(12)
  const jb = Buffer.alloc(headerSize)
  fs.readSync(fd, jb, 0, headerSize, 16)
  let end = jb.length
  while (end > 0) {
    const c = jb[end - 1]
    if (c === 0 || c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09) end--
    else break
  }
  const header = JSON.parse(jb.subarray(0, end).toString('utf8'))
  const leaves = []
  ;(function walk(node, prefix) {
    for (const name of Object.keys(node.files || {})) {
      const f = node.files[name]
      const rel = prefix ? prefix + '/' + name : name
      if (f.files) walk(f, rel)
      else leaves.push({ rel, m: f })
    }
  })(header, '')
  return { fd, size, headerSize, dataStart: 16 + headerSize, leaves }
}

// 顺序读整个数据区，为每个 packed 文件算哈希；顺带与 integrity 比对
function hashAll(h, buffer) {
  const packed = h.leaves.filter((l) => !l.m.unpacked)
  const res = new Map()
  if (packed.length === 0) return res
  const chunk = Buffer.alloc(BUF)
  let pos = h.dataStart + parseInt(packed[0].m.offset, 10)
  const dataEnd = h.dataStart + h.size

  let idx = 0
  let hh = crypto.createHash('sha256')
  let need = packed[0].m.size        // 当前文件还差多少字节

  while (idx < packed.length) {
    const n = Math.min(chunk.length, dataEnd - pos)
    if (n <= 0) break
    fs.readSync(h.fd, chunk, 0, n, pos)
    let start = 0
    while (start < n && idx < packed.length) {
      const take = Math.min(n - start, need)
      hh.update(chunk.subarray(start, start + take))
      start += take
      need -= take
      if (need === 0) {
        res.set(packed[idx].rel, hh.digest('hex'))
        idx++
        if (idx >= packed.length) break
        hh = crypto.createHash('sha256')
        need = packed[idx].m.size
      }
    }
    pos += n
  }
  return res
}

const t0 = process.hrtime.bigint()
const target = openAsar(process.argv[2])
const ref = process.argv[3] ? openAsar(process.argv[3]) : null
const allowArg = process.argv.indexOf('--allow')
const allow = allowArg >= 0 ? new Set(process.argv[allowArg + 1].split(',').map((s) => s.trim()).filter(Boolean)) : new Set()
const tOpen = Number(process.hrtime.bigint() - t0) / 1e6

const t1 = process.hrtime.bigint()
const ha = hashAll(target, null)
const tHashA = Number(process.hrtime.bigint() - t1) / 1e6

let hb = null, tHashB = 0
if (ref) {
  const t2 = process.hrtime.bigint()
  hb = hashAll(ref, null)
  tHashB = Number(process.hrtime.bigint() - t2) / 1e6
}

// 结构检查
let outOfRange = 0, integrityOK = 0, integrityBad = 0, gaps = 0, cursor = 0
const packed = target.leaves.filter((l) => !l.m.unpacked)
for (const l of packed) {
  const off = parseInt(l.m.offset, 10)
  if (off !== cursor) gaps++
  cursor = off + l.m.size
  if (off < 0 || off + l.m.size > target.size - target.dataStart) outOfRange++
  const ih = l.m.integrity && l.m.integrity.hash
  if (!ih) continue
  if (ha.get(l.rel) === ih) integrityOK++
  else integrityBad++
}

// 关键校验：Pickle 头必须符合 asar 规范（这是之前导致 DSH 起不来的原因）
const h16 = Buffer.alloc(16)
fs.readSync(target.fd, h16, 0, 16, 0)
const pk = [h16.readUInt32LE(0), h16.readUInt32LE(4), h16.readUInt32LE(8), h16.readUInt32LE(12)]
const pkOK = pk[0] === 4 && pk[1] === target.headerSize + 8 && pk[2] === target.headerSize + 4 && pk[3] === target.headerSize
if (!pkOK) {
  console.log(`  ❌ asar Pickle 头不符合规范: [${pk.join(', ')}]  期望 [4, ${target.headerSize + 8}, ${target.headerSize + 4}, ${target.headerSize}]`)
  console.log('     → Electron 会无法解析头部并回退到欢迎页，绝不能安装这个包')
  process.exit(1)
}
console.log(`  Pickle 头校验: OK [${pk.join(', ')}]`)

console.log(`待验: ${process.argv[2]}`)
console.log(`  magic=4 headerSize=${target.headerSize} dataStart=${target.dataStart} 文件大小=${target.size}`)
console.log(`  条目 ${target.leaves.length}（packed ${packed.length}）`)
console.log(`  数据区累加=${cursor} 实际=${target.size - target.dataStart} 不连续处=${gaps}`)
console.log(`  越界文件=${outOfRange}  integrity 自洽=${integrityOK}  不自洽=${integrityBad}`)

let ok = integrityBad === 0 && outOfRange === 0 && gaps === 0
if (ref) {
  let diff = 0, missing = 0, unexpected = 0
  const diffList = [], unexpectedList = []
  // 只比对"双方都参与哈希"的文件（unpacked 在两边都跳过，不能算缺失）
  for (const l of target.leaves) {
    const a = ha.get(l.rel)
    const b = hb.get(l.rel)
    if (a === undefined && b === undefined) continue
    if (a === undefined || b === undefined) { missing++; continue }
    if (a !== b) {
      diff++
      if (diffList.length < 8) diffList.push(l.rel)
      if (!allow.has(l.rel)) { unexpected++; if (unexpectedList.length < 8) unexpectedList.push(l.rel) }
    }
  }
  const refPacked = ref.leaves.filter((l) => !l.m.unpacked).length
  console.log(`  与参考包比对: packed=${packed.length}(参考 ${refPacked}) 内容不同=${diff} 缺失=${missing}${diffList.length ? ' 如 ' + diffList.join(', ') : ''}`)
  if (allow.size) console.log(`  允许变化: ${[...allow].join(', ')}；非预期变化=${unexpected}${unexpectedList.length ? ' → ' + unexpectedList.join(', ') : ''}`)
  ok = ok && missing === 0 && (diff === 0 || (allow.size > 0 && unexpected === 0))
}
console.log(`  耗时: 开包 ${tOpen.toFixed(0)}ms + 待验哈希 ${tHashA.toFixed(0)}ms` + (ref ? ` + 参考哈希 ${tHashB.toFixed(0)}ms` : ''))
console.log(ok ? '✅ 验证通过：结构完整、integrity 自洽、内容差异仅限允许范围' : '❌ 验证未通过')
process.exitCode = ok ? 0 : 1
fs.closeSync(target.fd)
if (ref) fs.closeSync(ref.fd)
