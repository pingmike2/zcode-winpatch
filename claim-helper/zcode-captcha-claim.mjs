#!/usr/bin/env node
// zcode-captcha-claim3.mjs — 手动领取辅助页 v3
// 1) 多账号下拉，显示名=accountId 邮箱；2) 免验证直领先行，3007 才弹滑块；
// 3) 监听全接口（ip:端口直达），页面显示本机入口
// 路由：/ (页面) /cfg (captcha配置) /accounts (账号列表) /claim (POST 领取)
import http from 'node:http';
import fs from 'node:fs';

const ZC = 'https://zcode.z.ai';
const PORT = 12696;
const DEFAULT_PLAN = process.env.ZCODE_PLAN || 'zcode-v3-start-plan-1106-wk';
const AUTH_PATH = '/root/.config/magpie/plugin-auth.json';

function readAccounts() {
  const raw = JSON.parse(fs.readFileSync(AUTH_PATH, 'utf8'));
  const out = [];
  for (const [k, v] of Object.entries(raw)) {
    if (!k.startsWith('zcode')) continue;
    let jwt = '', device = '';
    try {
      const r = typeof v.refresh === 'string' ? JSON.parse(v.refresh) : v.refresh;
      if (r && typeof r === 'object') { jwt = r.jwt || ''; device = r.device || ''; }
    } catch {}
    if (!jwt) continue;
    out.push({ id: k, jwt, device, label: (v.accountId && v.accountId.includes('@')) ? v.accountId : k });
  }
  return out;
}

function marketingHeaders(device) {
  return {
    'X-ZCode-App-Version': '3.17.2',
    'X-Platform': 'win32-x64',
    'X-Client-Language': 'zh-CN',
    'User-Agent': 'ZCode/3.17.2',
    ...(device ? { 'X-Device-Mid': device } : {}),
  };
}

async function doClaim(a, planId, verifyParam) {
  const headers = {
    'Content-Type': 'application/json', Accept: 'application/json',
    Authorization: 'Bearer ' + a.jwt,
    ...marketingHeaders(a.device),
  };
  if (verifyParam) {
    headers['X-Aliyun-Captcha-Verify-Param'] = verifyParam;
    headers['X-Aliyun-Captcha-Verify-Region'] = 'sgp';
  }
  const r = await fetch(`${ZC}/api/v1/zcode-plan/billing/claim`, {
    method: 'POST', headers, body: JSON.stringify({ plan_id: planId }),
  });
  const t = await r.text();
  fs.appendFileSync('/tmp/zcode-claim-captcha.log',
    `${new Date().toISOString()} ${a.id} ${planId} verify=${verifyParam ? 'yes' : 'no'} ${r.status} ${t.slice(0, 300)}\n`);
  let code = null;
  try { code = JSON.parse(t).code; } catch {}
  return { http: r.status, body: t.slice(0, 600), code };
}

const page = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ZCode Captcha Claim</title>
<style>body{font:15px/1.6 system-ui;margin:20px;max-width:820px;background:#111;color:#ddd}
button{padding:10px 18px;font-size:15px;border-radius:8px;border:1px solid #555;background:#1f6feb;color:#fff}
pre{background:#000;color:#0f0;padding:10px;border-radius:6px;min-height:50px;white-space:pre-wrap;word-break:break-all}
select{padding:8px;font-size:15px}#cap{margin:12px 0}small{color:#888}code{color:#7ee787}</style>
</head><body>
<h3>ZCode 手动过验证码领取</h3>
<div><small>本机入口: <code id="localEntry"></code>（隧道地址易逝，重启后换新隧道，仍用此 ip:port）</small></div>
<div>账号: <select id="acc"></select> <small>(先免验证直领，被风控拦才弹滑块)</small></div>
<div id="cap"></div>
<p><button id="go">点此领取</button></p>
<pre id="log">ready</pre>
<script>
const log = s => { document.getElementById('log').textContent += '\\n' + s; };
let CFG = null, SDKLoaded = false;
async function init(){
  document.getElementById('localEntry').textContent = location.hostname + ':' + (location.port||'');
  const accs = await (await fetch('/accounts')).json();
  const sel = document.getElementById('acc');
  for (const a of accs) { const o=document.createElement('option'); o.value=a.id; o.textContent=a.label; sel.appendChild(o); }
  sel.value = new URLSearchParams(location.search).get('acc') || accs[0]?.id;
  const r = await fetch('/cfg?acc='+encodeURIComponent(sel.value));
  CFG = await r.json();
  log('cfg ' + JSON.stringify(CFG));
}
function loadSdk(cfg) {
  if (SDKLoaded) return Promise.resolve();
  return new Promise((res, rej) => {
    window.AliyunCaptchaConfig = { region: cfg.region, prefix: cfg.prefix };
    const s = document.createElement('script');
    s.src = 'https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js';
    s.onload = () => { SDKLoaded = true; res(); }; s.onerror = () => rej(new Error('sdk load failed'));
    document.head.appendChild(s);
  });
}
async function claimWith(verifyParam) {
  const q = new URLSearchParams(location.search);
  const r = await fetch('/claim', { method:'POST', headers:{'content-type':'application/json'},
    body: JSON.stringify({ acc: document.getElementById('acc').value,
      plan_id: q.get('plan') || ${JSON.stringify(DEFAULT_PLAN)}, captchaVerifyParam: verifyParam })});
  return r.json();
}
document.getElementById('go').onclick = async () => {
  if(!CFG||CFG.error){ log('no cfg'); return; }
  log('try no-captcha direct claim...');
  const direct = await claimWith(null);
  if (direct.need_captcha) {
    log('server wants captcha (3007), popup slider...');
    await loadSdk(CFG);
    window.initAliyunCaptcha({
      SceneId: CFG.sceneId, prefix: CFG.prefix, mode: 'popup', element: '#cap', button: '#go',
      region: CFG.region, language: 'cn',
      success: async (captchaVerifyParam) => {
        log('captcha ok, claiming...');
        const r = await claimWith(captchaVerifyParam);
        log('claim -> ' + JSON.stringify(r));
      },
      fail: e => log('captcha fail ' + JSON.stringify(e)),
    });
  } else {
    log('claim -> ' + JSON.stringify(direct));
  }
};
init().catch(e=>log('init err '+e));
</script></body></html>`;

const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, 'http://x');
  const json = (o) => { res.writeHead(200, {'content-type':'application/json'}); res.end(JSON.stringify(o)); };
  if (u.pathname === '/') { res.writeHead(200, {'content-type':'text/html; charset=utf-8'}); return res.end(page); }
  if (u.pathname === '/accounts') return json(readAccounts().map(a => ({ id: a.id, label: a.label })));
  if (u.pathname === '/cfg') {
    const accs = readAccounts();
    const acc = accs.find(a => a.id === (u.searchParams.get('acc') || '')) || accs[0];
    try {
      const r = await fetch(`${ZC}/api/v1/client/configs`, { headers: marketingHeaders(acc?.device) });
      const j = await r.json();
      const c = j?.data?.configs?.captcha;
      return json(c && typeof c === 'object'
        ? { region: c.region, prefix: c.prefix, sceneId: c.sceneId }
        : { error: 'no captcha cfg' });
    } catch (e) { return json({ error: String(e) }); }
  }
  if (u.pathname === '/claim' && req.method === 'POST') {
    let body=''; req.on('data',c=>body+=c);
    req.on('end', async () => {
      try {
        const { acc, plan_id, captchaVerifyParam } = JSON.parse(body||'{}');
        const accs = readAccounts();
        const a = accs.find(x => x.id === acc) || accs[0];
        const out = await doClaim(a, plan_id || DEFAULT_PLAN, captchaVerifyParam);
        if (!captchaVerifyParam && out.code === 3007) return json({ need_captcha: true, code: out.code, msg: 'captcha verify failed' });
        return json({ ok: out.code === 0, code: out.code, http: out.http, raw: out.body });
      } catch (e) { return json({ ok: false, error: String(e) }); }
    });
    return;
  }
  res.writeHead(404); res.end('no');
});
server.listen(PORT, () => console.log('listening ' + PORT + ' on all interfaces'));
