// 快速验证：我的自研打包器能否产出"官方解析器认可"的包
// 用法: node check-official.cjs <原始包> <自研写出的包>
const asar = require('@electron/asar')
const fs = require('fs')

const ORIG = process.argv[2], MINE = process.argv[3]

function tryOfficial(label, p) {
  console.log(`===== ${label} =====`)
  console.log('  ' + p)
  let raw
  try {
    raw = asar.getRawHeader(p)
    console.log(`  ✓ getRawHeader: headerSize=${raw.headerSize} headerString长度=${raw.headerString.length}`)
  } catch (e) {
    console.log('  ❌ getRawHeader 失败: ' + e.message)
    return false
  }
  let h
  try { h = JSON.parse(raw.headerString); console.log('  ✓ header JSON 解析成功') }
  catch (e) { console.log('  ❌ header JSON 解析失败: ' + e.message); return false }
  try {
    const pkg = JSON.parse(asar.extractFile(p, 'package.json').toString('utf8'))
    console.log(`  ✓ extractFile(package.json): name=${pkg.name} main=${pkg.main}`)
  } catch (e) { console.log('  ❌ extractFile(package.json) 失败: ' + e.message); return false }
  try {
    const m = asar.extractFile(p, 'lib/main.js')
    console.log(`  ✓ extractFile(lib/main.js): ${m.length} 字节  补丁标记=${m.toString('utf8').includes('floatBallRestoreBounds')}`)
  } catch (e) { console.log('  ❌ extractFile(lib/main.js) 失败: ' + e.message); return false }
  let packed = 0, unp = 0
  ;(function w(n) { for (const k of Object.keys(n.files || {})) { const f = n.files[k]; if (f.files) w(f); else { f.unpacked ? unp++ : packed++ } } })(h)
  console.log(`  条目 packed=${packed} unpacked=${unp}`)
  console.log('  OK: official parser accepted this archive')
  console.log('OFFICIAL_PARSER_ACCEPTED')
  return true
}

const okO = tryOfficial('原始包（基准）', ORIG)
console.log('')
const okM = tryOfficial('自研打包器输出', MINE)
console.log('')
console.log(okM ? '结论：自研输出被官方接受 ✅' : '结论：自研输出仍被官方拒绝 ❌')
process.exit(okM ? 0 : 1)
