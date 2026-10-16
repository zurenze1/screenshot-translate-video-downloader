'use strict';
/* 截图翻译视频下载 · 发布会讲解
   → / 空格 / 翻页笔：下一步；← 上一步；N 讲述提示；F 全屏；数字键跳章 */
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const W = 1920, H = 1080;
  const stage = $('#stage');
  const slides = $$('.slide');
  const talk = window.PRODUCT_TALK || { chapters: [] };
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- 画布缩放 ----------
  function fit() {
    const s = Math.min(innerWidth / W, innerHeight / H);
    stage.style.transform = `scale(${s}) translate(-50%, -50%)`;
    stage.style.transformOrigin = '0 0';
    stage.style.left = '50%'; stage.style.top = '50%';
    stage.style.transform = `translate(${-W * s / 2}px, ${-H * s / 2}px) scale(${s})`;
  }
  addEventListener('resize', fit); fit();

  // ---------- 小提示 ----------
  let toastTimer;
  function toast(text, ms = 2600) {
    let t = $('.toast');
    if (!t) { t = document.createElement('div'); t.className = 'toast'; document.body.append(t); }
    t.textContent = text; t.style.opacity = 1;
    clearTimeout(toastTimer); toastTimer = setTimeout(() => t.style.opacity = 0, ms);
  }

  // ---------- 翻页与分步 ----------
  let cur = 0;
  const step = slides.map(() => 0);
  const maxStep = i => +(slides[i].dataset.steps || 0);
  const hooks = {};           // 每页进入/离开/分步时的回调

  const progress = $('#progress');
  slides.forEach(() => progress.append(document.createElement('i')));

  function applySteps(i) {
    $$('[data-step]', slides[i]).forEach(el => el.classList.toggle('shown', +el.dataset.step <= step[i]));
    slides[i].classList.toggle('stage-2', step[i] >= 1 && slides[i].id === 's-pain');
    hooks[slides[i].id]?.step?.(step[i]);
    const bars = $$('i', progress);
    bars.forEach((b, k) => b.style.setProperty('--p', k < cur ? 1 : k > cur ? 0 : (maxStep(cur) ? .35 + .65 * step[cur] / maxStep(cur) : 1)));
  }

  function chapterOf(i) {
    const id = slides[i].dataset.chapter;
    const k = talk.chapters.findIndex(c => c.id === id);
    return { k, c: talk.chapters[k] };
  }

  function go(i, fromBack = false) {
    if (i < 0 || i >= slides.length) return;
    const prev = slides[cur];
    if (i !== cur) {
      hooks[prev.id]?.leave?.();
      prev.classList.remove('active');
      prev.classList.add('leaving');
      setTimeout(() => prev.classList.remove('leaving'), 700);
      $$('video', prev).forEach(v => v.pause());
    }
    cur = i;
    const s = slides[i];
    step[i] = fromBack ? maxStep(i) : 0;
    s.classList.add('active');
    $$('video', s).forEach(v => { if (!v.dataset.manual) { v.play().catch(() => {}); } });
    hooks[s.id]?.enter?.();
    applySteps(i);
    const { k, c } = chapterOf(i);
    $('#chapter-label').innerHTML = c ? `<b>${String(k + 1).padStart(2, '0')}</b> · ${c.title}` : '';
    history.replaceState(null, '', `#${i + 1}`);
    document.body.classList.toggle('on-open', s.id === 's-open');
    renderNotes();
  }

  function next() {
    if (step[cur] < maxStep(cur)) { step[cur]++; applySteps(cur); return; }
    go(cur + 1);
  }
  function prev() {
    if (step[cur] > 0) { step[cur]--; applySteps(cur); return; }
    go(cur - 1, true);
  }

  $('#next').onclick = next;
  $('#prev').onclick = prev;

  // ---------- 讲述提示 + 计时 ----------
  const notes = $('#notes');
  let notesOpen = false, t0 = null;
  function fmtTime(ms) { const s = Math.floor(ms / 1000); return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`; }
  function renderNotes() {
    const { k, c } = chapterOf(cur);
    if (!c) { notes.innerHTML = ''; return; }
    const total = talk.targetSeconds ? fmtTime(talk.targetSeconds * 1000) : '';
    notes.innerHTML = `<div class="h"><span>${String(k + 1).padStart(2, '0')} / ${String(talk.chapters.length).padStart(2, '0')} · ${c.title} · 约 ${c.seconds} 秒</span><time id="note-timer">${t0 ? fmtTime(Date.now() - t0) : '00:00'} / ${total}</time></div>`
      + `<p class="cue">提示：${c.cue}　操作：${c.action}</p>` + c.paragraphs.map(p => `<p>${p}</p>`).join('');
  }
  function toggleNotes(v = !notesOpen) {
    notesOpen = v; notes.classList.toggle('open', v);
    if (v && !t0) t0 = Date.now();
    renderNotes();
  }
  setInterval(() => { const el = $('#note-timer'); if (el && t0) el.textContent = `${fmtTime(Date.now() - t0)} / ${fmtTime(talk.targetSeconds * 1000)}`; }, 500);
  $('#notes-btn').onclick = () => toggleNotes();

  function toggleFS() {
    if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen?.().catch(() => {});
  }
  $('#fs-btn').onclick = toggleFS;

  // 鼠标一动才显示导航
  let idle;
  addEventListener('mousemove', () => { document.body.classList.add('mouse'); clearTimeout(idle); idle = setTimeout(() => document.body.classList.remove('mouse'), 2200); });

  // 键盘：页内交互的按键优先
  addEventListener('keydown', e => {
    if (e.target.closest('input, textarea')) return;
    if (hooks[slides[cur].id]?.key?.(e)) { e.preventDefault(); return; }
    const k = e.key;
    if (['ArrowRight', 'PageDown', ' ', 'Enter'].includes(k) && !(k === 'Enter' && e.target.closest('button,a'))) { e.preventDefault(); next(); }
    else if (['ArrowLeft', 'PageUp', 'Backspace'].includes(k)) { e.preventDefault(); prev(); }
    else if (k === 'n' || k === 'N') toggleNotes();
    else if (k === 'f' || k === 'F') toggleFS();
    else if (k === 'Escape') { if (notesOpen) toggleNotes(false); }
    else if (k === 'Home') go(0);
    else if (k === 'End') go(slides.length - 1);
    else if (/^[1-7]$/.test(k)) { const id = talk.chapters[+k - 1]?.id; const i = slides.findIndex(s => s.dataset.chapter === id); if (i >= 0) go(i); }
  });

  // 触屏左右滑
  let tx = null;
  addEventListener('touchstart', e => { if (!e.target.closest('.wall,.strip,.knob,.boxes')) tx = e.touches[0].clientX; }, { passive: true });
  addEventListener('touchend', e => { if (tx == null) return; const dx = e.changedTouches[0].clientX - tx; tx = null; if (Math.abs(dx) > 60) dx < 0 ? next() : prev(); });

  // ---------- 时间码 ----------
  const tc = (sec, fps = 24) => { const f = Math.floor((sec % 1) * fps), s = Math.floor(sec); return [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60, f].map(n => String(n).padStart(2, '0')).join(':'); };
  const openVid = $('#s-open video');
  (function tick() {
    if (slides[cur].id === 's-open') $('#open-tc').textContent = 'TC ' + tc(openVid.currentTime);
    if (slides[cur].id === 's-translate') { const v = $('#tr-frame video'); $('#tr-tc').textContent = tc(315.2 + v.currentTime); updateSub(v.currentTime); }
    requestAnimationFrame(tick);
  })();

  // ================= 翻译 =================
  // 电影官方英文字幕（片段内时间）；中文为本软件翻译引擎实际输出，原样未改
  const CUES = [
    [0.8, 1.8, 'Look Celia.', '看Celia。'],
    [2.8, 4.8, 'We have to follow our passions.', '我们必须追随我们的激情。'],
    [5.8, 7.8, 'You have your robotics...', '你有你的机器人......'],
    [9.8, 12.8, '...and I just want to be awesome in space.', '...我只想在太空中变得棒极了。'],
  ];
  const subEn = $('#tr-frame .subline .en'), subZh = $('#tr-frame .subline .zh');
  let lastCue = -1;
  function updateSub(t) {
    const i = CUES.findIndex(c => t >= c[0] && t < c[1]);
    if (i === lastCue) return; lastCue = i;
    subEn.textContent = i >= 0 ? CUES[i][2] : '';
    subZh.textContent = i >= 0 ? CUES[i][3] : '';
    subZh.style.visibility = i >= 0 ? 'visible' : 'hidden';
  }
  const trBtn = $('#tr-toggle'), trFrame = $('#tr-frame');
  function setTranslated(on) {
    if (on) {
      const scan = $('.scan', trFrame); scan.classList.remove('run'); void scan.offsetWidth; scan.classList.add('run');
      setTimeout(() => trFrame.classList.add('translated'), reduced ? 0 : 420);
    } else trFrame.classList.remove('translated');
    trBtn.classList.toggle('on', on);
    trBtn.setAttribute('aria-pressed', on);
    trBtn.firstChild.textContent = on ? '恢复原文 ' : '全屏中文 ';
  }
  trBtn.onclick = () => setTranslated(!trFrame.classList.contains('translated'));
  let typing;
  function typeDemo() {
    clearInterval(typing);
    const src = "The world's changed, Celia...", dst = '世界变了，Celia......';
    const a = $('#mp-src'), b = $('#mp-dst');
    a.innerHTML = '<span class="caret"></span>'; b.textContent = '';
    // 模拟一次粘贴：整句出现，停顿片刻后译文自动出现
    setTimeout(() => {
      a.innerHTML = src.replace(/</g, '&lt;') + '<span class="caret"></span>';
      setTimeout(() => { b.innerHTML = dst + '<span class="ms">苹果离线翻译 · 本机</span>'; }, 380);
    }, 500);
  }
  hooks['s-translate'] = {
    enter() { setTranslated(false); },
    step(n) { if (n >= 1) typeDemo(); },
    key(e) { if (e.altKey && (e.code === 'KeyT')) { trBtn.click(); return true; } },
  };

  // ================= 截图中转站 =================
  const grid = $('#grid'), wall = $('#wall'), band = $('#band'), board = $('#board'), slots = $('#slots');
  const STILLS = Array.from({ length: 14 }, (_, i) => ({ id: i, src: `media/still_${String(i + 1).padStart(2, '0')}.jpg`, fn: `截图 10.16 ${String(10 + i).padStart(2, '0')}.${String(7 * i % 60).padStart(2, '0')}` }));
  let alive = STILLS.map(s => s.id), sel = new Set(), shelfUndo = [];
  function renderGrid() {
    grid.innerHTML = '';
    STILLS.filter(s => alive.includes(s.id)).forEach(s => {
      const d = document.createElement('div');
      d.className = 'thumb' + (sel.has(s.id) ? ' sel' : '');
      d.dataset.id = s.id;
      d.innerHTML = `<img src="${s.src}" alt="电影剧照截图" draggable="false"><span class="fn">${s.fn}</span>`;
      grid.append(d);
    });
    $('#wall-count').textContent = alive.length;
    $('#wall-sel').innerHTML = sel.size ? `已选 <b>${sel.size}</b> 张` : '还没选';
  }
  function refreshSel() {
    $$('.thumb', grid).forEach(t => t.classList.toggle('sel', sel.has(+t.dataset.id)));
    $('#wall-sel').innerHTML = sel.size ? `已选 <b>${sel.size}</b> 张` : '还没选';
  }
  renderGrid();

  let bandStart = null, baseSel = null, dragging = null;
  wall.addEventListener('pointerdown', e => {
    wall.focus({ preventScroll: true });
    const th = e.target.closest('.thumb');
    if (th) {   // 按在图片上：准备拖走
      const id = +th.dataset.id;
      if (e.metaKey || e.shiftKey) { sel.has(id) ? sel.delete(id) : sel.add(id); refreshSel(); return; }
      if (!sel.has(id)) { sel = new Set([id]); refreshSel(); }
      dragging = { x: e.clientX, y: e.clientY, started: false };
      wall.setPointerCapture(e.pointerId);
      return;
    }
    const r = wall.getBoundingClientRect();
    bandStart = { x: e.clientX, y: e.clientY, r };
    baseSel = (e.metaKey || e.shiftKey) ? new Set(sel) : new Set();
    sel = new Set(baseSel); refreshSel();
    wall.setPointerCapture(e.pointerId);
  });
  let ghost = null;
  wall.addEventListener('pointermove', e => {
    if (bandStart) {
      const { r } = bandStart, sx = r.width / 1200;
      const x0 = Math.min(bandStart.x, e.clientX), y0 = Math.min(bandStart.y, e.clientY);
      const x1 = Math.max(bandStart.x, e.clientX), y1 = Math.max(bandStart.y, e.clientY);
      Object.assign(band.style, { display: 'block', left: (x0 - r.left) / sx + 'px', top: (y0 - r.top) / sx + 'px', width: (x1 - x0) / sx + 'px', height: (y1 - y0) / sx + 'px' });
      const next = new Set(baseSel);
      $$('.thumb', grid).forEach(t => {
        const b = t.getBoundingClientRect();
        if (b.right > x0 && b.left < x1 && b.bottom > y0 && b.top < y1) { const id = +t.dataset.id; baseSel.has(id) ? next.delete(id) : next.add(id); }
      });
      sel = next; refreshSel();
    } else if (dragging) {
      if (!dragging.started && Math.hypot(e.clientX - dragging.x, e.clientY - dragging.y) > 6) {
        dragging.started = true;
        ghost = document.createElement('div'); ghost.className = 'ghost-drag';
        const first = STILLS.find(s => sel.has(s.id));
        ghost.innerHTML = `<img src="${first.src}" alt="">${sel.size > 1 ? `<span class="count">${sel.size}</span>` : ''}`;
        document.body.append(ghost);
      }
      if (ghost) {
        ghost.style.left = e.clientX - 60 + 'px'; ghost.style.top = e.clientY - 30 + 'px';
        const b = board.getBoundingClientRect();
        board.classList.toggle('hot', e.clientX > b.left && e.clientX < b.right && e.clientY > b.top && e.clientY < b.bottom);
      }
    }
  });
  function endPointer(e) {
    if (bandStart) { bandStart = null; band.style.display = 'none'; }
    if (dragging) {
      if (ghost) {
        ghost.remove(); ghost = null;
        if (board.classList.contains('hot')) {
          board.classList.remove('hot');
          const ids = STILLS.filter(s => sel.has(s.id));
          ids.forEach((s, k) => setTimeout(() => {
            const slot = document.createElement('div'); slot.className = 'slot';
            slot.innerHTML = `<img src="${s.src}" alt="放进分镜板的剧照">`;
            slots.prepend(slot);
            while (slots.children.length > 4) slots.lastChild.remove();
          }, k * 110));
          toast(`已放进分镜板：${ids.length} 张`);
        }
      } else if (!(e.metaKey || e.shiftKey)) {   // 只是点了一下
        const th = e.target.closest?.('.thumb');
        if (th) { sel = new Set([+th.dataset.id]); refreshSel(); }
      }
      dragging = null;
    }
  }
  wall.addEventListener('pointerup', endPointer);
  wall.addEventListener('pointercancel', endPointer);
  hooks['s-shelf'] = {
    key(e) {
      const cmd = e.metaKey || e.ctrlKey;
      if ((e.key === 'Backspace' || e.key === 'Delete') && sel.size) {
        shelfUndo.push([...alive]);
        const gone = [...sel];
        $$('.thumb', grid).forEach(t => { if (sel.has(+t.dataset.id)) t.classList.add('gone'); });
        setTimeout(() => { alive = alive.filter(id => !gone.includes(id)); sel.clear(); renderGrid(); }, 380);
        toast(`已删除 ${gone.length} 张 · 放进了废纸篓（⌘Z 撤销）`);
        return true;
      }
      if (cmd && e.key.toLowerCase() === 'z') {
        if (shelfUndo.length) { alive = shelfUndo.pop(); renderGrid(); toast('已撤销'); } else toast('没有可以撤销的');
        return true;
      }
      if (cmd && e.key.toLowerCase() === 'a') { sel = new Set(alive); refreshSel(); return true; }
      if (e.key === 'Escape' && sel.size) { sel.clear(); refreshSel(); return true; }
    },
  };

  // ================= 片段截取 =================
  const cv = $('#clip-video'); cv.dataset.manual = '1';
  const FILM = 734;       // 整部影片 12:14
  let cin = 3.4, cout = 8.1, dragH = null;
  const strip = $('#strip');
  function clipRender() {
    const D = cv.duration || 15.5;
    const a = cin / D * 100, b = cout / D * 100;
    $('#shade-l').style.cssText = `left:0;width:${a}%`;
    $('#shade-r').style.cssText = `left:${b}%;right:0`;
    $('#range').style.cssText = `left:${a}%;width:${b - a}%`;
    $('#h-in').style.left = `calc(${a}% - 13px)`;
    $('#h-out').style.left = `calc(${b}% - 13px)`;
    const ti = $('#tag-in'), to = $('#tag-out');
    ti.style.left = a + '%'; to.style.left = b + '%';
    ti.textContent = 'IN ' + tc(206.5 + cin).slice(3); to.textContent = 'OUT ' + tc(206.5 + cout).slice(3);
    const len = cout - cin;
    $('#clip-len').innerHTML = `${len.toFixed(2)}<small>秒</small>`;
    $('#clip-len2').textContent = `${len.toFixed(1)} 秒`;
    $('#clip-ratio').style.width = Math.max(.4, len / FILM * 100) + '%';
    $('#clip-save').textContent = `少下载约 ${(100 - len / FILM * 100).toFixed(1)}%（按时长估算）`;
  }
  function stripX(e) { const r = strip.getBoundingClientRect(); return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)) * (cv.duration || 15.5); }
  $('#h-in').addEventListener('pointerdown', e => { dragH = 'in'; e.target.setPointerCapture(e.pointerId); });
  $('#h-out').addEventListener('pointerdown', e => { dragH = 'out'; e.target.setPointerCapture(e.pointerId); });
  strip.addEventListener('pointerdown', e => {
    if (e.target.closest('.handle')) return;
    // 点时间轴：把更近的那一端挪过去
    const t = stripX(e); dragH = Math.abs(t - cin) < Math.abs(t - cout) ? 'in' : 'out';
    strip.setPointerCapture(e.pointerId); move(e);
  });
  function move(e) {
    if (!dragH) return;
    const t = stripX(e);
    if (dragH === 'in') cin = Math.min(t, cout - .5); else cout = Math.max(t, cin + .5);
    cv.currentTime = dragH === 'in' ? cin : Math.max(cin, cout - .6);
    clipRender();
  }
  addEventListener('pointermove', move);
  addEventListener('pointerup', () => { dragH = null; });
  for (const [id, which] of [['#h-in', 'in'], ['#h-out', 'out']]) {
    $(id).addEventListener('keydown', e => {
      const d = e.key === 'ArrowLeft' ? -0.1 : e.key === 'ArrowRight' ? 0.1 : 0;
      if (!d) return; e.stopPropagation(); e.preventDefault();
      if (which === 'in') cin = Math.max(0, Math.min(cin + d, cout - .5)); else cout = Math.min(cv.duration || 15.5, Math.max(cout + d, cin + .5));
      clipRender();
    });
  }
  (function loop() {
    if (slides[cur].id === 's-clip') {
      if (!dragH && (cv.currentTime < cin - .05 || cv.currentTime >= cout)) cv.currentTime = cin;
      const D = cv.duration || 15.5;
      $('#playhead').style.left = (cv.currentTime / D * 100) + '%';
    }
    requestAnimationFrame(loop);
  })();
  cv.addEventListener('loadedmetadata', clipRender);
  $('#clip-export').onclick = () => {
    const card = $('#export-card'), bar = $('#export-bar');
    const len = cout - cin;
    card.classList.add('show');
    $('#export-state').textContent = `只下载这 ${len.toFixed(1)} 秒，同时编码…`;
    $('#export-name').textContent = '';
    bar.style.transition = 'none'; bar.style.width = '0'; void bar.offsetWidth;
    bar.style.transition = `width ${reduced ? 0 : 1.6}s cubic-bezier(.65,0,.35,1)`; bar.style.width = '100%';
    setTimeout(() => {
      $('#export-state').textContent = '✅ 已导出 · 只有这一个文件';
      $('#export-name').textContent = `Tears of Steel 片段 ${tc(206.5 + cin).slice(3, 8).replace(':', '.')}-${tc(206.5 + cout).slice(3, 8).replace(':', '.')}.mp4`;
    }, reduced ? 50 : 1700);
  };
  hooks['s-clip'] = { enter() { clipRender(); cv.currentTime = cin; cv.play().catch(() => {}); $('#export-card').classList.remove('show'); } };

  // ================= 去水印 =================
  // 两处水印的位置，是软件「自动找水印」在这段视频上实际算出来的（比例坐标，原点左上）
  const DETECTED = [{ x: .013, y: .906, w: .135, h: .0625 }, { x: .8385, y: .0188, w: .135, h: .0875 }];
  const wmBa = $('#wm-ba'), wmBoxes = $('#wm-boxes'), wmDiv = $('#wm-div'), wmAfter = $('.after', wmBa);
  const vBefore = $('video.before', wmBa), vAfter = $('.after video', wmBa);
  let boxes = [], wmUndo = [], drawing = false, split = 1;
  function drawBoxes() {
    wmBoxes.innerHTML = '';
    boxes.forEach((b, i) => {
      const d = document.createElement('div'); d.className = 'wbox';
      Object.assign(d.style, { left: b.x * 100 + '%', top: b.y * 100 + '%', width: b.w * 100 + '%', height: b.h * 100 + '%' });
      d.innerHTML = `<b>水印 ${i + 1}</b>`; d.dataset.i = i;
      wmBoxes.append(d);
    });
    wmBoxes.classList.toggle('drawing', drawing);
    $('#wm-draw').textContent = drawing ? '✓ 完成框选' : '框选水印';
  }
  function setSplit(f, animate) {
    split = Math.max(0, Math.min(1, f));
    const dur = animate && !reduced ? '1.2s' : '0s';
    wmAfter.style.transition = `clip-path ${dur} cubic-bezier(.65,0,.35,1)`;
    wmDiv.style.transition = `left ${dur} cubic-bezier(.65,0,.35,1)`;
    wmAfter.style.clipPath = `inset(0 0 0 ${split * 100}%)`;
    wmDiv.style.left = split * 100 + '%';
  }
  function wmStatus(html) { $('#wm-status').innerHTML = html; }
  $('#wm-auto').onclick = () => {
    const sw = $('#wm-sweep'); sw.classList.remove('run'); void sw.offsetWidth; sw.classList.add('run');
    wmStatus('正在整段视频里取帧，找角落里<b>一直不动</b>的标志…');
    setTimeout(() => {
      wmUndo.push(JSON.stringify(boxes));
      DETECTED.forEach(d => { if (!boxes.some(b => Math.abs(b.x - d.x) < .05 && Math.abs(b.y - d.y) < .05)) boxes.push({ ...d }); });
      drawBoxes();
      wmStatus('找到 <b>2 处水印</b>：左下和右上。漏了的点「框选水印」接着框，框错的单击删掉。');
    }, reduced ? 0 : 1050);
  };
  $('#wm-draw').onclick = () => { drawing = !drawing; drawBoxes(); if (drawing) wmStatus('在画面上<b>连续拖出</b>好几个框；单击某个框删掉它；Esc 结束。'); };
  $('#wm-undo').onclick = () => wmUndoOne();
  function wmUndoOne() {
    if (!wmUndo.length) { toast('没有可以撤销的'); return; }
    const last = wmUndo.pop();
    if (last === 'ERASE') { setSplit(1, true); wmStatus('已撤销导出：处理后的文件放进了废纸篓。'); return; }
    boxes = JSON.parse(last); drawBoxes(); wmStatus('已撤销。');
  }
  $('#wm-erase').onclick = () => {
    if (!boxes.length) { wmStatus('先点「<b>自动找水印</b>」或自己框一下，再抹掉。'); return; }
    drawing = false; drawBoxes();
    wmUndo.push('ERASE');
    vAfter.currentTime = vBefore.currentTime;
    setSplit(.0, true);
    setTimeout(() => wmStatus('完成：拖动中间的 <b>⇆</b> 对比原片和处理后。右侧画面是软件<b>实际处理</b>的结果，不是效果图。'), reduced ? 0 : 1200);
  };
  // 画框：连续画，单击删掉
  let boxStart = null, liveBox = null;
  wmBoxes.addEventListener('pointerdown', e => {
    if (!drawing) return;
    const hit = e.target.closest('.wbox');
    const r = wmBoxes.getBoundingClientRect();
    boxStart = { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height, r, hit, moved: false };
    wmBoxes.setPointerCapture(e.pointerId);
  });
  wmBoxes.addEventListener('pointermove', e => {
    if (!boxStart) return;
    const { r } = boxStart;
    const x = Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y = Math.min(1, Math.max(0, (e.clientY - r.top) / r.height));
    if (!boxStart.moved && Math.hypot(x - boxStart.x, y - boxStart.y) < .01) return;
    boxStart.moved = true;
    if (!liveBox) { liveBox = document.createElement('div'); liveBox.className = 'wbox'; wmBoxes.append(liveBox); }
    const b = { x: Math.min(x, boxStart.x), y: Math.min(y, boxStart.y), w: Math.abs(x - boxStart.x), h: Math.abs(y - boxStart.y) };
    Object.assign(liveBox.style, { left: b.x * 100 + '%', top: b.y * 100 + '%', width: b.w * 100 + '%', height: b.h * 100 + '%' });
    liveBox.dataset.b = JSON.stringify(b);
  });
  wmBoxes.addEventListener('pointerup', () => {
    if (!boxStart) return;
    if (boxStart.moved && liveBox) {
      const b = JSON.parse(liveBox.dataset.b);
      if (b.w > .015 && b.h > .015) { wmUndo.push(JSON.stringify(boxes)); boxes.push(b); }
    } else if (boxStart.hit) {
      wmUndo.push(JSON.stringify(boxes)); boxes.splice(+boxStart.hit.dataset.i, 1);
    }
    liveBox = null; boxStart = null; drawBoxes();
  });
  // 对比滑块
  const knob = $('#wm-knob'); let knobDrag = false;
  knob.addEventListener('pointerdown', e => { knobDrag = true; knob.setPointerCapture(e.pointerId); });
  knob.addEventListener('pointermove', e => { if (!knobDrag) return; const r = wmBa.getBoundingClientRect(); setSplit((e.clientX - r.left) / r.width, false); });
  knob.addEventListener('pointerup', () => knobDrag = false);
  knob.addEventListener('keydown', e => { if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.stopPropagation(); e.preventDefault(); setSplit(split + (e.key === 'ArrowLeft' ? -.05 : .05), false); } });
  // 两段视频保持同步
  setInterval(() => { if (slides[cur].id === 's-wm' && Math.abs(vAfter.currentTime - vBefore.currentTime) > .08) vAfter.currentTime = vBefore.currentTime; }, 400);
  hooks['s-wm'] = {
    enter() { boxes = []; wmUndo = []; drawing = false; drawBoxes(); setSplit(1, false); wmStatus('两处水印是演示加上的虚构标识。右侧「处理后」是软件<b>实际处理</b>的结果。'); },
    key(e) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z') { wmUndoOne(); return true; }
      if (e.key === 'Escape' && drawing) { drawing = false; drawBoxes(); return true; }
    },
  };

  // ================= 字幕 =================
  // 字幕位置同样是软件「自动找字幕」在这段视频上算出来的
  const SUBRECT = { x: .172, y: .833, w: .656, h: .167 };
  const subLayers = $$('#sub-screen .layer'), subVids = subLayers.map(l => $('video', l));
  const TEXT = {
    keep: ['原样保留。', '什么都不动，字幕照常在。'],
    erase: ['抹掉了。', '用周围画面把字幕那条填平。复杂背景会留下涂抹痕迹 —— 这是真实输出，我们不藏。'],
    crop: ['裁掉了。', '直接剪掉字幕那一条，画面矮了 90 像素，最干净。'],
  };
  function setSubMode(m) {
    $$('#s-sub .seg button').forEach(b => { b.classList.toggle('on', b.dataset.mode === m); b.setAttribute('aria-selected', b.dataset.mode === m); });
    const t = subVids[0].currentTime;
    subVids.forEach(v => { if (Math.abs(v.currentTime - t) > .05) v.currentTime = t; });
    subLayers.forEach(l => l.classList.toggle('on', l.dataset.mode === m));
    $('#sub-frame').classList.toggle('cropped', m === 'crop');
    $('#sub-screen').style.height = m === 'crop' ? '444px' : '534px';
    $('#sub-t').textContent = TEXT[m][0]; $('#sub-d').textContent = TEXT[m][1];
    const bx = $('#sub-boxes'); bx.innerHTML = '';
    if (m !== 'keep') {
      const d = document.createElement('div'); d.className = 'wbox sub';
      Object.assign(d.style, { left: SUBRECT.x * 100 + '%', top: SUBRECT.y * 100 + '%', width: SUBRECT.w * 100 + '%', height: SUBRECT.h * 100 + '%', transition: 'opacity .8s ease 1.1s' });
      d.innerHTML = '<b>自动找到的字幕</b>';
      if (m === 'crop') { d.style.top = '100%'; d.style.height = '0'; }
      else { bx.append(d); requestAnimationFrame(() => requestAnimationFrame(() => d.style.opacity = 0)); }
    }
  }
  $$('#s-sub .seg button').forEach(b => b.onclick = () => setSubMode(b.dataset.mode));
  setInterval(() => { if (slides[cur].id !== 's-sub') return; const t = subVids[0].currentTime; subVids.slice(1).forEach(v => { if (Math.abs(v.currentTime - t) > .1) v.currentTime = t; }); }, 500);
  hooks['s-sub'] = { enter() { setSubMode('keep'); } };

  // ================= 迭代故事 =================
  hooks['s-story'] = { step(n) { const lefts = [0, 279, 558, 837, 1116, 1394]; $('#rail').style.width = n ? (lefts[n - 1] + 17) + 'px' : '0'; } };

  // ---------- 预加载下一页的视频 ----------
  // 启动：网址里 #页码 可以直接打开某一页
  const start = Math.max(0, Math.min(slides.length - 1, (parseInt(location.hash.slice(1), 10) || 1) - 1));
  slides[start].classList.add('active');
  cur = start;
  go(start);
  setTimeout(() => toast('← → 翻页 · N 讲述提示 · F 全屏', 3200), 900);
  addEventListener('hashchange', () => { const n = (parseInt(location.hash.slice(1), 10) || 1) - 1; if (n !== cur) go(Math.max(0, Math.min(slides.length - 1, n))); });
})();
