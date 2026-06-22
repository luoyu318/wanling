// 生成 1024 PNG + favicon 多尺寸 PNG + ICO
const sharp = require('sharp');
const fs = require('fs');
const path = require('path');
const dir = __dirname;

(async () => {
  // 1) App 图标 1024 PNG（深底紫版）
  const iconSvg = fs.readFileSync(path.join(dir, 'icon.svg'), 'utf8');
  await sharp(Buffer.from(iconSvg), { density: 600 })
    .resize(1024, 1024)
    .png()
    .toFile(path.join(dir, 'icon-1024.png'));
  console.log('✓ icon-1024.png');

  // 2) 常用 PNG 尺寸
  for (const s of [512, 256, 192, 180, 152, 128, 120, 87, 76, 60]) {
    await sharp(Buffer.from(iconSvg), { density: 600 })
      .resize(s, s).png()
      .toFile(path.join(dir, `icon-${s}.png`));
  }
  console.log('✓ PNG 多尺寸');

  // 3) favicon：用单色徽章，注入 currentColor=深紫，生成 16/32/48 PNG，再拼 ICO
  const mono = fs.readFileSync(path.join(dir, 'badge-mono.svg'), 'utf8');
  const colored = mono.replace(/currentColor/g, '#2a0f44');
  const sizes = [16, 32, 48];
  const pngs = [];
  for (const s of sizes) {
    const buf = await sharp(Buffer.from(colored), { density: 300 })
      .resize(s, s).png().toBuffer();
    pngs.push(buf);
    await sharp(buf).toFile(path.join(dir, `favicon-${s}.png`));
  }
  console.log('✓ favicon PNG');

  // 4) ICO（多尺寸封装）
  const ico = makeIco(pngs, sizes);
  fs.writeFileSync(path.join(dir, 'favicon.ico'), ico);
  console.log('✓ favicon.ico');
})().catch(e => { console.error(e); process.exit(1); });

// 生成多尺寸 ICO 文件（ICONDIR + 多个 ICONDIRENTRY + PNG 数据）
function makeIco(pngBufs, sizes) {
  const headerSize = 6;
  const entrySize = 16;
  const count = pngBufs.length;
  const offset = headerSize + entrySize * count;
  const bufs = [Buffer.from([0,0,1,0, count & 0xff, (count>>8)&0xff])];
  let acc = offset;
  for (let i = 0; i < count; i++) {
    const s = sizes[i];
    const w = s >= 256 ? 0 : s;
    const h = w;
    const sz = pngBufs[i].length;
    const entry = Buffer.alloc(entrySize);
    entry.writeUInt8(w, 0);
    entry.writeUInt8(h, 1);
    entry.writeUInt8(0, 2); // palette
    entry.writeUInt8(0, 3); // reserved
    entry.writeUInt16LE(1, 4); // planes
    entry.writeUInt16LE(32, 6); // bpp
    entry.writeUInt32LE(sz, 8);
    entry.writeUInt32LE(acc, 12);
    bufs.push(entry);
    acc += sz;
  }
  for (const b of pngBufs) bufs.push(b);
  return Buffer.concat(bufs);
}
