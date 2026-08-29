#if os(macOS)
import Foundation

// The single page `audition serve` hands out. Everything it draws — the
// sliders, the signal meters, the derivation chain — is generated from the
// JSON the server sends, so adding a planner knob or a chain step needs no
// change here.

let consolePage = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>AutoMix 决策台</title>
<style>
:root{
  --bg:#0e1116; --panel:#161b22; --panel2:#1c2430; --line:#2a3341;
  --fg:#e6edf3; --dim:#9aa7b4; --accent:#4f9cf9; --good:#3fb950;
  --warn:#d29922; --bad:#f85149; --key:#a371f7;
}
@media (prefers-color-scheme:light){
  :root{--bg:#f6f8fa;--panel:#fff;--panel2:#f0f3f6;--line:#d6dee7;
        --fg:#1c2128;--dim:#5b6774;--accent:#0969da;--good:#1a7f37;--warn:#9a6700;}
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
  padding:0 0 11rem;-webkit-text-size-adjust:100%}
/* The transport dock. Auditioning is the point of the page, so the render
   button, the player and the jump-to-the-hand-over control stay reachable
   from anywhere in a long scroll — including while a stem render runs. */
.dock{position:fixed;left:0;right:0;bottom:0;z-index:20;background:var(--panel);
  border-top:1px solid var(--line);padding:.55rem .7rem calc(.55rem + env(safe-area-inset-bottom));
  box-shadow:0 -6px 20px rgba(0,0,0,.22)}
.dock .inner{max-width:860px;margin:0 auto}
.dock audio{height:34px;margin:.35rem 0 0}
.dock .now{font-size:.78rem;color:var(--dim);white-space:nowrap;overflow:hidden;
  text-overflow:ellipsis;flex:1 1 12rem;min-width:0}
.wrap{max-width:860px;margin:0 auto;padding:1rem}
h1{font-size:1.3rem;margin:.3rem 0}
h2{font-size:1.02rem;margin:1.6rem 0 .5rem;padding-top:.9rem;border-top:1px solid var(--line);
  display:flex;align-items:center;justify-content:space-between;gap:.5rem}
.lead{color:var(--dim);font-size:.85rem;margin:.2rem 0 0}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;
  padding:.85rem;margin:.7rem 0}
select,input[type=text],input[type=number],textarea{background:var(--panel2);color:var(--fg);
  border:1px solid var(--line);border-radius:8px;padding:.45rem .5rem;font:inherit;
  font-size:.88rem;width:100%;max-width:100%}
textarea{font:12px/1.5 ui-monospace,Menlo,monospace;resize:vertical}
#aiPreview{font-size:.84rem;line-height:1.7}
#aiPreview code{background:var(--panel2);padding:.05rem .35rem;border-radius:4px;
  font:12px ui-monospace,Menlo,monospace}
button{background:var(--panel2);color:var(--fg);border:1px solid var(--line);
  border-radius:8px;padding:.45rem .75rem;font:inherit;font-size:.85rem;cursor:pointer;
  -webkit-tap-highlight-color:transparent}
button.go{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
button:disabled{opacity:.45;cursor:default}
.row{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}
.row>.grow{flex:1 1 220px;min-width:0}
.pick label{display:block;font-size:.75rem;color:var(--dim);margin:.35rem 0 .15rem}
.chip{display:inline-block;font-size:.75rem;padding:.1rem .55rem;border-radius:99px;
  border:1px solid var(--line);vertical-align:middle}
.chip.compatible{color:var(--good);border-color:var(--good)}
.chip.neutral{color:var(--warn);border-color:var(--warn)}
.chip.clash{color:var(--bad);border-color:var(--bad)}
.chip.na{color:var(--dim)}
.verdict{display:flex;flex-wrap:wrap;gap:.4rem .9rem;align-items:baseline;margin-top:.4rem}
.verdict b{font-size:1.05rem}
.verdict span{font-size:.85rem;color:var(--dim)}
.verdict code{background:var(--panel2);padding:.05rem .35rem;border-radius:4px;
  font:12px ui-monospace,Menlo,monospace;color:var(--fg)}
.tl{margin:.5rem 0}
.tl h4{margin:0 0 .2rem;font-size:.85rem;font-weight:600;
  display:flex;justify-content:space-between;gap:.5rem}
.tl h4 span{color:var(--dim);font-weight:400;font-size:.78rem}
.tl svg{width:100%;height:auto;display:block;border-radius:8px;background:var(--panel2)}
.tl svg.pick{cursor:crosshair}
/* Section band. Same trick as the ruler: the SVG below is squashed to the panel
   width, so any type inside it would stretch — the blocks are HTML, positioned
   in percent off the same time→x mapping, and stay pixel-aligned with it. */
.secband{position:relative;height:1.25rem;margin:.15rem 0 .2rem;border-radius:4px;
  overflow:hidden;background:var(--panel2);font-size:.66rem}
.secband span{position:absolute;top:0;bottom:0;display:flex;align-items:center;
  justify-content:center;overflow:hidden;white-space:nowrap;
  border-right:1px solid var(--panel)}
.secband span i{position:absolute;inset:0;border-radius:0}
.secband span b{position:relative;font-weight:600;padding:0 .2rem}
.secband .none{position:static;display:block;line-height:1.25rem;color:var(--dim);
  padding-left:.4rem;justify-content:flex-start;border:0}
.ruler{position:relative;height:1.1rem;margin-top:.1rem;font-size:.65rem;color:var(--dim);
  overflow:hidden}
.ruler .tick{position:absolute;top:0;transform:translateX(2px);white-space:nowrap}
.ruler .cue{position:absolute;top:0;transform:translateX(-50%);white-space:nowrap;
  color:var(--good);font-weight:600;background:var(--panel);padding:0 .2rem;border-radius:3px}
.legend{font-size:.72rem;color:var(--dim);margin:.25rem 0 0;display:flex;gap:.8rem;flex-wrap:wrap}
.legend i{display:inline-block;width:.7rem;height:.7rem;border-radius:2px;margin-right:.25rem;
  vertical-align:-1px}
.sig{border-top:1px dashed var(--line);padding:.6rem 0}
.sig:first-child{border-top:0}
.sighead{display:flex;justify-content:space-between;align-items:baseline;gap:.5rem;
  font-size:.88rem}
.sighead b{font-variant-numeric:tabular-nums}
.meter{position:relative;height:26px;margin:.45rem 0 .25rem;background:var(--panel2);
  border-radius:6px;border:1px solid var(--line)}
.meter .fill{position:absolute;top:0;bottom:0;left:0;border-radius:5px 0 0 5px;opacity:.28}
.meter .fill.compatible{background:var(--good)}
.meter .fill.neutral{background:var(--warn)}
.meter .fill.clash{background:var(--bad)}
.meter .mark{position:absolute;top:-1px;bottom:-1px;width:2px;background:var(--fg);opacity:.55}
.meter .mark b{position:absolute;top:-1.05rem;left:50%;transform:translateX(-50%);
  font-size:.64rem;color:var(--dim);font-weight:400;white-space:nowrap}
.meter .dot{position:absolute;top:50%;width:11px;height:11px;margin:-5.5px 0 0 -5.5px;
  border-radius:50%;background:var(--accent);box-shadow:0 0 0 2px var(--panel)}
.sigsay{font-size:.8rem;color:var(--dim);margin-top:.5rem}
.chain{counter-reset:s;margin:0;padding:0;list-style:none}
.chain li{position:relative;padding:.5rem 0 .5rem 1.9rem;border-top:1px dashed var(--line)}
.chain li:first-child{border-top:0}
.chain li::before{counter-increment:s;content:counter(s);position:absolute;left:0;top:.55rem;
  width:1.35rem;height:1.35rem;border-radius:50%;border:1px solid var(--line);
  display:flex;align-items:center;justify-content:center;font-size:.7rem;color:var(--dim)}
.chain li.fired::before{background:var(--accent);border-color:var(--accent);color:#fff}
.chain .t{font-size:.88rem;font-weight:600}
.chain .r{font-size:.76rem;color:var(--dim);border-left:2px solid var(--line);
  padding-left:.5rem;margin:.2rem 0}
.chain .d{font-size:.8rem;font-variant-numeric:tabular-nums}
.chain .o{font-size:.84rem;margin-top:.15rem}
.chain li.fired .o{color:var(--accent);font-weight:600}
details{margin:.5rem 0}
summary{cursor:pointer;font-size:.88rem;font-weight:600;padding:.3rem 0}
.knob{display:grid;grid-template-columns:1fr auto;gap:.15rem .5rem;align-items:center;
  padding:.45rem 0;border-top:1px dashed var(--line)}
.knob:first-child{border-top:0}
.knob .n{font:12px ui-monospace,Menlo,monospace}
.knob .v{font:12px ui-monospace,Menlo,monospace;font-variant-numeric:tabular-nums;
  text-align:right;min-width:4.2rem}
.knob.dirty .n{color:var(--accent);font-weight:700}
.knob .b{font-size:.72rem;color:var(--dim);grid-column:1/3}
.knob input[type=range]{grid-column:1/3;width:100%;margin:.15rem 0;accent-color:var(--accent)}
table{width:100%;border-collapse:collapse;font-size:.78rem;margin:.5rem 0}
th,td{border:1px solid var(--line);padding:.3rem .4rem;text-align:left;white-space:nowrap}
th{background:var(--panel2);position:sticky;top:0}
.scroll{overflow-x:auto;-webkit-overflow-scrolling:touch}
tr.changed td{background:color-mix(in srgb,var(--accent) 14%,transparent)}
.was{color:var(--dim);text-decoration:line-through}
audio{width:100%;margin:.4rem 0;height:38px}
.muted{color:var(--dim);font-size:.8rem}
.err{color:var(--bad);font-size:.82rem}
.spin{display:inline-block;width:.8rem;height:.8rem;border:2px solid var(--line);
  border-top-color:var(--accent);border-radius:50%;animation:spin .7s linear infinite;
  vertical-align:-1px}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<div class="wrap">
  <h1>AutoMix 决策台</h1>
  <p class="lead" id="lead">加载中…</p>

  <div class="card pick">
    <div class="row">
      <div class="grow">
        <label for="outSel">出曲</label>
        <select id="outSel"></select>
      </div>
      <div class="grow">
        <label for="inSel">入曲</label>
        <select id="inSel"></select>
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <button id="prevPair">← 上一对</button>
      <button id="nextPair">下一对 →</button>
      <button id="swap">⇄ 对调</button>
      <span class="muted" id="planTime"></span>
    </div>
    <details>
      <summary>用本机上任意两个文件</summary>
      <div class="row" style="margin-top:.4rem">
        <div class="grow"><input type="text" id="outPath" placeholder="/path/to/outgoing.flac"></div>
        <div class="grow"><input type="text" id="inPath" placeholder="/path/to/incoming.flac"></div>
        <button id="usePaths">用这两个路径</button>
      </div>
      <p class="muted">第一次分析一首没分析过的曲子要几秒。</p>
    </details>
  </div>

  <div class="card" id="verdictCard">
    <div class="verdict" id="verdict"></div>
    <div class="muted" id="nearMisses"></div>
    <div class="err" id="err"></div>
  </div>

  <h2>这一对的交接点 <span class="muted" id="planOvState">跟着规划器走</span></h2>
  <div class="card">
    <p class="muted">上面的 36 个旋钮是全局的：一动，整个语料的每一对都跟着变。
      如果你只是想给<b>这一对</b>换个交接点——比如让出曲的人声多唱完一句，
      或让入曲从更早的纯伴奏前奏进来——在这里直接写死就行。
      留空的那一项沿用规划器算出来的值。也可以直接在下面的时间轴上点一下：
      点出曲设出点，点入曲设入点。</p>
    <div class="row">
      <div class="grow">
        <label class="muted" for="ovOut">出点（出曲，秒或 mm:ss）</label>
        <input type="text" id="ovOut" placeholder="规划器的值" inputmode="decimal">
      </div>
      <div class="grow">
        <label class="muted" for="ovIn">入点（入曲，秒或 mm:ss）</label>
        <input type="text" id="ovIn" placeholder="规划器的值" inputmode="decimal">
      </div>
      <div class="grow">
        <label class="muted" for="ovLen">叠多久（秒）</label>
        <input type="text" id="ovLen" placeholder="规划器的值" inputmode="decimal">
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <button id="ovApply" class="go">用这个交接点</button>
      <button id="ovReset">回到规划器的选择</button>
      <span class="muted" id="ovHint"></span>
    </div>
    <div class="err" id="ovErr" style="margin-top:.35rem"></div>
  </div>

  <h2>两首歌长什么样</h2>
  <div id="timelines"></div>
  <p class="legend">
    <span><i style="background:var(--accent);opacity:.5"></i>音量起伏</span>
    <span><i style="background:var(--key)"></i>人声密度</span>
    <span><i style="background:var(--good);opacity:.45"></i>两首歌叠在一起的那一段</span>
    <span><i style="background:var(--warn);opacity:.35"></i>前奏 / 尾奏</span>
    <span>▾ 乐句起点 · 底部细刻度 = 每小节第一拍 · 顶部细刻度 = 歌词行</span>
  </p>
  <p class="legend">
    段落条（还只是给人眼核对用的，规划器暂时不读它）：
    <span><i style="background:var(--dim);opacity:.3"></i>前奏 / 尾奏</span>
    <span><i style="background:var(--accent);opacity:.34"></i>主歌</span>
    <span><i style="background:var(--warn);opacity:.55"></i>副歌</span>
    <span><i style="background:var(--key);opacity:.34"></i>过渡</span>
    <span><i style="background:var(--bad);opacity:.48"></i>drop</span>
  </p>

  <h2>五项信号：系统在看什么</h2>
  <div class="card" id="signals"></div>

  <h2>它是怎么一步步想出来的</h2>
  <div class="card"><ol class="chain" id="chain"></ol></div>

  <h2>参数：<span id="knobCount">…</span> 个可以拧的旋钮 <span class="muted" id="diffCount"></span></h2>
  <div class="card">
    <div class="row">
      <button id="resetAll">全部恢复出厂设置</button>
      <div class="grow"><input type="text" id="cfgName" placeholder="给这套参数起个名字"></div>
      <button id="saveCfg">保存</button>
      <select id="cfgList" style="max-width:12rem"></select>
      <button id="loadCfg">载入</button>
    </div>
    <div id="diffBox" class="muted" style="margin-top:.4rem"></div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted" for="styleSel">出曲怎么离场（不选就让系统自己决定）</label>
        <select id="styleSel"></select>
      </div>
      <div class="grow">
        <label class="muted" for="fadeOv">强制叠加多少秒（0 = 让系统自己算）</label>
        <input type="number" id="fadeOv" value="0" min="0" max="60" step="0.5">
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted">
          <input type="checkbox" id="stemsReady" checked style="width:auto;margin-right:.35rem">
          告诉规划器「人声分离可用」（这台机器模型就绪，所以默认开）
        </label>
        <p class="muted" style="margin:.15rem 0 0;font-size:.75rem">
          关掉 = 产品里的默认行为，规划器完全不看下面那组 stem 参数，
          结论与没有 stem 功能时逐字段一致。打开后它可以自己选 vocal duck / acapella over，
          并把交接点挪到出曲还在唱的地方。</p>
      </div>
    </div>
    <div class="row" style="margin-top:.5rem">
      <div class="grow">
        <label class="muted" for="stemSel">手动指定 stem 手法（盖掉规划器的选择，只影响试听渲染）</label>
        <select id="stemSel"></select>
      </div>
      <div class="grow" id="duckBox" style="display:none">
        <label class="muted" for="duckDB">vocal duck 深度 <b id="duckVal">−9.0 dB</b></label>
        <input type="range" id="duckDB" min="0" max="24" step="0.5" value="9"
               style="width:100%;accent-color:var(--accent)">
      </div>
    </div>
    <p class="muted" id="stemNote">stem 手法要先把出曲的叠加窗分离成人声/伴奏，首次约 20s，
      同一窗口再渲染走 sidecar 缓存。批量视图不跑 stem。
      vocal exchange 还要再分离一次入曲，所以第一次约 40s。</p>
  </div>

  <div id="envWrap" style="display:none">
    <h2>这次交接的四条增益曲线</h2>
    <div class="card">
      <p class="muted" id="envNote"></p>
      <div class="tl" id="envPlot"></div>
      <p class="legend" id="envLegend"></p>
      <div class="row" id="envHandRow" style="display:none">
        <span class="muted">这四条曲线是手写的（AI 给的 stemEnvelope），不是模板生成的。</span>
        <button id="envClear">清除，回到手法选择</button>
      </div>
    </div>
  </div>
  <div id="knobs"></div>

  <h2>把整个语料跑一遍 <button id="batchBtn">开始</button></h2>
  <div class="card">
    <p class="muted" id="batchInfo">用当前参数把语料里所有相邻的歌两两跑一遍，和出厂设置的结果逐格对照。</p>
    <div class="scroll"><table id="batchTable"></table></div>
  </div>

  <h2>让 AI 帮你调</h2>
  <div class="card">
    <p class="muted">把这一页现在看到的一切——系统怎么决策、每个参数各是什么意思和当前取值、
      这一对歌的五项信号和判断过程、你改动过哪些参数，加上两首歌的逐 2 秒音量/人声曲线、
      小节线、乐句起点和带时间戳的歌词——打包成一段纯文本，
      贴给任意一个 AI 聊天窗口，它回一段 JSON，再贴回来就能应用。
      它既可以改全局参数，也可以只给<b>这一对</b>指定出点、入点和叠加长度。</p>
    <div class="row">
      <button id="copyAI" class="go">复制给 AI</button>
      <span class="muted" id="copyInfo"></span>
    </div>
    <textarea id="copyFallback" style="display:none;width:100%;height:9rem;margin-top:.5rem"></textarea>
    <div style="margin-top:.8rem">
      <label class="muted" for="aiPaste">粘贴 AI 的回复（带解释文字也没关系，会自动挑出里面的 JSON）</label>
      <textarea id="aiPaste" style="width:100%;height:7rem"
        placeholder='例如：&#10;```json&#10;{"config": {"neutralTimbreDistance": 0.3}, "rationale": "…"}&#10;```'></textarea>
    </div>
    <div class="row" style="margin-top:.4rem">
      <button id="parseAI">看看它想改什么</button>
      <button id="applyAI" class="go" style="display:none">确认应用</button>
      <button id="cancelAI" style="display:none">取消</button>
    </div>
    <div id="aiPreview" style="margin-top:.5rem"></div>
  </div>
</div>

<div class="dock"><div class="inner">
  <div class="row">
    <button id="renderBtn" class="go">渲染试听</button>
    <button id="toOverlap">跳到交接前 3s</button>
    <span class="now" id="renderInfo">点「渲染试听」听听当前这一版（前后各带 12 秒上下文）。</span>
  </div>
  <audio id="audio" controls preload="none"></audio>
</div></div>

<script>
const $ = s => document.querySelector(s);
let BOOT = null, CONFIG = {}, REPORT = null, LAST_RENDER = null, BATCH = null;
/// A hand-written four-lane orchestration for the current pair, or null. Like
/// `PLAN_OV` it belongs to one seam, so switching pairs drops it.
let STEM_ENV = null;

// The three tiers, said the way a person would say them. The English term is
// kept as a small annotation rather than dropped: it is what the code, the
// CLI and the batch report all call it.
const TIER_TEXT = {
  compatible: "这两首歌很搭",
  neutral: "一般般，能接但别贪",
  clash: "差异很大，快进快出",
};
const tierText = t => TIER_TEXT[t] || t;

const OV_LABEL = {outPoint: "出点", inPoint: "入点", overlap: "叠加长度"};

const fmt = (v, d = 2) => (v === null || v === undefined) ? "—" : Number(v).toFixed(d);
const mmss = t => (t === null || t === undefined) ? "—"
  : `${Math.floor(t / 60)}:${(t % 60).toFixed(2).padStart(5, "0")}`;

async function api(path, body) {
  const opt = body ? {method: "POST", body: JSON.stringify(body)} : {};
  const r = await fetch(path, opt);
  const j = await r.json();
  if (j.error) throw new Error(j.error);
  return j;
}

// ---------------------------------------------------------------- boot

async function boot() {
  BOOT = await api("/api/bootstrap");
  $("#lead").textContent = `${BOOT.corpus} · ${BOOT.tracks.length} 首歌 · ${BOOT.fields.length} 个可调参数。`
    + `选一对歌，看系统怎么决定它们之间的过渡，改参数，然后在底部渲染出来听。`;
  for (const sel of ["#outSel", "#inSel"]) {
    $(sel).innerHTML = BOOT.tracks
      .map(t => `<option value="${t.path}">${t.name}</option>`).join("");
  }
  if (BOOT.pairs.length) {
    $("#outSel").value = BOOT.pairs[0].outgoing;
    $("#inSel").value = BOOT.pairs[0].incoming;
  }
  $("#styleSel").innerHTML = ['<option value="auto">auto（planner 自己选）</option>']
    .concat(BOOT.styles.map(s => `<option value="${s}">${s}</option>`)).join("");
  const STEM_LABEL = {
    acapella: "acapella over — 出曲人声飘在入曲上",
    instrumental: "instrumental out — 出曲抹掉人声收尾",
    duck: "vocal duck — 出曲人声压低",
    exchange: "vocal exchange — 编排一次人声交接（读歌词定交接句）",
  };
  $("#stemSel").innerHTML = ['<option value="none">none（不用 stem）</option>']
    .concat((BOOT.stems || []).map(s => `<option value="${s}">${STEM_LABEL[s] || s}</option>`))
    .join("");
  $("#duckDB").value = Math.abs(BOOT.duckDefaultDB ?? 9);
  $("#knobCount").textContent = BOOT.fields.length;
  paintDuck();
  CONFIG = Object.assign({}, BOOT.standard);
  buildKnobs();
  refreshConfigList(BOOT.configs);
  plan();
}

// ---------------------------------------------------------------- knobs

const GROUPS = {
  tier: "先判断两首歌搭不搭（很搭 / 一般般 / 差异很大）",
  beatmatch: "能不能踩到同一个拍子上",
  overlap: "两首歌该叠多久",
  shape: "从哪里交接、出曲怎么离场",
  stem: "要不要动用人声分离（只在上面的「人声分离可用」打开时才生效）",
};

function buildKnobs() {
  let html = "";
  for (const [g, title] of Object.entries(GROUPS)) {
    const fs = BOOT.fields.filter(f => f.group === g);
    if (!fs.length) continue;
    html += `<details ${g === "tier" ? "open" : ""}><summary>${title}</summary><div class="card">`;
    for (const f of fs) {
      html += `<div class="knob" id="k-${f.name}">
        <div class="n">${f.name}</div>
        <div class="v" id="v-${f.name}">${Number(f.standard).toFixed(f.digits)}</div>
        <div class="b">${f.blurb}</div>
        <input type="range" data-name="${f.name}" min="${f.min}" max="${f.max}"
               step="${f.step}" value="${f.standard}">
      </div>`;
    }
    html += "</div></details>";
  }
  $("#knobs").innerHTML = html;
  $("#knobs").addEventListener("input", e => {
    const name = e.target.dataset.name;
    if (!name) return;
    CONFIG[name] = parseFloat(e.target.value);
    paintKnob(name);
    schedulePlan();
  });
}

function paintKnob(name) {
  const f = BOOT.fields.find(x => x.name === name);
  $("#v-" + name).textContent = Number(CONFIG[name]).toFixed(f.digits);
  $("#k-" + name).classList.toggle("dirty", Math.abs(CONFIG[name] - f.standard) > 1e-12);
  paintDiff();
}

function paintDiff() {
  const diff = BOOT.fields.filter(f => Math.abs(CONFIG[f.name] - f.standard) > 1e-12);
  $("#diffCount").textContent = diff.length ? `${diff.length} 项和出厂设置不同` : "和出厂设置一致";
  $("#diffBox").innerHTML = diff.length
    ? diff.map(f => `<code>${f.name}</code> ${Number(f.standard).toFixed(f.digits)}`
        + ` → <b>${Number(CONFIG[f.name]).toFixed(f.digits)}</b>`).join(" · ")
    : "当前每一个参数都还是出厂设置。";
}

function applyConfig(cfg) {
  CONFIG = Object.assign({}, BOOT.standard, cfg || {});
  for (const f of BOOT.fields) {
    const el = document.querySelector(`input[data-name="${f.name}"]`);
    if (el) el.value = CONFIG[f.name];
    paintKnob(f.name);
  }
  plan();
}

// ---------------------------------------------------------------- plan

let planTimer = null, planSeq = 0;
function schedulePlan() {
  clearTimeout(planTimer);
  planTimer = setTimeout(plan, 90);
}

function paintDuck() {
  const stem = $("#stemSel").value;
  $("#duckBox").style.display = stem === "duck" ? "" : "none";
  $("#duckVal").textContent = `−${Number($("#duckDB").value).toFixed(1)} dB`;
}

function requestBody() {
  const fade = parseFloat($("#fadeOv").value) || 0;
  const body = {
    outgoing: $("#outSel").value, incoming: $("#inSel").value,
    config: CONFIG, style: $("#styleSel").value, fade: fade,
    stem: $("#stemSel").value,
    stems: $("#stemsReady").checked,
    duckDB: -Math.abs(parseFloat($("#duckDB").value) || 9),
  };
  // A hand-written envelope replaces the technique picker outright — the two
  // are mutually exclusive on the server, and it is the more specific of them.
  if (STEM_ENV) { body.stem = "none"; body.stemEnvelope = STEM_ENV; }
  const ov = {};
  for (const k of ["outPoint", "inPoint", "overlap"]) {
    if (PLAN_OV[k] !== null && PLAN_OV[k] !== undefined) ov[k] = PLAN_OV[k];
  }
  if (Object.keys(ov).length) body.planOverride = ov;
  return body;
}

// ------------------------------------------------- plan-level override
//
// The 36 knobs are global; this is the one control that speaks about a single
// seam. It rides the same request the sliders do, so a hand-placed out point
// re-plans, re-explains and re-renders exactly like a knob move.

let PLAN_OV = {outPoint: null, inPoint: null, overlap: null};

/// `199.5`, `"199.5"`, `"3:19.5"`, `"1:03:19"` → seconds; null otherwise.
/// Same grammar the server accepts, so the preview never promises something
/// the server will refuse.
function secondsFrom(raw) {
  const text = String(raw).trim();
  if (!text) return null;
  if (!text.includes(":")) {
    const v = Number(text);
    return isFinite(v) && v >= 0 ? v : null;
  }
  const parts = text.split(":");
  if (parts.length < 2 || parts.length > 3) return null;
  let total = 0;
  for (let i = 0; i < parts.length; i++) {
    // `Number("")` is 0, not NaN — "3:" must not read as three minutes flat.
    if (!parts[i].trim()) return null;
    const v = Number(parts[i]);
    if (!isFinite(v) || v < 0) return null;
    if (i > 0 && v >= 60) return null;
    total = total * 60 + v;
  }
  return total;
}

/// The rules the server enforces, mirrored so a bad number is refused before
/// it costs a round trip. Returns an error string, or null when it is fine.
function planOverrideError(ov) {
  if (!REPORT) return null;
  const outDur = REPORT.outgoing.duration, inDur = REPORT.incoming.duration;
  const maxOv = BOOT.maxManualOverlap ?? 40, minOv = BOOT.minManualOverlap ?? 0.5;
  const o = ov.outPoint ?? REPORT.plan.plannerOutPoint ?? REPORT.plan.outPoint;
  const i = ov.inPoint ?? REPORT.plan.plannerInPoint ?? REPORT.plan.inPoint;
  const d = ov.overlap ?? Math.max(REPORT.plan.plannerOverlap ?? 0, minOv);
  if (o === null || o === undefined || i === null || i === undefined) return null;
  if (o >= outDur) return `出点 ${mmss(o)} 超出了出曲的时长 ${mmss(outDur)}。`;
  if (i >= inDur) return `入点 ${mmss(i)} 超出了入曲的时长 ${mmss(inDur)}。`;
  if (d > maxOv) return `叠加 ${fmt(d)} 秒，超过 ${maxOv} 秒的上限。`;
  if (d < minOv) return `叠加 ${fmt(d)} 秒，短于 ${minOv} 秒的下限。`;
  if (outDur - o + 1e-6 < d)
    return `出点 ${mmss(o)} 之后只剩 ${fmt(outDur - o)} 秒，放不下 ${fmt(d)} 秒的叠加。`;
  if (inDur - i + 1e-6 < d)
    return `入点 ${mmss(i)} 之后只剩 ${fmt(inDur - i)} 秒，放不下 ${fmt(d)} 秒的叠加。`;
  return null;
}

/// Read the three boxes into `PLAN_OV`. Returns false (and paints the error)
/// when something does not parse or does not fit.
function readPlanOverride() {
  const fields = [["#ovOut", "outPoint"], ["#ovIn", "inPoint"], ["#ovLen", "overlap"]];
  const next = {outPoint: null, inPoint: null, overlap: null};
  for (const [sel, key] of fields) {
    const raw = $(sel).value.trim();
    if (!raw) continue;
    const v = secondsFrom(raw);
    if (v === null) {
      $("#ovErr").textContent = `「${raw}」看不懂：用秒（199.5）或 mm:ss（3:19.5）。`;
      return false;
    }
    next[key] = v;
  }
  const err = planOverrideError(next);
  if (err) { $("#ovErr").textContent = err; return false; }
  $("#ovErr").textContent = "";
  PLAN_OV = next;
  return true;
}

function paintPlanOverride() {
  const on = ["outPoint", "inPoint", "overlap"].filter(k => PLAN_OV[k] !== null);
  $("#planOvState").innerHTML = on.length
    ? `<b class="chip clash">这一对的 ${on.length} 项是手动指定的</b>`
    : "跟着规划器走";
  if (!REPORT) return;
  const p = REPORT.plan;
  $("#ovOut").placeholder = mmss(p.plannerOutPoint ?? p.outPoint);
  $("#ovIn").placeholder = mmss(p.plannerInPoint ?? p.inPoint);
  $("#ovLen").placeholder = fmt(p.plannerOverlap ?? p.overlapDuration);
  const maxOv = BOOT.maxManualOverlap ?? 40;
  const moves = [];
  if (PLAN_OV.outPoint !== null)
    moves.push(`出点 ${mmss(p.plannerOutPoint)} → ${mmss(p.outPoint)}`);
  if (PLAN_OV.inPoint !== null)
    moves.push(`入点 ${mmss(p.plannerInPoint)} → ${mmss(p.inPoint)}`);
  if (PLAN_OV.overlap !== null)
    moves.push(`叠加 ${fmt(p.plannerOverlap)} → ${fmt(p.overlapDuration)} 秒`);
  $("#ovHint").innerHTML = moves.length
    ? "已覆盖：" + moves.join(" · ")
    : `出曲 ${mmss(REPORT.outgoing.duration)} · 入曲 ${mmss(REPORT.incoming.duration)}`
      + ` · 叠加上限 ${maxOv} 秒`;
}

/// Apply a patch to the override — from a timeline click, or from an AI reply.
/// A patch that does not fit is refused outright rather than half-applied, so
/// `PLAN_OV` never holds a geometry the server would reject.
function setPlanOverride(patch, replan = true) {
  const next = Object.assign({}, PLAN_OV, patch);
  const err = planOverrideError(next);
  $("#ovErr").textContent = err || "";
  if (err) return false;
  PLAN_OV = next;
  $("#ovOut").value = PLAN_OV.outPoint === null ? "" : PLAN_OV.outPoint.toFixed(2);
  $("#ovIn").value = PLAN_OV.inPoint === null ? "" : PLAN_OV.inPoint.toFixed(2);
  $("#ovLen").value = PLAN_OV.overlap === null ? "" : PLAN_OV.overlap.toFixed(2);
  paintPlanOverride();
  if (replan) plan();
  return true;
}

$("#ovApply").onclick = () => { if (readPlanOverride()) { paintPlanOverride(); plan(); } };
$("#ovReset").onclick = () => {
  $("#ovOut").value = $("#ovIn").value = $("#ovLen").value = "";
  setPlanOverride({outPoint: null, inPoint: null, overlap: null});
};
for (const sel of ["#ovOut", "#ovIn", "#ovLen"]) {
  $(sel).addEventListener("keydown", e => { if (e.key === "Enter") $("#ovApply").click(); });
}

async function plan() {
  const seq = ++planSeq;
  const t0 = performance.now();
  try {
    const r = await api("/api/plan", requestBody());
    if (seq !== planSeq) return;               // a newer drag已经在路上
    REPORT = r;
    $("#err").textContent = "";
    $("#planTime").textContent = `重算 ${Math.round(performance.now() - t0)} ms`;
    paintVerdict(); paintPlanOverride(); paintTimelines(); paintSignals(); paintChain();
    paintEnvelope();
  } catch (e) {
    if (seq !== planSeq) return;
    $("#err").textContent = String(e.message || e);
    // A rejected hand-written envelope must stay reachable, or the page is
    // wedged on an error it cannot be told to drop.
    if (STEM_ENV) {
      $("#envWrap").style.display = "";
      $("#envHandRow").style.display = "";
    }
  }
}

function paintVerdict() {
  const r = REPORT;
  const bars = r.plan.overlapBars ? ` (${r.plan.overlapBars} 小节)` : "";
  const rates = r.plan.outgoingRate
    ? `<span>为了对拍各自变速 <code>${((r.plan.outgoingRate - 1) * 100).toFixed(2)}% / `
      + `${((r.plan.incomingRate - 1) * 100).toFixed(2)}%</code></span>`
    : "";
  const PLAN_TEXT = {
    beatMatched: "踩着同一个拍子叠进去",
    crossfade: "普通的交叉淡入淡出",
    gapless: "不做过渡，一首接一首",
  };
  $("#verdict").innerHTML = `
    <b class="chip ${r.tier}">${tierText(r.tier)}</b>
    <b>${PLAN_TEXT[r.plan.kind] || r.plan.kind}</b>
    <span>出曲怎么离场 <code>${r.style.description}</code></span>
    <span>叠多久 <code>${fmt(r.plan.overlapDuration)} 秒${bars}</code></span>
    <span>出曲从 <code>${mmss(r.plan.outPoint)}</code> 开始交接</span>
    <span>入曲从 <code>${mmss(r.plan.inPoint)}</code> 进来</span>
    ${rates}
    ${r.demotedByKey ? '<span class="chip neutral">因为和声不合降了一级</span>' : ""}
    ${r.overridden ? '<span class="chip clash">这一版是手动改过的</span>' : ""}
    ${(r.plan.overrideFields || []).length
      ? `<span class="chip clash">交接点是人工/AI 指定的（${
          r.plan.overrideFields.map(f => OV_LABEL[f] || f).join("、")}）</span>` : ""}
    <span class="muted" style="font-size:.72rem">（内部术语：${r.tier} / ${r.plan.kind}）</span>`;
  $("#nearMisses").innerHTML = r.nearMisses.length
    ? "⚠︎ 这几项就卡在门槛边上，参数稍微一动结论就会翻过去：" + r.nearMisses.join(" · ") : "";
}

// ---------------------------------------------------------------- timelines

// Section kinds, in the console's own palette. Chorus is the loud colour on
// purpose — it is the block every cue decision is measured against.
const SECTION_STYLE = {
  intro:  {c: "var(--dim)",    o: .30, label: "前奏"},
  verse:  {c: "var(--accent)", o: .34, label: "主歌"},
  chorus: {c: "var(--warn)",   o: .55, label: "副歌"},
  bridge: {c: "var(--key)",    o: .34, label: "过渡"},
  drop:   {c: "var(--bad)",    o: .48, label: "drop"},
  outro:  {c: "var(--dim)",    o: .30, label: "尾奏"},
};

/// The structure band above a timeline. Empty sections are not a rendering
/// failure — they are the segmenter refusing to guess, and the band says which
/// confidence it refused at, because that number is the thing being tuned.
function sectionBand(t) {
  const conf = `分段置信度 ${fmt(t.structureConfidence)}`;
  if (!t.sections || !t.sections.length)
    return `<div class="secband"><span class="none">${conf}——没到门槛，`
      + "这首没有可信的段落划分（下游照旧走能量启发式）</span></div>";
  const pct = s => (s / t.duration) * 100;
  const blocks = t.sections.map(s => {
    const st = SECTION_STYLE[s.kind] || {c: "var(--dim)", o: .3, label: s.kind};
    const left = pct(s.start), width = Math.max(0.4, pct(s.end) - left);
    const title = `${st.label} ${mmss(s.start)}–${mmss(s.end)} · 重复 ${s.repetition}`
      + ` · 能量 ${fmt(s.energy)} · 人声 ${fmt(s.vocalDensity)}`;
    return `<span style="left:${left.toFixed(2)}%;width:${width.toFixed(2)}%" title="${title}"
      ><i style="background:${st.c};opacity:${st.o}"></i><b>${st.label}</b></span>`;
  }).join("");
  return `<div class="secband">${blocks}</div>`;
}

function timeline(t, role, r) {
  const W = 1000, H = 132, PAD = 4;
  const x = s => PAD + (s / t.duration) * (W - 2 * PAD);
  const top = 14, base = H - 20, h = base - top;
  let g = "";


  // intro / outro shading
  if (t.introEnd > 0)
    g += `<rect x="${x(0)}" y="${top}" width="${x(t.introEnd) - x(0)}" height="${h}"
           fill="var(--warn)" opacity=".16"/>`;
  if (t.outroFadeStart !== null && t.outroFadeStart !== undefined)
    g += `<rect x="${x(t.outroFadeStart)}" y="${top}"
           width="${x(t.duration) - x(t.outroFadeStart)}" height="${h}"
           fill="var(--warn)" opacity=".16"/>`;

  // overlap window
  const start = role === "out" ? r.plan.outPoint : r.plan.inPoint;
  if (start !== null && start !== undefined && r.plan.overlapDuration > 0) {
    const x0 = x(start), x1 = x(Math.min(t.duration, start + r.plan.overlapDuration));
    g += `<rect x="${x0}" y="${top}" width="${Math.max(1.5, x1 - x0)}" height="${h}"
           fill="var(--good)" opacity=".33"/>`;
    g += `<line x1="${x0}" y1="${top - 6}" x2="${x0}" y2="${base}"
           stroke="var(--good)" stroke-width="2"/>`;
  }

  // RMS envelope, as a filled area
  if (t.rms.length > 1) {
    const step = (W - 2 * PAD) / (t.rms.length - 1);
    let d = `M ${PAD} ${base}`;
    t.rms.forEach((v, i) => { d += ` L ${(PAD + i * step).toFixed(1)} ${(base - v * h).toFixed(1)}`; });
    d += ` L ${W - PAD} ${base} Z`;
    g += `<path d="${d}" fill="var(--accent)" opacity=".45"/>`;
  }
  // vocal activity
  if (t.vocal.length > 1) {
    const step = (W - 2 * PAD) / (t.vocal.length - 1);
    let d = "";
    t.vocal.forEach((v, i) => {
      d += `${i ? "L" : "M"} ${(PAD + i * step).toFixed(1)} ${(base - v * h).toFixed(1)} `;
    });
    g += `<path d="${d}" fill="none" stroke="var(--key)" stroke-width="1.4" opacity=".95"/>`;
  }
  // Lyric lines as ticks along the top, drawn over the curves. Free ground
  // truth for the section band above: a chorus boundary that does not sit where
  // the repeated block of lines starts is a wrong boundary, and that is visible
  // without anyone annotating anything.
  const ly = (REPORT.lyrics || {})[role === "out" ? "outgoing" : "incoming"];
  for (const time of (ly && ly.times) || []) {
    if (time < 0 || time > t.duration) continue;
    g += `<line x1="${x(time).toFixed(1)}" y1="${top}" x2="${x(time).toFixed(1)}" y2="${top + 6}"
           stroke="var(--fg)" opacity=".45"/>`;
  }
  // downbeat grid
  g += t.downbeats.map(d =>
    `<line x1="${x(d).toFixed(1)}" y1="${base}" x2="${x(d).toFixed(1)}" y2="${base + 4}"
      stroke="var(--fg)" opacity=".22"/>`).join("");
  // phrase boundaries, best first — the top few are the real candidates
  g += t.phraseBoundaries.slice(0, 24).map((p, i) =>
    `<polygon points="${x(p) - 4},${top - 8} ${x(p) + 4},${top - 8} ${x(p)},${top - 1}"
      fill="var(--fg)" opacity="${(0.75 - i * 0.02).toFixed(2)}"/>`).join("");
  // minute ruler ticks (the labels live in HTML below, so squashing the
  // viewBox to the panel width never squashes the type)
  for (let s = 0; s <= t.duration; s += 60) {
    g += `<line x1="${x(s)}" y1="${base}" x2="${x(s)}" y2="${base + 8}" stroke="var(--dim)"/>`;
  }

  const pct = s => (PAD + (s / t.duration) * (W - 2 * PAD)) / W * 100;
  let ruler = "";
  for (let s = 0; s <= t.duration; s += 60) {
    ruler += `<span class="tick" style="left:${pct(s)}%">${s / 60}m</span>`;
  }
  if (start !== null && start !== undefined) {
    // Keep the cue label inside the panel at either end of the track.
    const p = pct(start);
    const shift = p > 78 ? "-100%" : (p < 12 ? "0" : "-50%");
    ruler += `<span class="cue" style="left:${p}%;transform:translateX(${shift})">${
      role === "out" ? "out" : "in"} ${mmss(start)}</span>`;
  }
  // `data-*` is what the click handler reads: clicking anywhere on the
  // outgoing timeline sets the out point, the incoming one the in point.
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" class="pick"
           data-role="${role}" data-duration="${t.duration}" data-pad="${PAD}"
           style="height:132px">${g}</svg><div class="ruler">${ruler}</div>`;
}

/// Click a timeline to move that side's cue. The same path the number boxes
/// and the AI's `planOverride` take — this is just a faster way to type a
/// number you can see.
function timelineClick(e) {
  const svg = e.target.closest("svg.pick");
  if (!svg || !REPORT) return;
  const box = svg.getBoundingClientRect();
  if (box.width <= 0) return;
  const W = 1000, PAD = Number(svg.dataset.pad) || 4;
  const duration = Number(svg.dataset.duration);
  const vx = ((e.clientX - box.left) / box.width) * W;
  const seconds = ((vx - PAD) / (W - 2 * PAD)) * duration;
  const clamped = Math.max(0, Math.min(duration - 0.05, seconds));
  setPlanOverride(svg.dataset.role === "out"
    ? {outPoint: Number(clamped.toFixed(2))}
    : {inPoint: Number(clamped.toFixed(2))});
}

function paintTimelines() {
  const r = REPORT;
  const block = (t, role, label) => `
    <div class="tl">
      <h4>${label} ${t.name}
        <span>${mmss(t.duration)} · ${fmt(t.bpm, 1)} BPM (${fmt(t.bpmConfidence)})
          · ${t.key || "无调"} (${fmt(t.keyConfidence)})
          · intro ${mmss(t.introEnd)}
          · outro ${t.outroFadeStart != null ? mmss(t.outroFadeStart) : "无"}
          · 分段 ${t.sections && t.sections.length
            ? t.sections.length + " 段（" + fmt(t.structureConfidence) + "）"
            : "无（" + fmt(t.structureConfidence) + "）"}</span></h4>
      ${sectionBand(t)}
      ${timeline(t, role, r)}
    </div>`;
  $("#timelines").innerHTML = block(r.outgoing, "out", "出 ") + block(r.incoming, "in", "入 ");
  $("#timelines").onclick = timelineClick;
}

// ---------------------------------------------------------------- envelope
//
// The four lanes, drawn the same way the timelines are: one squashed viewBox,
// labels in HTML underneath so type never stretches. Read-only on purpose —
// curves are written by the exchange template or pasted from an AI, and a
// drag-editor here would be a fourth way to say the same thing.

const LANE_COLOR = {
  outVocal: "var(--key)", outBed: "var(--accent)",
  inVocal: "var(--good)", inBed: "var(--warn)",
};
/// Anything under this is inaudible under any bed; plotting all the way to
/// −60 dB would spend half the panel on the difference between silent and
/// silent.
const ENV_FLOOR_DB = -48;

function paintEnvelope() {
  const env = REPORT && REPORT.stemEnvelope;
  const wrap = $("#envWrap");
  if (!env || !env.overlap) { wrap.style.display = "none"; return; }
  wrap.style.display = "";

  const W = 1000, H = 190, PADX = 6, TOP = 10, BASE = H - 22;
  const x = s => PADX + (s / env.overlap) * (W - 2 * PADX);
  const y = db => TOP + (Math.max(env.maxGainDB, 0) - Math.max(db, ENV_FLOOR_DB))
    / (Math.max(env.maxGainDB, 0) - ENV_FLOOR_DB) * (BASE - TOP);

  let g = "";
  for (const db of [6, 0, -12, -24, -36, -48]) {
    if (db > env.maxGainDB) continue;
    g += `<line x1="${PADX}" y1="${y(db).toFixed(1)}" x2="${W - PADX}" y2="${y(db).toFixed(1)}"
           stroke="var(--fg)" opacity="${db === 0 ? ".38" : ".13"}"
           stroke-dasharray="${db === 0 ? "" : "4 5"}"/>`;
    g += `<text x="${PADX + 3}" y="${(y(db) - 3).toFixed(1)}" font-size="11"
           fill="var(--dim)">${db} dB</text>`;
  }
  // The instant the vocal changes hands, when this envelope came from the
  // exchange template — the one number the curves are all built around.
  const ex = REPORT.stemExchange;
  if (ex && ex.fallbackReason == null) {
    g += `<line x1="${x(ex.handover).toFixed(1)}" y1="${TOP - 6}"
           x2="${x(ex.handover).toFixed(1)}" y2="${BASE}"
           stroke="var(--good)" stroke-width="2" opacity=".8"/>`;
  }
  for (const lane of env.lanes) {
    if (!lane.points.length) continue;
    // An empty lane is 0 dB pass-through; a one-point lane is a flat hold.
    let d = "";
    lane.points.forEach((p, i) => {
      d += `${i ? "L" : "M"} ${x(p[0]).toFixed(1)} ${y(p[1]).toFixed(1)} `;
    });
    g += `<path d="${d}" fill="none" stroke="${LANE_COLOR[lane.key]}"
           stroke-width="2.2" stroke-linejoin="round" opacity=".95"/>`;
    g += lane.points.map(p =>
      `<circle cx="${x(p[0]).toFixed(1)}" cy="${y(p[1]).toFixed(1)}" r="3"
        fill="${LANE_COLOR[lane.key]}"/>`).join("");
  }
  for (let s = 0; s <= env.overlap + 1e-6; s += 2) {
    g += `<line x1="${x(s).toFixed(1)}" y1="${BASE}" x2="${x(s).toFixed(1)}" y2="${BASE + 6}"
           stroke="var(--dim)"/>`;
  }
  $("#envPlot").innerHTML =
    `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="height:190px">${g}</svg>`;

  const zero = env.lanes.filter(l => !l.points.length).map(l => l.label);
  $("#envNote").innerHTML =
    `横轴是叠加内部的 ${fmt(env.overlap)} 秒，纵轴是这条轨相对<b>原混音</b>的增益。`
    + `这四条曲线作用在分离出来的 stem 上，`
    + `叠加在推子/EQ 自动化<b>之上</b>——所以 0 dB 不是“不动”，是“交叉淡出原本要做的事，照做”。`
    + (ex && ex.fallbackReason == null
       ? `<br>交接落在第 <b>${fmt(ex.handover)}</b> 秒（出曲 ${mmss(ex.handoverAbsolute)}），`
         + (ex.source === "lyric"
            ? `依据是出曲歌词「${ex.lyricLine || ""}」唱完的位置。`
            : "出曲这段没有可用的歌词行末，改用人声活跃度的低谷。")
         + (ex.clampedFrom != null
            ? `（原本算到 ${fmt(ex.clampedFrom)} 秒，被夹回允许窗口内。）` : "")
       : "")
    + (ex && ex.fallbackReason
       ? `<br><span class="err">vocal exchange 没能编排出来：${ex.fallbackReason}</span>` : "")
    + (zero.length ? `<br>直通（0 dB，不分离这一侧）：${zero.join("、")}` : "");
  $("#envLegend").innerHTML = env.lanes
    .map(l => `<span><i style="background:${LANE_COLOR[l.key]}"></i>${l.label}</span>`).join("");
  $("#envHandRow").style.display = STEM_ENV ? "" : "none";
}

const ENV_LANES = ["outVocal", "outBed", "inVocal", "inBed"];

/// The same rules `StemEnvelope.validate` and `Audition.StemEnvelopeInput`
/// enforce, mirrored here so the AI preview never promises something the
/// server will refuse.
function stemEnvelopeError(env, overlap) {
  if (typeof env !== "object" || env === null || Array.isArray(env)) {
    return "stemEnvelope 不是一个对象";
  }
  for (const [key, rows] of Object.entries(env)) {
    if (rows === null) continue;
    if (!ENV_LANES.includes(key)) {
      return `stemEnvelope 里没有 ${key} 这条轨（只有 ${ENV_LANES.join(" / ")}）`;
    }
    if (!Array.isArray(rows)) return `stemEnvelope.${key} 要是一个数组，每项是 [秒, dB]`;
    if (rows.length > 16) {
      return `stemEnvelope.${key} 有 ${rows.length} 个点，超过 16 个的上限`;
    }
    let previous = null;
    for (const row of rows) {
      if (!Array.isArray(row) || row.length !== 2) {
        return `stemEnvelope.${key} 的每一项都要写成 [秒, dB] 两个数字`;
      }
      const t = Number(row[0]), db = Number(row[1]);
      if (!isFinite(t) || !isFinite(db)) return `stemEnvelope.${key} 里有不是数字的取值`;
      if (t < -1e-6 || t > overlap + 1e-6) {
        return `stemEnvelope.${key} 的时间 ${t} 不在 0–${overlap.toFixed(2)} 秒之内`;
      }
      if (db < -60 - 1e-4 || db > 6 + 1e-4) {
        return `stemEnvelope.${key} 的增益 ${db} dB 超出 −60…+6 的范围`;
      }
      if (previous !== null && t < previous - 1e-6) {
        return `stemEnvelope.${key} 的时间必须递增：${previous} 之后又出现了 ${t}`;
      }
      previous = t;
    }
  }
  return null;
}

// ---------------------------------------------------------------- signals

function paintSignals() {
  $("#signals").innerHTML = REPORT.signals.map(s => {
    const pct = v => Math.max(0, Math.min(100, (v / s.axisMax) * 100));
    const marks = s.marks.map(m =>
      `<span class="mark" style="left:${pct(m.value)}%"><b>${m.label} ${fmt(m.value, 2)}</b></span>`)
      .join("");
    const dot = s.value === null || s.value === undefined ? ""
      : `<span class="dot" style="left:${pct(s.value)}%"></span>`;
    const fill = s.value === null || s.value === undefined ? ""
      : `<span class="fill ${s.state}" style="width:${pct(s.value)}%"></span>`;
    return `<div class="sig">
      <div class="sighead"><span>${s.label}</span>
        <b class="chip ${s.state}">${s.display}</b></div>
      <div class="meter">${fill}${marks}${dot}</div>
      <div class="sigsay">${s.verdict}</div>
    </div>`;
  }).join("");
}

function paintChain() {
  $("#chain").innerHTML = REPORT.chain.map(c => `
    <li class="${c.fired ? "fired" : ""}">
      <div class="t">${c.title}</div>
      <div class="r">${c.rule}</div>
      <div class="d">${c.detail}</div>
      <div class="o">${c.outcome}</div>
    </li>`).join("");
}

// ---------------------------------------------------------------- render

// A whole-mix render takes ~0.3s, a first stem render ~20s (人声分离). Both go
// through the same job + poll path so the page never sits on a dead socket.
const STAGE_TEXT = {planning: "读取决策…", separating: "分离人声…", rendering: "渲染中…"};

function sgn(v) { return (v >= 0 ? "+" : "") + fmt(v); }

function describeRender(r) {
  const bits = [];
  bits.push(r.cached ? "复用已渲染的这一版"
    : `${fmt(r.duration)}s 音频 · ${fmt(r.realtimeFactor, 1)}× 实时`);
  bits.push(`交接在 ${fmt(r.overlapStart)}s`);
  if (r.style) bits.push(`手法 ${r.style}`);
  // Playback trims are the product's own compensation; the normalization on
  // top is only so two renders can be A/B'd without a loudness bias.
  if (r.outgoingTrimDB || r.incomingTrimDB) {
    bits.push(`播放增益 出 ${sgn(r.outgoingTrimDB)} / 入 ${sgn(r.incomingTrimDB)} dB`);
  }
  // The transition gain ride: held across the overlap, then let go of slowly.
  // Both halves are in the rendered file, so this is audible, not just a number.
  if (r.rideDB) {
    bits.push(`交接补偿 入 ${sgn(r.rideDB)} dB`
      + `（叠加期间全额，之后 ${fmt(r.rideReleaseSeconds, 1)}s 推回原位）`);
  }
  if (r.normalizationTargetLUFS !== undefined) {
    bits.push(`盲听归一 ${fmt(r.measuredLUFS, 1)} → ${fmt(r.normalizationTargetLUFS, 1)} LUFS`
      + `（${sgn(r.normalizationGainDB)} dB，只影响这个文件的响度，不影响过渡本身）`);
  }
  if (r.stemTechnique) {
    const sides = (r.stemSeparatedSides || []).join("+") || "出曲";
    const inc = r.stemIncomingSeparatedSeconds != null
      ? ` + 入曲 ${fmt(r.stemIncomingSeparatedSeconds, 1)}s` : "";
    bits.push(`stem ${r.stemTechnique} · 分离 ${sides}：`
      + `${fmt(r.stemSeparatedSeconds, 1)}s${inc}，用时`
      + ` ${fmt(r.stemSeconds)}s${r.stemCacheHit ? "（缓存命中）" : ""}`);
  }
  let html = bits.join(" · ");
  if (r.stemFallbackReason) {
    html += ` <span class="err">· stem 未生效，已降级为整混渲染：${r.stemFallbackReason}</span>`;
  }
  return html;
}

$("#renderBtn").onclick = async () => {
  const btn = $("#renderBtn");
  btn.disabled = true;
  const t0 = performance.now();
  const tick = (stage, elapsed) =>
    $("#renderInfo").innerHTML = `<span class="spin"></span> ${STAGE_TEXT[stage] || stage}`
      + ` ${elapsed.toFixed(0)}s`;
  tick("planning", 0);
  try {
    const started = await api("/api/render", requestBody());
    let r = null;
    for (;;) {
      const s = await api("/api/render-status/" + encodeURIComponent(started.job));
      if (s.status === "done") { r = s; break; }
      if (s.status === "failed") throw new Error(s.error);
      tick(s.stage, s.elapsed ?? (performance.now() - t0) / 1000);
      await new Promise(res => setTimeout(res, 400));
    }
    LAST_RENDER = r;
    $("#audio").src = r.url + "?t=" + Date.now();
    $("#audio").load();
    $("#renderInfo").innerHTML = describeRender(r);
  } catch (e) {
    $("#renderInfo").innerHTML = `<span class="err">${e.message}</span>`;
  }
  btn.disabled = false;
};

$("#toOverlap").onclick = () => {
  if (!LAST_RENDER) return;
  const a = $("#audio");
  a.currentTime = Math.max(0, LAST_RENDER.overlapStart - 3);
  a.play();
};

// ---------------------------------------------------------------- batch

$("#batchBtn").onclick = async () => {
  const btn = $("#batchBtn");
  btn.disabled = true;
  $("#batchInfo").innerHTML = '<span class="spin"></span> 计算中…';
  try {
    const r = await api("/api/batch", requestBody());
    BATCH = r;
    const changed = r.pairs.filter(p => p.changed).length;
    $("#batchInfo").textContent = changed
      ? `一共 ${r.pairs.length} 对，其中 ${changed} 对的结论被你的改动挪动了（高亮那几行）。`
      : `一共 ${r.pairs.length} 对，结论和出厂设置完全一致。`;
    const cell = (p, key, digits) => {
      const now = p[key], was = p.standard ? p.standard[key] : undefined;
      const show = digits === undefined ? (now ?? "—") : fmt(now, digits);
      if (was === undefined || was === null) return `<td>${show}</td>`;
      const same = digits === undefined ? was === now : Math.abs(was - now) < 0.005;
      const wasShow = digits === undefined ? was : fmt(was, digits);
      return same ? `<td>${show}</td>`
        : `<td><b>${show}</b> <span class="was">← ${wasShow}</span></td>`;
    };
    $("#batchTable").innerHTML =
      `<tr><th>出 → 入</th><th>搭不搭</th><th>怎么接</th><th>出曲怎么离场</th><th>stem 手法</th>
        <th>叠多久 s</th><th>音量差 dB</th><th>音色差</th><th>出曲交接点</th></tr>` +
      r.pairs.map(p => `<tr class="${p.changed ? "changed" : ""}">
        <td title="${p.outgoing} → ${p.incoming}">${p.outgoing.slice(0, 10)} → ${p.incoming.slice(0, 10)}</td>
        ${cell(p, "tier")}${cell(p, "plan")}${cell(p, "style")}${cell(p, "stem")}
        ${cell(p, "overlap", 2)}
        <td>${fmt(p.loudness)}</td><td>${fmt(p.timbre, 3)}</td><td>${mmss(p.outPoint)}</td>
      </tr>`).join("");
  } catch (e) {
    $("#batchInfo").innerHTML = `<span class="err">${e.message}</span>`;
  }
  btn.disabled = false;
};

// ------------------------------------------------------------------- AI 回路
//
// The console knows everything an outside model would need — what each of the
// 36 knobs means and where it sits, what the five signals said, how the
// decision was derived — but only as pixels. These two buttons turn that into
// text a chat window can read, and read a reply back in. No network call
// leaves this page: the user carries the text across by hand, which is also
// why the reply has to be parsed leniently.

function aiSystemPrompt() {
  const lines = [];
  lines.push("你是一位 DJ 自动过渡（AutoMix）的调参专家。我会给你一套过渡决策系统的完整状态，");
  lines.push("请你像调音师那样判断参数该怎么改，并按我指定的格式回复。");
  lines.push("");
  lines.push("## 这个系统怎么决策");
  lines.push("对每一对相邻的歌，系统先算五项信号，据此定一个“档位”，再决定用什么手法交接：");
  lines.push("1. 音量差（dB）：出曲结尾和入曲开头各取一段的平均响度之差。越大越不适合长叠。");
  lines.push("2. 音色差距（0–1 的余弦距离）：两首歌整体频谱形状的差别。同一首歌自比约 0.03。");
  lines.push("3. 速度差（比例）：两边 BPM 按倍速关系折算后的相对差。够小才谈得上对拍。");
  lines.push("4. 调性远近（五度圈步数 0–6）：只会把“很搭”降一级，从不单独判定“差异很大”。");
  lines.push("5. 人声密度（倍数）：交接窗口内的人声活跃度相对各自整首歌均值。两边都高 = 两个主唱打架。");
  lines.push("");
  lines.push("档位三档：compatible（很搭，可长叠、可对拍）、neutral（一般般，只给短交接）、");
  lines.push("clash（差异很大，只给最短的礼貌淡出）。");
  lines.push("出曲的离场手法有三种：fade（普通淡出）、filterSweep（滤波掏空）、echoOut（拍点上停住留回声），");
  lines.push("外加 stagedEQ（高中低三段分批交接）。另有一组需要人声分离的 stem 手法（见下文上下文）。");
  lines.push("");
  lines.push("## 可调参数（共 " + BOOT.fields.length + " 个）");
  lines.push("格式：名称 | 分组 | 当前值 | 出厂值 | 允许范围 | 含义");
  for (const f of BOOT.fields) {
    lines.push(`${f.name} | ${f.group} | ${Number(CONFIG[f.name]).toFixed(f.digits)}`
      + ` | ${Number(f.standard).toFixed(f.digits)}`
      + ` | ${Number(f.min).toFixed(f.digits)}–${Number(f.max).toFixed(f.digits)}`
      + ` | ${f.blurb}`);
  }
  lines.push("");
  lines.push("超出范围的取值会被系统自动收进范围内；不认识的参数名会被忽略。");
  lines.push("");
  lines.push("## 你还能直接指挥这一次过渡（planOverride）");
  lines.push("上面 35 个参数是**全局**的：改一个，语料里每一对歌的结论都会跟着变。");
  lines.push("所以「这一对该从哪儿切」不该靠拧全局阈值去凑。你可以直接给这一对写死交接几何：");
  lines.push("- outPoint：出曲从第几秒开始交接");
  lines.push("- inPoint：入曲从第几秒进来（想从纯伴奏前奏更早进入，就把它调小）");
  lines.push("- overlap：两首歌叠多久（秒）");
  lines.push("三项都可省略，省略的沿用规划器算出来的值；单位是秒，也接受 \"3:19.5\" 这种写法。");
  lines.push("硬约束：出点/入点必须落在各自曲长以内，出点之后和入点之后都要装得下整段叠加，"
    + `叠加长度在 ${BOOT.minManualOverlap ?? 0.5}–${BOOT.maxManualOverlap ?? 40} 秒之间。`
    + "越界会被拒绝并给出原因。");
  lines.push("接法（对拍 / 交叉淡入淡出）不变：只有几何被改写。"
    + "对拍那一档会按原来的节拍周期重新折算小节数。");
  lines.push("");
  lines.push("## 你还能编排这一次交接的四条增益曲线（stemEnvelope）");
  lines.push("人声分离可用时，叠加期间有四条独立的通道：出曲人声、出曲伴奏、入曲人声、入曲伴奏。"
    + "stemEnvelope 让你给每条通道各写一串折点，控制它们在叠加内部的增益走向：");
  lines.push('- 写成 {"outVocal": [[秒, dB], ...], "outBed": ..., "inVocal": ..., "inBed": ...}');
  lines.push("- 秒是**从叠加开始算**的相对时间（0 = 两首歌刚开始重叠），必须递增，"
    + `且落在 0–${fmt(REPORT ? REPORT.plan.overlapDuration : 0)} 秒（这次叠加的长度）之内。`);
  lines.push("- dB 范围 −60 到 +6；折点之间按 dB 线性插值，首尾之外保持端点值。");
  lines.push("- 每条通道最多 16 个点；省略某条通道 = 那条直通（0 dB）。"
    + "一侧的两条都省略，那一侧根本不会被分离，能省掉约 15 秒的模型推理。");
  lines.push("- **重要**：这些增益作用在分离出来的 stem 上，并且叠加在推子/EQ 自动化**之上**。"
    + "所以 0 dB 不是“音量恒定”，而是“交叉淡出原本要做的事照做”。"
    + "想让出曲人声在淡出期间保持同样的响度，得自己把推子的倒数写进去（最多 +6 dB）。");
  lines.push("典型形态：入曲伴奏先进铺底 → 出曲伴奏早退 → 出曲人声把这一句唱完 → 入曲人声接手。"
    + "任何时刻只有一个人声在前面，伴奏床始终连续。");
  lines.push("**想要标准的人声交接，直接写 \"stem\": \"exchange\" 就够了**："
    + "系统会读出曲的 .lrc 歌词，把交接点放在离叠加中点最近的那一句唱完的位置，"
    + "自动补偿推子，并在没有歌词时退回 vocal duck。"
    + "只有当你想精细控制某条通道的形状时，才自己写 stemEnvelope。");
  lines.push("\"stem\" 和 \"stemEnvelope\" 只能给一个，同时给会被拒绝。");
  lines.push("");
  lines.push("下面的上下文里有两首歌的逐 2 秒 rms/人声曲线、小节第一拍、乐句起点和带时间戳的歌词，"
    + "足够你自己挑一个切点——比如让出曲人声收完最后一句、入曲从伴奏段先铺底。");
  lines.push("如果你判断问题出在**选点逻辑**（规划器总把入点锁死在某处、不肯从更早的纯伴奏进入）"
    + "而不是某个参数值，请直接写进 rationale，别硬凑参数。");
  return lines.join("\n");
}

// The page draws two timelines; text has to carry the same information, or the
// AI is being asked to place a seam it cannot see. Only the windows that
// matter go in — the outgoing tail and the incoming head — sampled every 2 s,
// which keeps the whole block a couple of kilobytes.

const TL_OUT_TAIL = 90, TL_IN_HEAD = 60, TL_STEP = 2;

function tlWindow(t, role) {
  const from = role === "out" ? Math.max(0, t.duration - TL_OUT_TAIL) : 0;
  const to = role === "out" ? t.duration : Math.min(t.duration, TL_IN_HEAD);
  return [from, to];
}

/// The 1 s grids sampled onto a 2 s one, as `t=182s rms=0.62 voc=0.41`.
function tlRows(t, from, to) {
  const at = (grid, s) => {
    const i = Math.round(s);
    return (i >= 0 && i < grid.length) ? grid[i] : null;
  };
  const rows = [];
  for (let s = Math.ceil(from); s <= to; s += TL_STEP) {
    const rms = at(t.rms, s), voc = at(t.vocal, s);
    if (rms === null && voc === null) continue;
    rows.push(`t=${Math.round(s)}s rms=${fmt(rms)} voc=${fmt(voc)}`);
  }
  return rows;
}

function aiTimelines() {
  const r = REPORT;
  const lines = [];
  lines.push("## 时间轴（逐 2 秒）");
  lines.push("rms 已按各首歌自己的峰值归一化到 0–1；voc 是 0–1 的人声活跃度"
    + "（上面「人声密度」那项信号是它相对全曲均值的倍数）。"
    + `出曲只给结尾 ${TL_OUT_TAIL} 秒，入曲只给开头 ${TL_IN_HEAD} 秒——`
    + "交接只发生在这两段里。");
  for (const [role, label, t] of [["out", "出曲", r.outgoing], ["in", "入曲", r.incoming]]) {
    const [from, to] = tlWindow(t, role);
    const mean = t.vocal.length
      ? t.vocal.reduce((a, b) => a + b, 0) / t.vocal.length : 0;
    lines.push("");
    lines.push(`### ${label} ${t.name}　${mmss(from)}–${mmss(to)}`
      + `（全曲 voc 均值 ${fmt(mean)}）`);
    lines.push(tlRows(t, from, to).join("\n"));
    const beats = (t.downbeats || []).filter(d => d >= from && d <= to);
    // Every fourth downbeat is one every four bars — enough to see where the
    // grid sits without pasting three hundred numbers.
    const shown = beats.filter((_, i) => i % 4 === 0).slice(0, 24);
    lines.push(`小节第一拍（每 4 个取 1）：${
      shown.length ? shown.map(d => fmt(d, 2)).join(" ") : "（这段里没有）"}`);
    const phrases = (t.phraseBoundaries || []).filter(p => p >= from && p <= to)
      .sort((a, b) => a - b).slice(0, 20);
    lines.push(`乐句起点（规划器认可的候选交接点）：${
      phrases.length ? phrases.map(p => `${mmss(p)}(${fmt(p)})`).join("　") : "（这段里没有）"}`);
  }
  return lines.join("\n");
}

/// The structure table. Paired with the lyrics block below it, this is what
/// lets an outside reader check a label — "副歌 at 2:41" against the line that
/// repeats there — instead of taking the segmenter's word for it.
function aiSections() {
  const r = REPORT;
  const lines = ["## 段落划分（分析器给的,规划器还没用它选点）"];
  lines.push("energy 是段均 RMS / 全曲峰值,vocal 是段均人声活跃度 / 全曲均值"
    + "（1 = 与全曲平均一样密）,repeat 是同类段落出现的次数。"
    + "置信度低于门槛时整份丢空——那不是失败,是分析器拒绝猜。"
    + "标签可以怀疑:歌词块的重复位置才是判它对不对的依据。");
  for (const [label, t] of [["出曲", r.outgoing], ["入曲", r.incoming]]) {
    lines.push("");
    lines.push(`### ${label} ${t.name}（置信度 ${fmt(t.structureConfidence)}）`);
    if (!t.sections || !t.sections.length) {
      lines.push("（没有可信的段落划分）");
      continue;
    }
    for (const s of t.sections) {
      const st = SECTION_STYLE[s.kind] || {label: s.kind};
      const name = st.label === s.kind ? s.kind : `${st.label}(${s.kind})`;
      lines.push(`  ${mmss(s.start)}–${mmss(s.end)}  ${name}`
        + `  repeat=${s.repetition} energy=${fmt(s.energy)} vocal=${fmt(s.vocalDensity)}`);
    }
  }
  return lines.join("\n");
}

/// Timed lyrics from the corpus `.lrc` sidecars, so "let the outgoing singer
/// finish the line" is a decision the AI can actually make.
function aiLyrics() {
  const r = REPORT;
  const lines = ["## 歌词（带时间戳）"];
  const block = (label, t, side, which) => {
    if (!side) {
      lines.push(`${label} ${t.name}：无歌词（语料里没有同名 .lrc）`);
      return;
    }
    const rows = side[which] || [];
    lines.push(`${label} ${t.name}（共 ${side.count} 行，这里是${
      which === "tail" ? "最后" : "开头"} ${rows.length} 行）：`);
    for (const l of rows) lines.push(`  [${mmss(l.t)}] ${l.text}`);
  };
  const ly = r.lyrics || {};
  block("出曲", r.outgoing, ly.outgoing, "tail");
  lines.push("");
  block("入曲", r.incoming, ly.incoming, "head");
  return lines.join("\n");
}

function aiContext() {
  const r = REPORT;
  const lines = [];
  if (!r) return "（当前没有可用的决策，先在页面上选一对歌。）";
  lines.push("## 当前这一对");
  for (const [role, t] of [["出曲", r.outgoing], ["入曲", r.incoming]]) {
    lines.push(`${role}：${t.name} · 时长 ${mmss(t.duration)} · ${fmt(t.bpm, 1)} BPM`
      + `（把握 ${fmt(t.bpmConfidence)}）· 调 ${t.key || "听不出"}（把握 ${fmt(t.keyConfidence)}）`
      + ` · intro 到 ${mmss(t.introEnd)}`
      + ` · ${t.outroFadeStart != null ? "自带淡出，从 " + mmss(t.outroFadeStart) + " 起" : "结尾没有自带淡出"}`);
  }
  lines.push("");
  lines.push(aiTimelines());
  lines.push("");
  lines.push(aiSections());
  lines.push("");
  lines.push(aiLyrics());
  lines.push("");
  lines.push("## 五项信号");
  for (const s of r.signals) {
    const marks = s.marks.map(m => `${m.label} ${fmt(m.value, 3)}(${m.field})`).join("，");
    lines.push(`- ${s.label}：${s.display}　[门槛：${marks}]　判定 ${s.state}`);
    lines.push(`  ${s.verdict}`);
  }
  lines.push("");
  lines.push("## 判断过程");
  r.chain.forEach((c, i) => {
    lines.push(`${i + 1}. ${c.title}${c.fired ? "（这一步改变了结果）" : ""}`);
    lines.push(`   规则：${c.rule}`);
    lines.push(`   数据：${c.detail}`);
    lines.push(`   结果：${c.outcome}`);
  });
  lines.push("");
  lines.push("## 人声分离");
  lines.push(r.stemsReady
    ? `这次告诉规划器人声分离可用，它${r.plannedStemTechnique
        ? "自己选了 " + r.plannedStemTechnique : "没有选任何 stem 手法"}。`
    : "这次没有告诉规划器人声分离可用，stem 那一组参数完全没参与判断。");
  const ex = r.stemExchange;
  if (ex) {
    lines.push(ex.fallbackReason
      ? `vocal exchange 没能编排出来，已降级为 vocal duck：${ex.fallbackReason}`
      : `vocal exchange 的交接句落在叠加的第 ${fmt(ex.handover)} 秒`
        + `（出曲 ${mmss(ex.handoverAbsolute)}），依据是 ${ex.source === "lyric"
            ? `歌词「${ex.lyricLine || ""}」唱完` : "人声活跃度的低谷"}。`);
  }
  if (r.stemEnvelope) {
    lines.push("当前这次交接的四条增益曲线（秒是叠加内部的相对时间，dB 相对原混音）：");
    for (const lane of r.stemEnvelope.lanes) {
      lines.push(`  ${lane.key}（${lane.label}）：` + (lane.points.length
        ? lane.points.map(p => `[${fmt(p[0], 2)}, ${fmt(p[1], 1)}]`).join(" ")
        : "直通（0 dB，这一侧不分离）"));
    }
  }
  lines.push("");
  lines.push("## 当前结论");
  lines.push(`档位 ${r.tier}（${tierText(r.tier)}）${r.demotedByKey ? "，被和声降过一级" : ""}`
    + ` · 接法 ${r.plan.kind} · 出曲离场手法 ${r.style.description}`
    + ` · 叠加 ${fmt(r.plan.overlapDuration)} 秒`
    + (r.plan.overlapBars ? `（${r.plan.overlapBars} 小节）` : "")
    + ` · 出点 ${mmss(r.plan.outPoint)} · 入点 ${mmss(r.plan.inPoint)}`);
  if (r.nearMisses.length) lines.push("卡在门槛边上的：" + r.nearMisses.join("；"));
  lines.push("");
  lines.push("## 参数相对出厂设置的改动");
  const diff = BOOT.fields.filter(f => Math.abs(CONFIG[f.name] - f.standard) > 1e-12);
  lines.push(diff.length
    ? diff.map(f => `${f.name}: ${Number(f.standard).toFixed(f.digits)}`
        + ` → ${Number(CONFIG[f.name]).toFixed(f.digits)}`).join("\n")
    : "（没有改动，就是出厂设置）");
  lines.push("");
  lines.push("## 全语料分布");
  if (BATCH) {
    const tally = key => {
      const m = {};
      for (const p of BATCH.pairs) m[p[key]] = (m[p[key]] || 0) + 1;
      return Object.entries(m).sort((a, b) => b[1] - a[1])
        .map(([k, v]) => `${k} × ${v}`).join("，");
    };
    lines.push(`共 ${BATCH.pairs.length} 对相邻歌曲。`);
    lines.push(`档位分布：${tally("tier")}`);
    lines.push(`接法分布：${tally("plan")}`);
    lines.push(`离场手法分布：${tally("style")}`);
    const changed = BATCH.pairs.filter(p => p.changed);
    lines.push(changed.length
      ? `与出厂设置结论不同的 ${changed.length} 对：`
        + changed.map(p => `${p.outgoing} → ${p.incoming}`).join("；")
      : "与出厂设置的结论完全一致。");
  } else {
    lines.push("（还没跑过批量视图，没有分布数据。）");
  }
  return lines.join("\n");
}

const AI_OUTPUT_SPEC = `## 请这样回复

先用几句话说你的判断，然后给出**一个** fenced JSON 代码块，格式如下：

\`\`\`json
{
  "planOverride": {"outPoint": 199.5, "inPoint": 2.0, "overlap": 12.0},
  "config": {"参数名": 新值, "另一个参数名": 新值},
  "styleOverride": "auto | plain | sweep | echo | staged",
  "stem": "none | acapella | instrumental | duck | exchange",
  "stemEnvelope": {"outVocal": [[0, 0], [9, 0], [9.8, -60]],
                   "outBed":   [[0, 0], [3.6, -9], [9, -30], [12, -40]],
                   "inVocal":  [[0, -40], [8.4, -40], [9, -30], [10, 0]],
                   "inBed":    [[0, -6], [7.2, 0], [12, 0]]},
  "rationale": "为什么这么改，一两句话"
}
\`\`\`

约束：
- 每个字段都可以省略；省略就表示保持现状。
- "stem" 和 "stemEnvelope" 只能给一个。想要标准的人声交接就写 "stem": "exchange"，
  想精细控制四条通道才写 "stemEnvelope"（秒是叠加内部的相对时间，dB 在 −60…+6）。
- "planOverride" 只作用于当前这一对歌：里面 outPoint / inPoint / overlap 三项也各自可省。
  单位是秒（也接受 "3:19.5"）。想编排一次具体的过渡（比如让出曲人声收完最后一句、
  入曲先从伴奏铺底），用它，而不是去拧全局参数。
- "config" 里只放你真的想改的参数，用上面表格里的准确名称，值必须是数字；
  它会影响整个语料，所以只在你确实想改**规则**时才用。
- "rationale" 用中文，说清楚你想让听感往哪个方向走；
  如果你认为该改的是选点逻辑而不是参数，也写在这里。
- 只给一个 JSON 块，不要给多个候选方案。`;

function aiBundle() {
  return [aiSystemPrompt(), "", "=".repeat(60), "", aiContext(), "", "=".repeat(60), "",
          AI_OUTPUT_SPEC].join("\n");
}

/// The console is served over plain HTTP on a LAN address, so
/// `navigator.clipboard` is usually unavailable (it needs a secure context).
/// Fall back to the old selection + execCommand path, and if even that is
/// refused, hand the user a pre-selected textarea to copy by hand.
async function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) {
    try { await navigator.clipboard.writeText(text); return "clipboard"; } catch (e) { /* fall through */ }
  }
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.cssText = "position:fixed;top:0;left:0;width:1px;height:1px;opacity:0";
  document.body.appendChild(ta);
  ta.select();
  ta.setSelectionRange(0, text.length);
  let ok = false;
  try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
  document.body.removeChild(ta);
  return ok ? "execCommand" : "manual";
}

$("#copyAI").onclick = async () => {
  const text = aiBundle();
  const how = await copyText(text);
  const box = $("#copyFallback");
  if (how === "manual") {
    box.style.display = "";
    box.value = text;
    box.focus();
    box.select();
    $("#copyInfo").innerHTML =
      '<span class="err">浏览器不让脚本写剪贴板（非 HTTPS 页面）。文本已全选，按 ⌘C 复制。</span>';
  } else {
    box.style.display = "none";
    $("#copyInfo").textContent =
      `已复制 ${text.length} 个字符（含 system prompt、当前上下文、回复格式三段）。`;
  }
};

/// Pull the first JSON object out of whatever the model wrote. Fenced block
/// first, then the first balanced `{…}` anywhere in the text — models put
/// prose on both sides of it more often than not.
function extractJSON(raw) {
  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidates = [];
  if (fenced) candidates.push(fenced[1]);
  const start = raw.indexOf("{");
  if (start >= 0) {
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < raw.length; i++) {
      const ch = raw[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}" && --depth === 0) { candidates.push(raw.slice(start, i + 1)); break; }
    }
  }
  for (const c of candidates) {
    try {
      const v = JSON.parse(c);
      if (v && typeof v === "object" && !Array.isArray(v)) return v;
    } catch (e) { /* try the next candidate */ }
  }
  return null;
}

let PENDING_AI = null;

$("#parseAI").onclick = () => {
  const raw = $("#aiPaste").value.trim();
  const preview = $("#aiPreview");
  $("#applyAI").style.display = $("#cancelAI").style.display = "none";
  PENDING_AI = null;
  if (!raw) { preview.innerHTML = '<span class="err">先把 AI 的回复粘进上面的框里。</span>'; return; }

  const parsed = extractJSON(raw);
  if (!parsed) {
    preview.innerHTML = '<span class="err">在这段文字里没找到能解析的 JSON。'
      + '让 AI 用 ```json 代码块把结果包起来再试一次。</span>';
    return;
  }
  const cfg = parsed.config;
  if (cfg !== undefined && (typeof cfg !== "object" || cfg === null || Array.isArray(cfg))) {
    preview.innerHTML = '<span class="err">JSON 里的 "config" 不是一个对象。</span>';
    return;
  }

  const accepted = {}, rows = [], ignored = [], bad = [];
  for (const [name, value] of Object.entries(cfg || {})) {
    const f = BOOT.fields.find(x => x.name === name);
    if (!f) { ignored.push(name); continue; }
    const n = typeof value === "number" ? value : parseFloat(value);
    if (!isFinite(n)) { bad.push(`${name}=${JSON.stringify(value)}`); continue; }
    // Same clamp the server applies to every override, applied here too so
    // the preview shows the value that will actually take effect.
    const clamped = Math.min(Math.max(n, f.min), f.max);
    if (Math.abs(clamped - CONFIG[name]) < 1e-12) continue;
    accepted[name] = clamped;
    rows.push(`<code>${name}</code> ${Number(CONFIG[name]).toFixed(f.digits)}`
      + ` → <b>${clamped.toFixed(f.digits)}</b>`
      + (Math.abs(clamped - n) > 1e-9
         ? ` <span class="err">（原本给的是 ${n}，超出 ${f.min}–${f.max}，已收进范围）</span>` : ""));
  }

  let style = null;
  if (typeof parsed.styleOverride === "string") {
    const s = parsed.styleOverride.trim();
    if (s === "auto" || BOOT.styles.includes(s)) style = s;
    else bad.push(`styleOverride=${JSON.stringify(parsed.styleOverride)}`);
  }
  let stem = null;
  if (typeof parsed.stem === "string") {
    const s = parsed.stem.trim();
    if (s === "none" || (BOOT.stems || []).includes(s)) stem = s;
    else bad.push(`stem=${JSON.stringify(parsed.stem)}`);
  }

  // stemEnvelope — the four-lane orchestration. Mutually exclusive with
  // "stem": one picks a ready-made technique, the other writes the curves.
  let stemEnv = null;
  const se = parsed.stemEnvelope;
  if (se !== undefined && se !== null) {
    if (stem && stem !== "none") {
      bad.push('"stem" 和 "stemEnvelope" 只能给一个：'
        + '想要标准的人声交接就写 "stem": "exchange"，想精细控制才写 "stemEnvelope"');
    } else {
      const err = stemEnvelopeError(se, REPORT.plan.overlapDuration);
      if (err) bad.push(err);
      else if (Object.keys(se).length) stemEnv = se;
    }
  }

  // planOverride — the one part of the reply that speaks about *this* pair.
  let planOv = null;
  const po = parsed.planOverride;
  if (po !== undefined && po !== null) {
    if (typeof po !== "object" || Array.isArray(po)) {
      bad.push('planOverride 不是一个对象');
    } else {
      const next = {outPoint: null, inPoint: null, overlap: null};
      let ok = true;
      for (const [key, value] of Object.entries(po)) {
        if (!(key in next)) { ignored.push("planOverride." + key); continue; }
        if (value === null) continue;
        const v = secondsFrom(value);
        if (v === null) {
          bad.push(`planOverride.${key}=${JSON.stringify(value)}`);
          ok = false; continue;
        }
        next[key] = v;
      }
      const err = ok ? planOverrideError(next) : null;
      if (err) { bad.push(err); }
      else if (ok && Object.values(next).some(v => v !== null)) { planOv = next; }
    }
  }

  const notes = [];
  if (planOv) {
    const p = REPORT.plan;
    const moves = [];
    if (planOv.outPoint !== null)
      moves.push(`出点 ${mmss(p.plannerOutPoint ?? p.outPoint)} → <b>${mmss(planOv.outPoint)}</b>`);
    if (planOv.inPoint !== null)
      moves.push(`入点 ${mmss(p.plannerInPoint ?? p.inPoint)} → <b>${mmss(planOv.inPoint)}</b>`);
    if (planOv.overlap !== null)
      moves.push(`叠加 ${fmt(p.plannerOverlap ?? p.overlapDuration)} → <b>${
        fmt(planOv.overlap)}</b> 秒`);
    notes.push("<b>这一对的交接点</b>（只影响当前这一对，不动全局参数）<br>"
      + moves.join("<br>"));
  }
  if (rows.length) notes.push("<b>要改的参数</b><br>" + rows.join("<br>"));
  if (style) notes.push(`<b>出曲离场手法</b> 改为 <code>${style}</code>`);
  if (stem) notes.push(`<b>stem 手法</b> 改为 <code>${stem}</code>`);
  if (stemEnv) {
    notes.push("<b>手写的四条增益曲线</b>（只影响当前这一对）<br>"
      + ENV_LANES.filter(k => Array.isArray(stemEnv[k]) && stemEnv[k].length)
          .map(k => `<code>${k}</code> ${stemEnv[k].length} 个点：`
            + stemEnv[k].map(p => `${fmt(p[0], 1)}s→${fmt(p[1], 1)}dB`).join("，")).join("<br>")
      + "<br><span class=\"muted\">没写到的通道保持直通（0 dB）。</span>");
  }
  if (parsed.rationale) notes.push(`<b>AI 给的理由</b><br>${String(parsed.rationale)}`);
  if (ignored.length) {
    notes.push(`<span class="err">这些名字不存在，已忽略：${ignored.join("、")}</span>`);
  }
  if (bad.length) {
    notes.push(`<span class="err">这些取值不合法，已拒绝：${bad.join("、")}</span>`);
  }
  if (!rows.length && !style && !stem && !planOv && !stemEnv) {
    notes.push('<span class="err">解析出来了，但没有一项是能应用的改动。</span>');
    preview.innerHTML = notes.join("<br><br>");
    return;
  }
  PENDING_AI = {config: accepted, style: style, stem: stem, planOverride: planOv,
                stemEnvelope: stemEnv};
  preview.innerHTML = notes.join("<br><br>");
  $("#applyAI").style.display = $("#cancelAI").style.display = "";
};

$("#applyAI").onclick = () => {
  if (!PENDING_AI) return;
  if (PENDING_AI.style) $("#styleSel").value = PENDING_AI.style;
  if (PENDING_AI.stem) {
    $("#stemSel").value = PENDING_AI.stem;
    STEM_ENV = null;
    paintDuck();
  }
  if (PENDING_AI.stemEnvelope) {
    STEM_ENV = PENDING_AI.stemEnvelope;
    $("#stemSel").value = "none";
    paintDuck();
  }
  $("#applyAI").style.display = $("#cancelAI").style.display = "none";
  const applied = Object.keys(PENDING_AI.config).length;
  const parts = [];
  if (PENDING_AI.planOverride) {
    // Fills the three boxes and lands in PLAN_OV, exactly as if it had been
    // typed there — `applyConfig` below is what re-plans.
    setPlanOverride(PENDING_AI.planOverride, false);
    parts.push("交接点");
  }
  if (applied) parts.push(`${applied} 项参数改动`);
  if (PENDING_AI.style || PENDING_AI.stem) parts.push("手法改动");
  if (PENDING_AI.stemEnvelope) parts.push("四条增益曲线");
  applyConfig(Object.assign({}, CONFIG, PENDING_AI.config));   // re-plans
  BATCH = null;
  $("#aiPreview").innerHTML = `已应用${parts.join("、") || "改动"}，决策已重算。`;
  PENDING_AI = null;
};

$("#cancelAI").onclick = () => {
  PENDING_AI = null;
  $("#applyAI").style.display = $("#cancelAI").style.display = "none";
  $("#aiPreview").innerHTML = "";
};

// ---------------------------------------------------------------- presets

function refreshConfigList(names) {
  $("#cfgList").innerHTML = names.length
    ? names.map(n => `<option value="${n}">${n}</option>`).join("")
    : '<option value="">（还没有预设）</option>';
}

$("#saveCfg").onclick = async () => {
  const name = $("#cfgName").value.trim();
  if (!name) { $("#cfgName").focus(); return; }
  const r = await api("/api/configs", {name: name, config: CONFIG});
  refreshConfigList(r.configs);
  $("#cfgList").value = r.saved;
};
$("#loadCfg").onclick = async () => {
  const name = $("#cfgList").value;
  if (!name) return;
  const r = await api("/api/configs/" + encodeURIComponent(name));
  applyConfig(r.config);
};
$("#resetAll").onclick = () => applyConfig(BOOT.standard);

// ---------------------------------------------------------------- picking

const pairIndex = () => BOOT.pairs.findIndex(
  p => p.outgoing === $("#outSel").value && p.incoming === $("#inSel").value);
/// A hand-placed seam belongs to one pair; carrying it to the next pair would
/// point at seconds that mean nothing there, so switching pairs drops it.
function clearPlanOverrideAndPlan() {
  $("#ovOut").value = $("#ovIn").value = $("#ovLen").value = "";
  PLAN_OV = {outPoint: null, inPoint: null, overlap: null};
  // Curves written against this overlap mean nothing against the next one.
  STEM_ENV = null;
  $("#ovErr").textContent = "";
  paintPlanOverride();
  plan();
}

function gotoPair(i) {
  if (!BOOT.pairs.length) return;
  const p = BOOT.pairs[(i + BOOT.pairs.length) % BOOT.pairs.length];
  $("#outSel").value = p.outgoing; $("#inSel").value = p.incoming;
  clearPlanOverrideAndPlan();
}
$("#prevPair").onclick = () => gotoPair((pairIndex() < 0 ? 0 : pairIndex()) - 1);
$("#nextPair").onclick = () => gotoPair((pairIndex() < 0 ? -1 : pairIndex()) + 1);
$("#swap").onclick = () => {
  const a = $("#outSel").value;
  $("#outSel").value = $("#inSel").value; $("#inSel").value = a;
  clearPlanOverrideAndPlan();
};
$("#usePaths").onclick = () => {
  for (const [inp, sel] of [["#outPath", "#outSel"], ["#inPath", "#inSel"]]) {
    const v = $(inp).value.trim();
    if (!v) continue;
    const s = $(sel);
    let opt = [...s.options].find(o => o.value === v);
    if (!opt) { opt = new Option(v.split("/").pop(), v); s.add(opt); }
    s.value = v;
  }
  clearPlanOverrideAndPlan();
};
$("#outSel").onchange = clearPlanOverrideAndPlan;
$("#inSel").onchange = clearPlanOverrideAndPlan;
$("#styleSel").onchange = plan;
$("#fadeOv").oninput = schedulePlan;
$("#stemSel").onchange = () => { STEM_ENV = null; paintDuck(); plan(); };
$("#envClear").onclick = () => { STEM_ENV = null; plan(); };
$("#stemsReady").onchange = () => { BATCH = null; plan(); };
$("#duckDB").oninput = () => { paintDuck(); schedulePlan(); };

boot().catch(e => { $("#lead").textContent = "启动失败：" + e.message; });
</script>
</body>
</html>
"""#
#endif
