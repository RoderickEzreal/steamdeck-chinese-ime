#!/usr/bin/env node
// ============================================================================
//  Steam 屏幕键盘(OSK)中文链路的端到端验证
//
//  原理:Steam 客户端(CEF)自己有一套 IBus 绑定。切到"简体中文(拼音)"布局时它做两件事:
//      await Promise.all(一批 cfg.set_value(...));      // 写引擎配置
//      await bus.set_global_engine("pinyin");           // 切全局引擎
//  ★ 第一步里任何一个写失败,Promise.all 就 reject,第二步永远不会执行 ——
//    引擎停在 xkb:us::eng,打字只有拉丁字母、没有中文候选。
//
//  本脚本在 Steam 客户端内部(通过 CEF DevTools)完整复刻这两步,并真的敲一个键,
//  看 preedit 和候选列表出来没有。这是判断"掌机模式到底能不能打中文"最准的方法。
//
//  前置条件:
//    1. Steam 客户端带 --remote-debugging-port=8080 启动
//       (SteamOS 上可以用 ~/.local/bin/steam -steamdeck ... --remote-debugging-port=8080)
//    2. Steam 客户端正在运行且有页面(标题为 "Steam")
//    3. node >= 22(用全局 WebSocket,无需 npm 包)
//
//  用法: node verify-steam-osk.mjs
// ============================================================================

const PORT = process.env.STEAM_DEBUG_PORT || 8080;
const KEY  = process.env.VERIFY_KEY || 'n';   // 敲哪个键 -> 期望 preedit「你」

// --- Steam 客户端自己的两批引擎配置(与 sp.js 里的常量保持一致) -------------
const PINYIN_CFG = {
    InitChinese: true, InitSimplifiedChinese: true,
    LookupTablePageSize: 5, MinusEqualPage: false,
    CommaPeriodPage: false, AutoCommit: true,
};
const BOPOMOFO_CFG = {
    InitChinese: true, InitSimplifiedChinese: false,
    LookupTablePageSize: 5, MinusEqualPage: false, SelectKeys: 0,
};

// --- 在 Steam 页面里跑的表达式 ---------------------------------------------
const EXPR = `(async () => {
  const out = {};
  const P = ${JSON.stringify(PINYIN_CFG)};
  const D = ${JSON.stringify(BOPOMOFO_CFG)};
  const KEY = ${JSON.stringify(KEY)};

  try {
    const bus = await IBus.bus_new();

    // ---- 1. 引擎表(OSK 判断"这个布局能不能用"就靠它) ----
    try {
      const names = ['pinyin', 'bopomofo', 'table:cangjie5', 'table:quick5'];
      out.engines = {};
      for (const n of names) {
        const r = await bus.get_engines_by_names([n]);
        out.engines[n] = r ? r.length : 0;
      }
    } catch (e) { out.enginesErr = String(e); }

    // ---- 2. 复刻 Promise.all(写引擎配置) ----
    const cfg = await bus.get_config();
    out.hasConfig = !!cfg;
    out.writes = [];
    if (cfg) {
      for (const [k, v] of Object.entries(P)) {
        try { await cfg.set_value('engine/pinyin', k, v); out.writes.push('pinyin/' + k + ' = OK'); }
        catch (e) { out.writes.push('pinyin/' + k + ' = FAIL: ' + String(e)); }
      }
      for (const [k, v] of Object.entries(D)) {
        try { await cfg.set_value('engine/bopomofo', k, v); out.writes.push('bopomofo/' + k + ' = OK'); }
        catch (e) { out.writes.push('bopomofo/' + k + ' = FAIL: ' + String(e)); }
      }
    }
    // 关键判据:模拟 Steam 的 Promise.all 会不会 reject
    out.promiseAllRejects = false;
    try {
      await Promise.all(Object.entries(P).map(([k, v]) => cfg.set_value('engine/pinyin', k, v)));
    } catch (e) { out.promiseAllRejects = true; out.promiseAllErr = String(e); }

    // ---- 3. 切全局引擎 ----
    try { await bus.set_global_engine('pinyin'); out.setEngine = 'OK'; }
    catch (e) { out.setEngine = 'ERR ' + String(e); }
    await new Promise(r => setTimeout(r, 900));

    // ---- 4. 建输入上下文,真的敲一个键 ----
    const CAPS = IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.AUXILIARY_TEXT |
                 IBus.Capabilite.SURROUNDING_TEXT | IBus.Capabilite.LOOKUP_TABLE |
                 IBus.Capabilite.FOCUS | IBus.Capabilite.PROPERTY;
    const ctx = await bus.create_input_context('pinyin');
    await ctx.set_capabilities(CAPS);
    await ctx.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.NONE);
    await ctx.focus_in();
    await new Promise(r => setTimeout(r, 800));

    const st = { preedit: '', cands: [] };
    ctx.connect('update-preedit-text', (t) => { st.preedit = t; });
    ctx.connect('update-lookup-table', async (table) => {
      const n = await table.get_number_of_candidates();
      const arr = [];
      for (let i = 0; i < n; i++) arr.push(await table.get_candidate(i));
      st.cands = arr;
    });

    out.handled = await ctx.process_key_event(KEY.charCodeAt(0), 0, 0);
    await new Promise(r => setTimeout(r, 600));
    out.preedit = st.preedit;
    out.cands = st.cands;
  } catch (e) { out.busErr = String(e); }

  return JSON.stringify(out);
})()`;

// --- 连接 CEF DevTools --------------------------------------------------------
const listRes = await fetch(`http://127.0.0.1:${PORT}/json/list`).catch(() => null);
if (!listRes) {
    console.error(`连不上 127.0.0.1:${PORT} —— Steam 客户端需要带 --remote-debugging-port=${PORT} 启动`);
    process.exit(2);
}
const targets = await listRes.json();
const page = targets.filter(t => t.type === 'page' && t.title === 'Steam')[0];
if (!page) {
    console.error('没找到标题为 "Steam" 的 CEF 页面');
    console.error('当前页面:', targets.map(t => `${t.type}/${t.title}`).join(', '));
    process.exit(2);
}

const result = await new Promise((resolve) => {
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    const timer = setTimeout(() => { try { ws.close(); } catch {} resolve({ error: 'timeout' }); }, 60000);
    ws.onopen = () => ws.send(JSON.stringify({
        id: 1, method: 'Runtime.evaluate',
        params: { expression: EXPR, returnByValue: true, awaitPromise: true },
    }));
    ws.onmessage = (ev) => {
        let msg; try { msg = JSON.parse(ev.data); } catch { return; }
        if (msg.id === 1) { clearTimeout(timer); try { ws.close(); } catch {} resolve(msg.result || msg.error); }
    };
    ws.onerror = () => { clearTimeout(timer); resolve({ error: 'ws error' }); };
});

const raw = result && result.result && result.result.value;
if (!raw) { console.error('执行失败:', JSON.stringify(result).slice(0, 800)); process.exit(2); }
const j = JSON.parse(raw);

console.log('═══ Steam OSK 中文链路验证 ═══\n');
console.log('引擎表 (get_engines_by_names):');
for (const [k, v] of Object.entries(j.engines || {})) {
    console.log(`   ${v > 0 ? '✓' : '✗'} ${k.padEnd(16)} ${v} 个`);
}
console.log('\n引擎配置写入 (Steam 切布局时做的第一批事):');
(j.writes || []).forEach(w => console.log('   ' + w));
console.log(`\nPromise.all 是否 reject : ${j.promiseAllRejects ? '✗ 是 (' + j.promiseAllErr + ')' : '✓ 否'}`);
console.log(`set_global_engine       : ${j.setEngine || '(未执行)'}`);
console.log(`输入 "${KEY}" → preedit  : "${j.preedit}"`);
console.log(`候选                    : ${JSON.stringify(j.cands)}`);
if (j.busErr) console.log('\nbusErr:', j.busErr);
if (/is_connected/.test(j.busErr || '')) {
    console.log('\n── 提示 ──');
    console.log('  当前没有 ibus 守护进程持有 org.freedesktop.IBus。');
    console.log('  掌机模式里它由 ibus-gamescope.service 提供(切到掌机模式再测);');
    console.log('  桌面模式里可以手动起一个来测:');
    console.log('    systemd-run --user --unit=ibus-verify \\');
    console.log('      --property=EnvironmentFile=/run/user/1000/gamescope-environment \\');
    console.log('      /usr/bin/ibus-daemon -r --panel=disable --emoji-extension=disable');
}

console.log('\n── 判定 ──');
const pass = !j.promiseAllRejects
          && (j.setEngine || '').startsWith('OK')
          && (j.preedit || '').length > 0
          && (j.cands || []).length > 0;
if (pass) {
    console.log('✓ 通过 —— 掌机模式 OSK 应该能出中文候选');
    process.exit(0);
} else {
    console.log('✗ 不通过');
    if (j.promiseAllRejects) console.log('  → Promise.all 中断 = ibus 配置写入失败 = dconf profile "ibus" 缺失');
    else if ((j.setEngine || '').startsWith('ERR')) console.log('  → set_global_engine 失败 = 总线名被抢占 / daemon 不是真的 ibus-daemon');
    else console.log('  → 有引擎但没候选 = pinyin 引擎没加载');
    console.log('  详见 docs/gaming-mode.md');
    process.exit(1);
}
