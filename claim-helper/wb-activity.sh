#!/bin/bash
# wb-activity.sh — WorkBuddy 国际版每日活跃上报（被动领积分，方案 A：零侵入插件）
# 每天 cron 跑一次：读 plugin-auth.json 全部 workbuddy 号，各发一轮 /v2/report chat_request_send
# 代理：读 magpie settings.json 的 proxyCustom（socks5），未配置则直连
# 日志：/root/wb-activity.log；凭证不落日志
export PATH=/usr/local/lib/nodejs/node-v24.11.1-linux-x64/bin:$PATH

LOG=/root/wb-activity.log
echo "=== $(date -Is) ===" >> "$LOG"

node --input-type=module <<'EOF' >> "$LOG" 2>&1
import fs from 'node:fs';
import { execFileSync } from 'node:child_process';

const BASE = 'https://www.workbuddy.ai';
const DOMAIN = 'www.workbuddy.ai';
const APP = '3.17.2';

// 按号代理: providers.json 里 workbuddy-ai.accountProxies[email] 优先,
// 回退 settings.json 的全局 proxyCustom; 每号各自 curl -x, 与插件同出口 IP
function readAccountProxies() {
  const out = { global: '' };
  try {
    const s = JSON.parse(fs.readFileSync('/root/.config/magpie/settings.json', 'utf8'));
    out.global = s.proxyCustom || '';
  } catch {}
  try {
    const p = JSON.parse(fs.readFileSync('/root/.config/magpie/providers.json', 'utf8'));
    const wb = (p.providers || []).find(x => x.id === 'workbuddy-ai');
    out.perAccount = wb?.accountProxies || {};
  } catch (e) {
    console.log(`providers.json unreadable, falling back to global proxy: ${String(e).slice(0, 80)}`);
    out.perAccount = {};
  }
  return out;
}
const PROXIES = readAccountProxies();
// curl 选项注入防护: 拒绝以 - 开头的配置值
function proxyFor(email) {
  const raw = PROXIES.perAccount[email] || PROXIES.global || '';
  if (typeof raw !== 'string' || !raw || raw.startsWith('-') || /[\r\n\0]/.test(raw)) return '';
  return raw;
}
function proxyHostOf(px) {
  if (!px) return '(direct)';
  try { return new URL(px).host || '(masked)'; } catch { return '(masked)'; }
}
console.log(`proxy: per-account from providers.json (fallback: global proxyCustom)`);

function readAccounts() {
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync('/root/.config/magpie/plugin-auth.json', 'utf8'));
  } catch (e) {
    console.log(`plugin-auth.json unreadable: ${String(e).slice(0, 80)}`);
    process.exit(1);
  }
  const strip = (s) => String(s ?? '').replace(/[\r\n\0]/g, '');
  const out = [];
  for (const [k, v] of Object.entries(raw)) {
    if (!k.startsWith('workbuddy')) continue;
    if (v.type !== 'oauth' || !v.access || !v.uid) continue;
    out.push({ id: k, email: strip(v.accountId) || k, access: strip(v.access), uid: strip(v.uid), domain: strip(v.domain) || DOMAIN });
  }
  return out;
}

function headers(a) {
  return [
    '-H', 'Content-Type: application/json',
    '-H', 'Accept: application/json',
    '-H', `User-Agent: WorkBuddy/${APP}`,
    '-H', `Authorization: Bearer ${a.access}`,
    '-H', `X-User-Id: ${a.uid}`,
    '-H', `X-Domain: ${a.domain}`,
    '-H', 'X-Product: SaaS',
    '-H', 'X-IDE-Type: WorkBuddy',
  ];
}

function chatRequestSendEvent(uid) {
  const now = Date.now();
  const cid = `wb-act-${now}`;
  return [{
    eventCode: 'chat_request_send',
    timestamp: now,
    reportDelay: 0,
    mode: 'craft',
    conversationId: cid,
    requestId: `${cid}-req`,
    inputLength: 12,
    requestModelId: 'fast-model',
    requestModelName: 'fast-model',
    isPlan: false,
    agentName: 'cli',
    agentType: 'conversation',
    userId: uid,
  }];
}

function curlJson(url, a, body) {
  const px = proxyFor(a.email);
  const args = ['-s', '--max-time', '30', ...(px ? ['-x', px] : []),
    '-X', 'POST', url, ...headers(a),
    '-d', typeof body === 'string' ? body : JSON.stringify(body)];
  const out = execFileSync('curl', args, { encoding: 'utf8', timeout: 35000 });
  try { return JSON.parse(out); } catch { return { _raw: out.slice(0, 120) }; }
}

function report(a) {
  const j = curlJson(`${BASE}/v2/report`, a, chatRequestSendEvent(a.uid));
  return { code: j.code, msg: j.msg };
}

function balance(a) {
  const j = curlJson(`${BASE}/billing/meter/get-user-resource-summary`, a, {});
  const pkgs = j?.data?.Packages || [];
  return pkgs.map(p => `${p.CycleRemainCapacity}/${p.CycleTotalCapacity}`).join(' , ') || 'no-data';
}

const accs = readAccounts();
if (!accs.length) { console.log('no workbuddy oauth accounts'); process.exit(0); }

let ok = 0;
for (const a of accs) {
  try {
    const r = report(a);
    const bal = r.code === 0 ? balance(a) : '-';
    console.log(`${a.email} report=${r.code}${r.msg && r.msg !== 'OK' ? ' ' + r.msg : ''} via=${proxyHostOf(proxyFor(a.email))} balance=[${bal}]`);
    if (r.code === 0) ok++;
  } catch (e) {
    console.log(`${a.email} ERR ${String(e).slice(0, 120)}`);
  }
  await new Promise(r => setTimeout(r, 1200));
}
console.log(`done: ${ok}/${accs.length} reported`);
EOF
