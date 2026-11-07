#!/bin/bash
# wb-activity.sh — WorkBuddy 国际版每日活跃上报（被动领积分，方案 A：零侵入插件）
# 每天 cron 跑一次：读 plugin-auth.json 全部 workbuddy 号，各发一轮 /v2/report chat_request_send
# 日志：/root/wb-activity.log；凭证不落日志
export PATH=/usr/local/lib/nodejs/node-v24.11.1-linux-x64/bin:$PATH

LOG=/root/wb-activity.log
echo "=== $(date -Is) ===" >> "$LOG"

node --input-type=module <<'EOF' >> "$LOG" 2>&1
import fs from 'node:fs';

const BASE = 'https://www.workbuddy.ai';
const DOMAIN = 'www.workbuddy.ai';
const APP = '3.17.2';

function readAccounts() {
  const raw = JSON.parse(fs.readFileSync('/root/.config/magpie/plugin-auth.json', 'utf8'));
  const out = [];
  for (const [k, v] of Object.entries(raw)) {
    if (!k.startsWith('workbuddy')) continue;
    // 只处理 oauth 号（API key 号没有 access/uid，报不了活跃）
    if (v.type !== 'oauth' || !v.access || !v.uid) continue;
    out.push({ id: k, email: v.accountId || k, access: v.access, uid: v.uid, domain: v.domain || DOMAIN });
  }
  return out;
}

function headers(a) {
  return {
    'Content-Type': 'application/json',
    Accept: 'application/json',
    'User-Agent': `WorkBuddy/${APP}`,
    Authorization: `Bearer ${a.access}`,
    'X-User-Id': a.uid,
    'X-Domain': a.domain,
    'X-Product': 'SaaS',
    'X-IDE-Type': 'WorkBuddy',
  };
}

function chatRequestSendEvent(uid) {
  const now = Date.now();
  const cid = `wb-act-${now}`;
  const rid = `${cid}-req`;
  return [{
    eventCode: 'chat_request_send',
    timestamp: now,
    reportDelay: 0,
    mode: 'craft',
    conversationId: cid,
    requestId: rid,
    inputLength: 12,
    requestModelId: 'fast-model',
    requestModelName: 'fast-model',
    isPlan: false,
    agentName: 'cli',
    agentType: 'conversation',
    userId: uid,
  }];
}

async function report(a) {
  const res = await fetch(`${BASE}/v2/report`, {
    method: 'POST',
    headers: headers(a),
    body: JSON.stringify(chatRequestSendEvent(a.uid)),
  });
  const j = await res.json().catch(() => ({}));
  return { code: j.code, msg: j.msg, http: res.status };
}

async function balance(a) {
  const res = await fetch(`${BASE}/billing/meter/get-user-resource-summary`, {
    method: 'POST',
    headers: headers(a),
    body: JSON.stringify({}),
  });
  const j = await res.json().catch(() => ({}));
  const pkgs = j?.data?.Packages || [];
  return pkgs.map(p => `${p.CycleRemainCapacity}/${p.CycleTotalCapacity}`).join(' , ') || 'no-data';
}

const accs = readAccounts();
if (!accs.length) { console.log('no workbuddy oauth accounts'); process.exit(0); }

let ok = 0;
for (const a of accs) {
  try {
    const r = await report(a);
    const bal = r.code === 0 ? await balance(a) : '-';
    console.log(`${a.email} report=${r.http}/${r.code}${r.msg && r.msg !== 'OK' ? ' ' + r.msg : ''} balance=[${bal}]`);
    if (r.code === 0) ok++;
  } catch (e) {
    console.log(`${a.email} ERR ${String(e).slice(0, 100)}`);
  }
  await new Promise(r => setTimeout(r, 1200));
}
console.log(`done: ${ok}/${accs.length} reported`);
EOF
