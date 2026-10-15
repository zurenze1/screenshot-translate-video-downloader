(() => {
  'use strict';
  const $ = (s, root = document) => root.querySelector(s);
  const $$ = (s, root = document) => [...root.querySelectorAll(s)];
  const body = document.body;
  const talk = window.PRODUCT_TALK;
  const scenes = $$('.scene');
  const fmt = n => `${Math.floor(n / 60).toString().padStart(2, '0')}:${Math.floor(n % 60).toString().padStart(2, '0')}`;
  let toastTimeout;
  function toast(message) {
    const el = $('#toast'); el.textContent = message; el.hidden = false;
    clearTimeout(toastTimeout); toastTimeout = setTimeout(() => { el.hidden = true; }, 3000);
  }
  let storedMotion;
  try { storedMotion = localStorage.getItem('product-motion'); } catch { /* 浏览器禁用存储时仍可使用 */ }
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
  let motionOff = storedMotion === 'off' || (storedMotion !== 'on' && reduced.matches);
  function updateMotion() {
    body.classList.toggle('motion-off', motionOff);
    body.classList.toggle('has-motion', !motionOff);
    $('#motion-toggle').setAttribute('aria-pressed', String(motionOff));
    $('#motion-toggle').title = motionOff ? '开启动效' : '暂停装饰动效';
    $('#motion-toggle span').textContent = motionOff ? '关' : '开';
  }
  updateMotion();
  $('#motion-toggle').addEventListener('click', () => {
    motionOff = !motionOff; updateMotion();
    try { localStorage.setItem('product-motion', motionOff ? 'off' : 'on'); } catch { /* 无需存储权限 */ }
  });
  reduced.addEventListener('change', e => { motionOff = e.matches; updateMotion(); });
  document.addEventListener('visibilitychange', () => body.classList.toggle('page-hidden', document.hidden));
  const visibility = new IntersectionObserver(entries => entries.forEach(entry => {
    entry.target.classList.toggle('is-offscreen', !entry.isIntersecting);
  }), {threshold: 0});
  scenes.forEach(scene => visibility.observe(scene));
  const reveal = new IntersectionObserver(entries => entries.forEach(entry => {
    if (entry.isIntersecting) { entry.target.classList.remove('awaiting'); reveal.unobserve(entry.target); }
  }), {threshold: .08});
  $$('.section-heading, .translation-layout, .shelf-workspace, .clip-layout, .edit-workspace, .story-opening, .get-heading').forEach(el => {
    el.setAttribute('data-reveal', ''); el.classList.add('awaiting'); reveal.observe(el);
  });
  $('.hero').addEventListener('pointermove', e => {
    if (motionOff || e.pointerType === 'touch') return;
    const r = e.currentTarget.getBoundingClientRect();
    e.currentTarget.style.setProperty('--hero-x', `${((e.clientX - r.left) / r.width - .5) * 9}px`);
    e.currentTarget.style.setProperty('--hero-y', `${((e.clientY - r.top) / r.height - .5) * 7}px`);
  });
  $('.hero').addEventListener('pointerleave', e => { e.currentTarget.style.setProperty('--hero-x', '0px'); e.currentTarget.style.setProperty('--hero-y', '0px'); });
  let scrollQueued = false;
  window.addEventListener('scroll', () => {
    if (scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(() => {
      if (!presenting) {
        const available = document.documentElement.scrollHeight - innerHeight;
        $('#page-progress').style.width = `${available > 0 ? scrollY / available * 100 : 0}%`;
      }
      scrollQueued = false;
    });
  }, {passive: true});

  // 翻译示意：预置双语文本，不调用外部服务，也不读取屏幕。
  $('#translate-switch').addEventListener('click', e => {
    const translated = e.currentTarget.getAttribute('aria-pressed') !== 'true';
    e.currentTarget.setAttribute('aria-pressed', String(translated));
    e.currentTarget.replaceChildren(document.createTextNode(translated ? '恢复原文 ' : '全屏中文 '));
    const key = document.createElement('kbd'); key.textContent = '⌥ T'; e.currentTarget.append(key);
    $$('[data-en]').forEach(el => { el.textContent = translated ? el.dataset.zh : el.dataset.en; });
    $('#translate-state').textContent = translated ? '当前显示中文。再点一下，恢复原文。' : '点击右上角，试试整屏变中文。';
  });
  const samples = [
    ['Save the moment that inspires you.', '留下让你有灵感的那一刻。'],
    ['把时间留给创作。', 'Make more time for creating.'],
    ['〔截图中的字〕 Keep your ideas moving.', '〔识别后翻译〕 让你的想法继续向前。']
  ];
  $('#sample-select').addEventListener('change', e => {
    const [source, result] = samples[Number(e.target.value)];
    $('#sample-source').textContent = source; $('#sample-result').textContent = result;
  });

  // 截图中转站示意：支持框选、键盘、多文件拖到示意文档。
  const grid = $('#shelf-grid');
  const selection = new Set();
  const delivered = new Set();
  const shots = [
    {id:'01', name:'参考画面', bg:'#d5d4bf', shape:'#7d896d'},
    {id:'02', name:'构图灵感', bg:'#e0c9b1', shape:'#aa8062'},
    {id:'03', name:'配色记录', bg:'#c0c8b5', shape:'#e7dfb7'},
    {id:'04', name:'软件界面', bg:'#c9c8c0', shape:'#858a7a'},
    {id:'05', name:'字体参考', bg:'#d7c6a9', shape:'#a68f6d'},
    {id:'06', name:'创作笔记', bg:'#b5bdac', shape:'#7f8b72'}
  ];
  let visibleShots = [...shots];
  let bandOrigin = null;
  let bandBase = new Set();
  let selectedOnDown = false;
  let draggingShot = false;
  function renderShots() {
    $$('.shot', grid).forEach(el => el.remove());
    visibleShots.forEach(shot => {
      const el = document.createElement('button'); el.className = 'shot'; el.type = 'button';
      el.dataset.id = shot.id; el.draggable = true; el.style.setProperty('--shot-bg', shot.bg); el.style.setProperty('--shot-shape', shot.shape);
      el.setAttribute('aria-label', `${shot.name}，截图 ${shot.id}`); el.setAttribute('aria-pressed', String(selection.has(shot.id)));
      const art = document.createElement('span'); art.className = 'shot-art'; art.setAttribute('aria-hidden', 'true');
      const check = document.createElement('span'); check.className = 'shot-check'; check.textContent = '✓'; check.setAttribute('aria-hidden', 'true');
      const name = document.createElement('span'); name.className = 'shot-name'; name.textContent = `${shot.id} / ${shot.name}`;
      el.append(art, check, name);
      el.addEventListener('pointerdown', () => { selectedOnDown = selection.has(shot.id); draggingShot = false; });
      el.addEventListener('click', () => {
        if (draggingShot) return;
        if (selection.has(shot.id)) selection.delete(shot.id); else selection.add(shot.id);
        syncSelection();
      });
      el.addEventListener('dragstart', e => {
        draggingShot = true;
        if (!selectedOnDown && !selection.has(shot.id)) { selection.clear(); selection.add(shot.id); syncSelection(); }
        e.dataTransfer.setData('application/x-product-shots', JSON.stringify([...selection]));
        e.dataTransfer.setData('text/plain', [...selection].map(id => shots.find(s => s.id === id).name).join('、'));
        e.dataTransfer.effectAllowed = 'copy';
      });
      el.addEventListener('dragend', () => { setTimeout(() => { draggingShot = false; }, 0); });
      grid.append(el);
    });
    syncSelection();
  }
  function syncSelection() {
    $$('.shot', grid).forEach(el => {
      const selected = selection.has(el.dataset.id); el.classList.toggle('selected', selected); el.setAttribute('aria-pressed', String(selected));
    });
    $('#shelf-status').textContent = selection.size ? `已选 ${selection.size} 张 · 按住选中的图，拖进右侧文档。` : '空白处拖动框选 · 点击也能多选 · Delete 删除';
    $('#shelf-delete').disabled = !selection.size; $('#shelf-send').disabled = !selection.size;
  }
  renderShots();
  grid.addEventListener('pointerdown', e => {
    if (e.target.closest('.shot') || e.button !== 0 || e.pointerType === 'touch') return;
    const r = grid.getBoundingClientRect();
    bandOrigin = {x:e.clientX - r.left, y:e.clientY - r.top}; bandBase = e.metaKey || e.shiftKey ? new Set(selection) : new Set();
    selection.clear(); bandBase.forEach(id => selection.add(id)); syncSelection();
    grid.focus({preventScroll:true}); grid.setPointerCapture(e.pointerId); e.preventDefault();
  });
  grid.addEventListener('pointermove', e => {
    if (!bandOrigin) return;
    const bounds = grid.getBoundingClientRect();
    const x = Math.max(0, Math.min(bounds.width, e.clientX - bounds.left));
    const y = Math.max(0, Math.min(bounds.height, e.clientY - bounds.top));
    const r = {x:Math.min(bandOrigin.x,x),y:Math.min(bandOrigin.y,y),w:Math.abs(x-bandOrigin.x),h:Math.abs(y-bandOrigin.y)};
    const band = $('#selection-band'); band.hidden = false;
    Object.assign(band.style,{left:`${r.x}px`,top:`${r.y}px`,width:`${r.w}px`,height:`${r.h}px`});
    selection.clear(); bandBase.forEach(id => selection.add(id));
    $$('.shot', grid).forEach(el => {
      const er = el.getBoundingClientRect();
      if (er.left-bounds.left < r.x+r.w && er.right-bounds.left > r.x && er.top-bounds.top < r.y+r.h && er.bottom-bounds.top > r.y) {
        if (bandBase.has(el.dataset.id)) selection.delete(el.dataset.id); else selection.add(el.dataset.id);
      }
    });
    syncSelection();
  });
  const stopBand = () => { bandOrigin = null; $('#selection-band').hidden = true; };
  grid.addEventListener('pointerup',stopBand); grid.addEventListener('pointercancel',stopBand); grid.addEventListener('lostpointercapture',stopBand);
  function deleteShots() {
    const n = selection.size; if (!n) return;
    visibleShots = visibleShots.filter(s => !selection.has(s.id)); selection.clear(); renderShots();
    $('#shelf-status').textContent = `已移除 ${n} 张示意图。点击“重置”可恢复。`;
  }
  $('#shelf-delete').addEventListener('click',deleteShots);
  $('#shelf-all').addEventListener('click', () => { visibleShots.forEach(s => selection.add(s.id)); syncSelection(); });
  $('#shelf-reset').addEventListener('click', () => {
    selection.clear(); delivered.clear(); visibleShots = [...shots]; $('#dropped-images').replaceChildren(); renderShots();
  });
  grid.addEventListener('keydown', e => {
    if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); deleteShots(); }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') { e.preventDefault(); visibleShots.forEach(s => selection.add(s.id)); syncSelection(); }
    if (e.key === 'Escape') { e.stopPropagation(); selection.clear(); syncSelection(); }
  });
  function deliver(ids) {
    const incoming = ids.filter(id => shots.some(s => s.id === id));
    if (!incoming.length) return;
    incoming.forEach(id => delivered.add(id)); $('#dropped-images').replaceChildren();
    [...delivered].forEach(id => {
      const shot = shots.find(s => s.id === id); const mini = document.createElement('span');
      mini.className = 'drop-mini'; mini.style.setProperty('--shot-bg', shot.bg); mini.title = shot.name; mini.setAttribute('aria-label',shot.name);
      $('#dropped-images').append(mini);
    });
    $('#shelf-status').textContent = `已把 ${incoming.length} 张示意图放进文档。实际软件可拖入聊天框、文档与文件夹。`;
    toast(`已放进文档 · ${incoming.length} 张示意图`);
  }
  $('#shelf-send').addEventListener('click', () => deliver([...selection]));
  const destination = $('#shelf-destination');
  destination.addEventListener('dragover', e => {
    if (!e.dataTransfer.types.includes('application/x-product-shots')) return;
    e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; destination.classList.add('drag-over');
  });
  destination.addEventListener('dragleave', () => destination.classList.remove('drag-over'));
  destination.addEventListener('drop', e => {
    e.preventDefault(); destination.classList.remove('drag-over');
    try { const ids = JSON.parse(e.dataTransfer.getData('application/x-product-shots')); if (Array.isArray(ids)) deliver(ids); } catch { toast('先在左侧选中几张示意图。'); }
  });
  destination.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); deliver([...selection]); } });

  // 时间轴操作示意。
  const clipStart = $('#clip-start'), clipEnd = $('#clip-end');
  function updateTimeline(changed) {
    let start = Number(clipStart.value), end = Number(clipEnd.value);
    if (start >= end) {
      if (changed === clipStart) end = Math.min(30,start+1); else start = Math.max(0,end-1);
      clipStart.value = start; clipEnd.value = end;
    }
    $('#clip-duration').textContent = end-start;
    $('#clip-range-label').textContent = `${fmt(start)} — ${fmt(end)}`;
    Object.assign($('#clip-selection').style,{left:`${start/30*100}%`,width:`${(end-start)/30*100}%`});
    clipStart.setAttribute('aria-valuetext',`${start} 秒`); clipEnd.setAttribute('aria-valuetext',`${end} 秒`);
  }
  [clipStart,clipEnd].forEach(input => input.addEventListener('input', () => updateTimeline(input)));
  updateTimeline();

  // 水印与字幕操作示意，有独立撤销栈，不生成伪造的导出文件。
  let editState = {mode:'keep', boxes:[]};
  const editHistory = [];
  const pushEdit = () => editHistory.push({...editState, boxes:[...editState.boxes]});
  const modes = {keep:'保留字幕',erase:'抹掉字幕（填平示意）',crop:'裁掉字幕条（画幅变矮）'};
  function renderEdit() {
    $$('.segmented [data-subtitle]').forEach(el => el.setAttribute('aria-pressed', String(el.dataset.subtitle === editState.mode)));
    const stage = $('#edit-stage'); stage.classList.toggle('erased',editState.mode==='erase'); stage.classList.toggle('cropped',editState.mode==='crop');
    $('#subtitle-zone').hidden = editState.mode === 'keep';
    $('#watermark-boxes').replaceChildren();
    for (const id of editState.boxes) {
      const box = document.createElement('button'); box.className='watermark-box'; box.dataset.position=String(id); box.textContent=`水印 ${id} ×`;
      box.setAttribute('aria-label',`删除水印框 ${id}`); box.addEventListener('click',()=>{pushEdit();editState.boxes=editState.boxes.filter(value=>value!==id);renderEdit();});
      $('#watermark-boxes').append(box);
    }
    $('.wm-one').classList.toggle('removed',editState.boxes.includes(1)); $('.wm-two').classList.toggle('removed',editState.boxes.includes(2));
    $('#edit-status').textContent = `当前：${modes[editState.mode]} · ${editState.boxes.length} 个水印框。网页仅演示操作，不代表真实处理效果。`;
    $('#undo-edit').disabled=!editHistory.length; $('#add-watermark').disabled=editState.boxes.length>=3;
  }
  $$('.segmented [data-subtitle]').forEach(el => el.addEventListener('click',()=>{
    if(editState.mode===el.dataset.subtitle)return;pushEdit();editState.mode=el.dataset.subtitle;renderEdit();
  }));
  $('#add-watermark').addEventListener('click',()=>{if(editState.boxes.length>=3)return;pushEdit();editState.boxes.push([1,2,3].find(id=>!editState.boxes.includes(id)));renderEdit();});
  $('#undo-edit').addEventListener('click',()=>{if(!editHistory.length)return;editState=editHistory.pop();renderEdit();});
  $('#reset-edit').addEventListener('click',()=>{pushEdit();editState={mode:'keep',boxes:[]};renderEdit();});
  renderEdit();

  // 逐字稿和讲解模式共用一份内容。
  let offset = 0;
  const chapterRanges = talk.chapters.map(chapter => {const start=offset;offset+=chapter.seconds;return `${fmt(start)}—${fmt(offset)}`;});
  function paragraph(text,className) { const p=document.createElement('p');p.textContent=text;if(className)p.className=className;return p; }
  const allSpoken = talk.chapters.flatMap(c=>c.paragraphs).join('\n\n');
  const hanCount = (allSpoken.match(/\p{Script=Han}/gu)||[]).length;
  $('#script-stats').textContent=`约 ${hanCount} 个汉字 · 7 个章节 · 时间预算 3 分 35 秒（含演示停顿）\n建议先试讲一遍，按自己的语速调整。`;
  talk.chapters.forEach((chapter,i)=>{
    const section=document.createElement('section');const heading=document.createElement('h3');
    heading.textContent=chapter.title;const time=document.createElement('span');time.textContent=chapterRanges[i];heading.append(time);section.append(heading);
    chapter.paragraphs.forEach(t=>section.append(paragraph(t)));section.append(paragraph(`演示：${chapter.action}`,'script-cue'));$('#script-content').append(section);
  });
  const dialog=$('#script-dialog');let dialogReturnFocus;
  function openScript(){dialogReturnFocus=document.activeElement;dialog.showModal();}
  function closeScript(){dialog.close();}
  $('#script-open').addEventListener('click',openScript);$('#script-close').addEventListener('click',closeScript);
  dialog.addEventListener('click',e=>{if(e.target===dialog){const r=dialog.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeScript();}});
  dialog.addEventListener('close',()=>dialogReturnFocus?.focus({preventScroll:true}));
  $('#copy-script').addEventListener('click',async()=>{
    try{await navigator.clipboard.writeText(allSpoken);toast('逐字稿已复制。');}
    catch{toast('浏览器未允许复制，请选中文字复制，或打开文字版。');}
  });
  let presenting=false,currentChapter=0,previousScroll=0;
  let timerStarted=0,timerElapsed=0,timerRunning=false;
  function updateTimer(){
    const elapsed=Math.floor((timerElapsed+(timerRunning?performance.now()-timerStarted:0))/1000);
    $('#talk-timer').textContent=fmt(elapsed);$('#timer-toggle').setAttribute('aria-label',timerRunning?'暂停讲解计时':'开始讲解计时');
    $('#timer-toggle').firstChild.textContent=timerRunning?'Ⅱ ':'▶ ';
  }
  setInterval(()=>{if(presenting&&timerRunning)updateTimer();},250);
  function toggleTimer(){if(timerRunning){timerElapsed+=performance.now()-timerStarted;timerRunning=false;}else{timerStarted=performance.now();timerRunning=true;}updateTimer();}
  $('#timer-toggle').addEventListener('click',toggleTimer);
  $('#timer-reset').addEventListener('click',()=>{timerElapsed=0;timerStarted=performance.now();updateTimer();toast('讲解计时已归零。');});
  talk.chapters.forEach((chapter,i)=>{
    const dot=document.createElement('button');dot.setAttribute('aria-label',`第 ${i+1} 章：${chapter.title}`);dot.title=chapter.title;
    dot.addEventListener('click',()=>setChapter(i));$('#chapter-dots').append(dot);
  });
  function setChapter(index){
    currentChapter=Math.max(0,Math.min(talk.chapters.length-1,index));
    scenes.forEach((scene,i)=>scene.classList.toggle('is-active',i===currentChapter));
    $$('[data-reveal]').forEach(el=>el.classList.remove('awaiting'));
    $('#chapter-index').textContent=`${String(currentChapter+1).padStart(2,'0')} / 07`;
    $('#chapter-title').textContent=talk.chapters[currentChapter].title;
    $$('#chapter-dots>button').forEach((dot,i)=>dot.setAttribute('aria-current',String(i===currentChapter)));
    $('#prev-chapter').disabled=currentChapter===0;$('#next-chapter').disabled=currentChapter===talk.chapters.length-1;
    $('#page-progress').style.width=`${(currentChapter+1)/talk.chapters.length*100}%`;
    const chapter=talk.chapters[currentChapter];const notes=$('#notes-content');notes.replaceChildren();
    const h=document.createElement('h3');h.textContent=chapter.title;notes.append(h);
    const action=paragraph('','action-cue');const strong=document.createElement('strong');strong.textContent=`${chapterRanges[currentChapter]} · 操作提示`;action.append(strong,document.createTextNode(chapter.action));notes.append(action);
    chapter.paragraphs.forEach(t=>notes.append(paragraph(t)));notes.append(paragraph(chapter.cue,'fine-print'));
    if(presenting)window.scrollTo({top:0,behavior:'instant'});
  }
  function setNotes(show){$('#speaker-notes').hidden=!show;$('#notes-toggle').setAttribute('aria-expanded',String(show));}
  function enterPresent(index=0){
    if(!presenting)previousScroll=scrollY;presenting=true;body.classList.add('presenting');$('#presentation-bar').hidden=false;
    $('#present-toggle').textContent='讲解中 ↗';setChapter(index);timerElapsed=0;timerStarted=performance.now();timerRunning=true;updateTimer();
    const url=new URL(location.href);url.searchParams.set('present','1');url.hash=talk.chapters[currentChapter].id;history.replaceState(null,'',url);
    toast('左右方向键翻章 · N 显示讲述提示 · G 打开逐字稿 · Esc 退出');
  }
  function exitPresent(){
    presenting=false;body.classList.remove('presenting');$('#presentation-bar').hidden=true;setNotes(false);
    if(timerRunning){timerElapsed+=performance.now()-timerStarted;timerRunning=false;}updateTimer();
    $('#present-toggle').replaceChildren(document.createTextNode('开始讲解 ↗'));
    const url=new URL(location.href);url.searchParams.delete('present');url.hash='';history.replaceState(null,'',url);
    window.scrollTo({top:previousScroll,behavior:'instant'});$('#present-toggle').focus({preventScroll:true});
  }
  $('#present-toggle').addEventListener('click',()=>{if(presenting)exitPresent();else enterPresent();});
  $('#present-bottom').addEventListener('click',()=>enterPresent());$('#exit-present').addEventListener('click',exitPresent);
  $('#prev-chapter').addEventListener('click',()=>setChapter(currentChapter-1));$('#next-chapter').addEventListener('click',()=>setChapter(currentChapter+1));
  $('#notes-toggle').addEventListener('click',()=>setNotes($('#speaker-notes').hidden));$('#notes-close').addEventListener('click',()=>setNotes(false));
  $$('a[href^="#"]').forEach(a=>a.addEventListener('click',e=>{
    if(!presenting)return;const index=talk.chapters.findIndex(c=>`#${c.id}`===a.getAttribute('href'));
    if(index>=0){e.preventDefault();setChapter(index);}
  }));
  document.addEventListener('keydown',e=>{
    if(dialog.open)return;
    if(e.target.closest('input,select,textarea,summary,details,.segmented,.shelf-grid,[contenteditable=true]'))return;
    if(presenting){
      if(e.key==='ArrowRight'||e.key==='PageDown'){e.preventDefault();setChapter(currentChapter+1);}
      if(e.key==='ArrowLeft'||e.key==='PageUp'){e.preventDefault();setChapter(currentChapter-1);}
      if(e.key==='Escape'){if(!$('#speaker-notes').hidden)setNotes(false);else exitPresent();}
      if(e.key.toLowerCase()==='n'&&!e.metaKey&&!e.ctrlKey){e.preventDefault();setNotes($('#speaker-notes').hidden);}
      if(e.key.toLowerCase()==='g'&&!e.metaKey&&!e.ctrlKey){e.preventDefault();openScript();}
    }
  });
  setChapter(0);
  $('#page-progress').style.width='0%';
  const query=new URLSearchParams(location.search);
  if(query.get('present')==='1')enterPresent(Math.max(0,talk.chapters.findIndex(c=>`#${c.id}`===location.hash)));
  if(query.get('script')==='1')openScript();
})();
