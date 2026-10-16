const fs=require('fs'),crypto=require('crypto');
const ASAR=process.argv[2],REL=process.argv[3],OUT=process.argv[4];
const fd=fs.openSync(ASAR,'r');const h=Buffer.alloc(16);fs.readSync(fd,h,0,16,0);
const hs=h.readUInt32LE(12);const jb=Buffer.alloc(hs);fs.readSync(fd,jb,0,hs,16);
const header=JSON.parse(jb.toString('utf8'));const ds=16+hs;
let found=null;(function w(n,p){for(const k of Object.keys(n.files||{})){const f=n.files[k];const r=p?p+'/'+k:k;if(f.files)w(f,r);else if(r===REL)found=f}})(header,'');
if(!found){console.error('not found');process.exit(1)}
const off=typeof found.offset==='string'?parseInt(found.offset,10):found.offset;
const b=Buffer.alloc(found.size);fs.readSync(fd,b,0,found.size,ds+off);fs.closeSync(fd);
fs.writeFileSync(OUT,b);
console.log('extracted',REL,found.size,'bytes  sha256=',crypto.createHash('sha256').update(b).digest('hex'));