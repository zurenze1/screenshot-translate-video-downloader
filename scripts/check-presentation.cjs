'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '..');
const docs = path.join(root, 'docs');
const html = fs.readFileSync(path.join(docs, 'index.html'), 'utf8');
const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map(m => m[1]);
assert.equal(new Set(ids).size, ids.length, '页面不应存在重复 ID');
const idSet = new Set(ids);
for (const match of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
  const url = match[1];
  if (/^(https?:|data:|mailto:)/.test(url)) continue;
  if (url.startsWith('#')) { assert(idSet.has(url.slice(1)), `无效锚点 ${url}`); continue; }
  assert(fs.existsSync(path.resolve(docs, decodeURI(url.split(/[?#]/)[0]))), `文件缺失 ${url}`);
}
const context = {window:{}};
vm.runInNewContext(fs.readFileSync(path.join(docs, 'talk-data.js'), 'utf8'), context);
const talk = context.window.PRODUCT_TALK;
assert.equal(talk.chapters.length, 7);
assert.equal(talk.chapters.reduce((sum,c) => sum+c.seconds, 0), talk.targetSeconds);
const markdown = fs.readFileSync(path.join(docs, '讲解逐字稿.md'), 'utf8');
for (const chapter of talk.chapters) {
  assert(idSet.has(chapter.id), `章节入口缺失 ${chapter.id}`);
  for (const para of chapter.paragraphs) assert(markdown.includes(para), `逐字稿与网页内容未同步：${chapter.title}`);
}
for (const file of ['app.js','talk-data.js']) new vm.Script(fs.readFileSync(path.join(docs,file),'utf8'),{filename:file});
const publicText = ['index.html','app.js','talk-data.js','style.css'].map(file=>fs.readFileSync(path.join(docs,file),'utf8')).join('\n');
assert(!/\/Users\/|gh[pousr]_[A-Za-z0-9]{20}|sk-[A-Za-z0-9]{20}/.test(publicText), '公开文件包含不应出现的本机路径或凭据模式');
const han = (talk.chapters.flatMap(c=>c.paragraphs).join('').match(/\p{Script=Han}/gu)||[]).length;
console.log(`通过：7 个章节，${ids.length} 个唯一 ID，静态资源与锚点完整，逐字稿 ${han} 个汉字，时间预算 ${talk.targetSeconds} 秒。`);
