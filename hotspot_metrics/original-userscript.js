// ==UserScript==
// @name         Hotspot RF Live Summary (Overlay + Baseline + Chart)
// @namespace    local.hotspot.rf
// @version      0.3
// @description  Real-time LTE/5G RSRP/RSRQ/SNR + baseline deltas + live quality chart
// @match        http://192.168.1.1/*
// @grant        none
// ==/UserScript==

(() => {
  'use strict';

  // ---------- Config ----------
  const SAMPLE_MS = 2000;        // UI updates every few seconds
  const HISTORY_LEN = 90;        // ~3 minutes @2s
  const PANEL_W = 330;

  // ---------- Helpers ----------
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const fmt = (v, unit='') => (v === null || Number.isNaN(v)) ? '—' : `${v}${unit}`;
  const mean = (arr) => arr.length ? arr.reduce((a,b)=>a+b,0)/arr.length : null;
  const stdev = (arr) => {
    if (arr.length < 2) return null;
    const m = mean(arr);
    const v = arr.reduce((a,b)=>a+(b-m)*(b-m),0)/(arr.length-1);
    return Math.sqrt(v);
  };

  // Threshold colors (tweak to taste)
  function colorRSRP(x){ if(x==null) return '#999'; return (x>=-90)?'#2ecc71':(x>=-105)?'#f1c40f':'#e74c3c'; }
  function colorRSRQ(x){ if(x==null) return '#999'; return (x>=-10)?'#2ecc71':(x>=-13)?'#f1c40f':'#e74c3c'; }
  function colorSNR(x){  if(x==null) return '#999'; return (x>=13)?'#2ecc71':(x>=5)?'#f1c40f':'#e74c3c'; }

  function extractMetric(text, label, unit) {
    const re = new RegExp(`${label}\\s*(-?\\d+(?:\\.\\d+)?)\\s*${unit}`);
    const m = text.match(re);
    return m ? Number(m[1]) : null;
  }
  function extractString(text, label) {
    const re = new RegExp(`${label}\\s*([^\\n\\r]+)`);
    const m = text.match(re);
    return m ? m[1].trim() : '—';
  }

  // ---------- Quality score (0..100) ----------
  function qualityScore({ snr, rsrq, rsrp }) {
    // Normalize each metric to 0..1 (heuristic scale for relative tuning)
    const sSNR  = (snr  == null) ? null : clamp((snr + 5) / 25, 0, 1);     // -5..20 dB
    const sRSRQ = (rsrq == null) ? null : clamp((rsrq + 20) / 17, 0, 1);   // -20..-3 dB
    const sRSRP = (rsrp == null) ? null : clamp((rsrp + 120) / 40, 0, 1);  // -120..-80 dBm

    // Weighted avg over available components
    const parts = [
      { v: sSNR,  w: 0.50 },
      { v: sRSRQ, w: 0.30 },
      { v: sRSRP, w: 0.20 },
    ].filter(p => p.v !== null);

    if (!parts.length) return null;

    const wsum = parts.reduce((a,p)=>a+p.w,0);
    const vsum = parts.reduce((a,p)=>a+p.w*p.v,0);
    return Math.round((vsum / wsum) * 100);
  }

  // ---------- UI ----------
  const panel = document.createElement('div');
  panel.style.cssText = `
    position: fixed; top: 14px; right: 14px; z-index: 999999;
    width: ${PANEL_W}px; font: 12px/1.35 system-ui, Segoe UI, Arial;
    background: rgba(20,20,20,0.88); color: #fff;
    border: 1px solid rgba(255,255,255,0.15);
    border-radius: 10px; padding: 10px;
    box-shadow: 0 8px 24px rgba(0,0,0,0.35);
    user-select: none;
  `;

  panel.innerHTML = `
    <div style="display:flex; align-items:center; justify-content:space-between; gap:8px;">
      <div style="font-weight:800;">RF Summary</div>
      <div id="qNow" style="color:rgba(255,255,255,.85); font-weight:700; font-size:11px;">LTE — / 5G —</div>
    </div>

    <div id="meta" style="margin-top:6px; color:rgba(255,255,255,0.75);"></div>

    <div style="margin-top:8px;">
      <canvas id="qChart" width="${PANEL_W-20}" height="95"
        style="display:block; width:100%; border-radius:8px; background:rgba(255,255,255,0.06);"></canvas>
      <div style="margin-top:4px; display:flex; gap:10px; align-items:center; color:rgba(255,255,255,.75); font-size:11px;">
        <span><span style="display:inline-block;width:10px;height:3px;background:#4aa3ff;margin-right:6px;vertical-align:middle;"></span>LTE</span>
        <span><span style="display:inline-block;width:10px;height:3px;background:#ff5db1;margin-right:6px;vertical-align:middle;"></span>5G</span>
        <span style="margin-left:auto;">Quality 0–100</span>
      </div>
    </div>

    <div style="margin-top:8px; display:grid; grid-template-columns: 1fr 1fr; gap:10px;">
      <div>
        <div style="font-weight:800; margin-bottom:4px;">LTE</div>
        <div>RSRP: <span id="lteRsrp">—</span></div>
        <div>RSRQ: <span id="lteRsrq">—</span></div>
        <div>SNR:  <span id="lteSnr">—</span></div>
      </div>
      <div>
        <div style="font-weight:800; margin-bottom:4px;">5G</div>
        <div>RSRP: <span id="nrRsrp">—</span></div>
        <div>RSRQ: <span id="nrRsrq">—</span></div>
        <div>SNR:  <span id="nrSnr">—</span></div>
      </div>
    </div>

    <div style="margin-top:8px; padding-top:8px; border-top:1px solid rgba(255,255,255,0.12);">
      <div style="display:flex; gap:8px; align-items:center; justify-content:space-between;">
        <div style="font-weight:800;">Compare</div>
        <div>
          <button id="btnBase">Set baseline</button>
          <button id="btnClear">Clear</button>
        </div>
      </div>
      <div id="compareLine" style="margin-top:6px; color:rgba(255,255,255,0.75);">Baseline: —</div>
      <div id="deltaLine" style="margin-top:4px;">Δ: —</div>
      <div id="stability" style="margin-top:6px; color:rgba(255,255,255,0.65); font-size:11px;"></div>
    </div>
  `;
  document.body.appendChild(panel);

  // button styling
  for (const b of panel.querySelectorAll('button')) {
    b.style.cssText = `
      font: 12px system-ui, Segoe UI, Arial;
      border: 1px solid rgba(255,255,255,0.25);
      background: rgba(255,255,255,0.08);
      color: #fff; padding: 3px 8px; border-radius: 8px; cursor: pointer;
    `;
  }

  // draggable
  let dragging=false, dx=0, dy=0;
  panel.addEventListener('mousedown', (e)=>{ dragging=true; const r=panel.getBoundingClientRect(); dx=e.clientX-r.left; dy=e.clientY-r.top; e.preventDefault(); });
  window.addEventListener('mousemove', (e)=>{ if(!dragging) return; panel.style.left=`${e.clientX-dx}px`; panel.style.top=`${e.clientY-dy}px`; panel.style.right='auto'; });
  window.addEventListener('mouseup', ()=> dragging=false);

  const $ = (sel) => panel.querySelector(sel);
  function setVal(el, val, unit, colorFn){
    el.textContent = fmt(val, unit);
    el.style.color = colorFn(val);
    el.style.fontWeight = '800';
  }

  // ---------- State ----------
  let baseline = null;
  const hist = {
    lteSnr:[], nrSnr:[], lteRsrq:[], nrRsrq:[],
    qLte:[], q5g:[]
  };

  // ---------- Chart ----------
  const canvas = $('#qChart');
  const ctx = canvas.getContext('2d');

  function pushSeries(arr, v) {
    arr.push(v);
    if (arr.length > HISTORY_LEN) arr.shift();
  }

  function drawChart() {
    const w = canvas.width, h = canvas.height;
    ctx.clearRect(0,0,w,h);

    const padL = 26, padR = 8, padT = 8, padB = 16;
    const gw = w - padL - padR;
    const gh = h - padT - padB;

    // background grid
    ctx.save();
    ctx.globalAlpha = 0.7;
    ctx.strokeStyle = 'rgba(255,255,255,0.12)';
    ctx.lineWidth = 1;

    // horizontal lines at 0/25/50/75/100
    const ticks = [0,25,50,75,100];
    ctx.font = '10px system-ui, Segoe UI, Arial';
    ctx.fillStyle = 'rgba(255,255,255,0.55)';
    for (const t of ticks) {
      const y = padT + gh - (t/100)*gh;
      ctx.beginPath();
      ctx.moveTo(padL, y);
      ctx.lineTo(padL+gw, y);
      ctx.stroke();

      ctx.fillText(String(t), 2, y+3);
    }

    // axis border
    ctx.globalAlpha = 1;
    ctx.strokeStyle = 'rgba(255,255,255,0.18)';
    ctx.strokeRect(padL, padT, gw, gh);
    ctx.restore();

    const n = Math.max(hist.qLte.length, hist.q5g.length);
    if (n < 2) return;

    const xAt = (i) => padL + (i/(HISTORY_LEN-1))*gw;
    const yAt = (q) => {
      if (q == null) return null;
      const qq = clamp(q, 0, 100);
      return padT + gh - (qq/100)*gh;
    };

    function plot(series, color) {
      ctx.save();
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      ctx.beginPath();
      let started = false;

      // series aligned to the end (most recent on right)
      const startIdx = Math.max(0, HISTORY_LEN - series.length);
      for (let i = 0; i < series.length; i++) {
        const x = xAt(startIdx + i);
        const y = yAt(series[i]);
        if (y == null) { started = false; continue; }
        if (!started) { ctx.moveTo(x,y); started = true; }
        else ctx.lineTo(x,y);
      }
      ctx.stroke();
      ctx.restore();
    }

    plot(hist.qLte, '#4aa3ff'); // LTE
    plot(hist.q5g,  '#ff5db1'); // 5G
  }

  // ---------- Logic ----------
  function snapshot(cur){
    return {
      lteRsrp: cur.lteRsrp, lteRsrq: cur.lteRsrq, lteSnr: cur.lteSnr,
      nrRsrp:  cur.nrRsrp,  nrRsrq:  cur.nrRsrq,  nrSnr:  cur.nrSnr,
      band: cur.band, svc: cur.svc
    };
  }

  function current(){
    const text = document.body.innerText || '';

    // exact strings appear in your diagnostics page 【1-b93168】
    return {
      lteRsrp: extractMetric(text, 'LTE RSRP', 'dBm'),
      lteRsrq: extractMetric(text, 'LTE RSRQ', 'dB'),
      lteSnr:  extractMetric(text, 'LTE RS-SNR', 'dB'),

      nrRsrp:  extractMetric(text, '5G RSRP', 'dBm'),
      nrRsrq:  extractMetric(text, '5G RSRQ', 'dB'),
      nrSnr:   extractMetric(text, '5G RS-SNR', 'dB'),

      band:    extractString(text, 'Current Radio Band'),
      svc:     extractString(text, 'PS Service Type'),
    };
  }

  function pushHist(cur){
    const push = (k,v) => { if (v==null) return; hist[k].push(v); if (hist[k].length>HISTORY_LEN) hist[k].shift(); };

    push('lteSnr',  cur.lteSnr);
    push('nrSnr',   cur.nrSnr);
    push('lteRsrq', cur.lteRsrq);
    push('nrRsrq',  cur.nrRsrq);

    const qL = qualityScore({ snr: cur.lteSnr, rsrq: cur.lteRsrq, rsrp: cur.lteRsrp });
    const qN = qualityScore({ snr: cur.nrSnr,  rsrq: cur.nrRsrq,  rsrp: cur.nrRsrp });

    pushSeries(hist.qLte, qL);
    pushSeries(hist.q5g,  qN);

    return { qL, qN };
  }

  function updateUI(cur, qNow){
    setVal($('#lteRsrp'), cur.lteRsrp, ' dBm', colorRSRP);
    setVal($('#lteRsrq'), cur.lteRsrq, ' dB',  colorRSRQ);
    setVal($('#lteSnr'),  cur.lteSnr,  ' dB',  colorSNR);

    setVal($('#nrRsrp'),  cur.nrRsrp,  ' dBm', colorRSRP);
    setVal($('#nrRsrq'),  cur.nrRsrq,  ' dB',  colorRSRQ);
    setVal($('#nrSnr'),   cur.nrSnr,   ' dB',  colorSNR);

    $('#meta').textContent = `${cur.band} • ${cur.svc}`;
    $('#qNow').textContent = `LTE ${fmt(qNow.qL,'')} / 5G ${fmt(qNow.qN,'')}`;

    // Baseline + delta (both radios)
    if (baseline) {
      $('#compareLine').textContent = `Baseline set (${baseline.band} • ${baseline.svc})`;

      const d = (v, b) => (v == null || b == null) ? null : (v - b);

      const dLteSnr  = d(cur.lteSnr,  baseline.lteSnr);
      const dLteRsrq = d(cur.lteRsrq, baseline.lteRsrq);
      const dLteRsrp = d(cur.lteRsrp, baseline.lteRsrp);

      const dNrSnr   = d(cur.nrSnr,   baseline.nrSnr);
      const dNrRsrq  = d(cur.nrRsrq,  baseline.nrRsrq);
      const dNrRsrp  = d(cur.nrRsrp,  baseline.nrRsrp);

      $('#deltaLine').textContent =
        `Δ LTE: SNR ${fmt(dLteSnr,' dB')}, RSRQ ${fmt(dLteRsrq,' dB')}, RSRP ${fmt(dLteRsrp,' dBm')}  |  ` +
        `Δ 5G: SNR ${fmt(dNrSnr,' dB')}, RSRQ ${fmt(dNrRsrq,' dB')}, RSRP ${fmt(dNrRsrp,' dBm')}`;
    } else {
      $('#compareLine').textContent = `Baseline: —`;
      $('#deltaLine').textContent = `Δ: —`;
    }

    // Stability (stddev) over history
    const s5 = stdev(hist.nrSnr), s4 = stdev(hist.lteSnr);
    const q5 = stdev(hist.nrRsrq), q4 = stdev(hist.lteRsrq);
    $('#stability').textContent =
      `Stability (~${Math.round((HISTORY_LEN*SAMPLE_MS)/1000)}s): ` +
      `LTE SNR σ=${fmt(s4?.toFixed(1),'')}, 5G SNR σ=${fmt(s5?.toFixed(1),'')}, ` +
      `LTE RSRQ σ=${fmt(q4?.toFixed(1),'')}, 5G RSRQ σ=${fmt(q5?.toFixed(1),'')}`;

    drawChart();
  }

  $('#btnBase').addEventListener('click', () => baseline = snapshot(current()));
  $('#btnClear').addEventListener('click', () => baseline = null);

  function tick(){
    const cur = current();
    const qNow = pushHist(cur);
    updateUI(cur, qNow);
  }

  tick();
  setInterval(tick, SAMPLE_MS);
})();