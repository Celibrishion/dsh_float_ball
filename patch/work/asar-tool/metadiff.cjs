// 元数据逐条对比：官方 API 读两个包的 header，比较每个文件的 size/offset/integrity 声明
// 只应有 lib/main.js 不同。
const asar = require('@electron/asar')

const A = process.argv[2], B = process.argv[3]
const allow = process.argv[4] ? new Set(process.argv[4].split(',')) : new Set()

function leaves(p) {
  const h = JSON.parse(asar.getRawHeader(p).headerString)
  const out = new Map()
  ;(function walk(n, pref) {
    for (const k of Object.keys(n.files || {})) {
      const f = n.files[k]
      const r = pref ? pref + '/' + k : k
      if (f.files) walk(f, r)
      else out.set(r, f)
    }
  })(h, '')
  return out
}

const a = leaves(A), b = leaves(B)
console.log(`A 条目 ${a.size}   B 条目 ${b.size}`)

let onlyA = 0, onlyB = 0, sizeDiff = 0, integDiff = 0, offsetDiff = 0, unpackedDiff = 0
const unexpected = []
const changed = []

// 先按顺序比较 offset：offset 变了是正常的（因为 main.js 变长，其后文件整体后移）
for (const [rel, fa] of a) {
  const fb = b.get(rel)
  if (!fb) { onlyA++; unexpected.push('仅A有: ' + rel); continue }
  const sameSize = fa.size === fb.size
  const sameInteg = JSON.stringify(fa.integrity) === JSON.stringify(fb.integrity)
  const sameUnp = !!fa.unpacked === !!fb.unpacked
  const sameOff = String(fa.offset) === String(fb.offset)
  if (!sameUnp) { unpackedDiff++; unexpected.push('unpacked 标记不同: ' + rel) }
  if (!sameSize) { sizeDiff++; changed.push(rel) }
  if (!sameInteg) { integDiff++; if (sameSize) changed.push('(integrity only) ' + rel) }
  if (!sameOff) offsetDiff++
}
for (const rel of b.keys()) if (!a.has(rel)) { onlyB++; unexpected.push('仅B有: ' + rel) }

console.log(`\n声明差异统计:`)
console.log(`  size 不同     : ${sizeDiff}`)
console.log(`  integrity 不同: ${integDiff}`)
console.log(`  unpacked 不同 : ${unpackedDiff}`)
console.log(`  offset 不同   : ${offsetDiff}  （lib/main.js 变长导致其后文件整体后移，属正常）`)
console.log(`  仅 A 有       : ${onlyA}`)
console.log(`  仅 B 有       : ${onlyB}`)

const realChanged = [...new Set(changed.map((c) => c.replace(/^\(integrity only\) /, '')))]
console.log(`\n实际内容有变化的文件 (${realChanged.length}): ${realChanged.join(', ')}`)

const unexpectedChanged = realChanged.filter((r) => !allow.has(r))
const ok = onlyA === 0 && onlyB === 0 && unpackedDiff === 0 && unexpectedChanged.length === 0
if (unexpected.length) { console.log('\n非预期项:'); unexpected.slice(0, 10).forEach((u) => console.log('  ' + u)) }
console.log(ok
  ? '✅ 除允许的文件外，所有条目的 size/integrity/unpacked 声明完全一致'
  : '❌ 存在非预期差异')
process.exit(ok ? 0 : 1)
