---
name: local-app-testing
description: "Use when asked to clickthrough test DMeer or any local Electron app. Uses cliclick for real mouse clicks + CDP for element positions and screenshots. Clicks through the UI as a real user would. Not a deterministic script — agent uses common sense."
domain: engineering
subjects.team: dmer-app-team
type: Bounded
allowed-tools: read write edit bash
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Local App Testing

How to test DMeer (or any local Electron app) by clicking through the UI as a real user would — with real mouse clicks via cliclick, not simulated browser events.

## Philosophy

This is a **human-emulation test**, not a deterministic script. The agent clicks buttons with real mouse events, fills forms, and observes behavior exactly as a user would.

## Tools Required

| Tool | Purpose |
|------|---------|
| `cliclick` | Real mouse clicks at screen coordinates (`brew install cliclick`) |
| CDP via `--remote-debugging-port` | Screenshots, element position queries |
| `osascript` + shell | Window position, screen size, coordinate math |

## Launch

```bash
cd /path/to/dmer
pkill -9 Electron 2>/dev/null; sleep 2
rm -f ~/Library/Application\ Support/dmeer/Singleton* 2>/dev/null
DMER_AUTO_CONFIG=1 npx electron . --remote-debugging-port=9243 &
for i in $(seq 1 15); do curl -s http://127.0.0.1:9243/json/version > /dev/null && break; sleep 1; done
```

## The Test Pattern

### Step 1 — Get window position (osascript)

macOS title bar (~28px) is NOT part of the viewport. Use osascript for runtime position:

```bash
WIN_POS=$(osascript -e 'tell application "System Events" to get position of window 1 of process "Electron"' 2>/dev/null)
if [ -n "$WIN_POS" ]; then
  WIN_X=$(echo $WIN_POS | cut -d, -f1)
  WIN_Y=$(echo $WIN_POS | cut -d, -f2 | tr -d ' ')
else
  SCREEN=$(osascript -e 'tell application "Finder" to get bounds of window of desktop')
  SW=$(echo $SCREEN | cut -d, -f3); SH=$(echo $SCREEN | cut -d, -f4)
  WIN_X=$(( ($SW - 520) / 2 )); WIN_Y=$(( ($SH - 680) / 2 ))
fi
```

### Step 2 — Find element position (CDP)

Query getBoundingClientRect via CDP Runtime.evaluate:

```bash
node -e "
const WebSocket=require('ws');const http=require('http');
(async()=>{
  const pages=await new Promise((r,j)=>{http.get('http://127.0.0.1:9243/json',res=>{let b='';res.on('data',c=>b+=c);res.on('end',()=>r(JSON.parse(b)))}).on('error',j)});
  const pg=pages.find(p=>p.type==='page');
  const ws=new WebSocket(pg.webSocketDebuggerUrl);
  await new Promise(r=>ws.on('open',r));
  let mid=0;const pend=new Map();
  function cmd(m,p={}){const id=++mid;ws.send(JSON.stringify({id,method:m,params:p}));return new Promise((r,j)=>{pend.set(id,r);setTimeout(()=>{pend.delete(id);j(new Error('timeout'))},5000)});}
  ws.on('message',d=>{const m=JSON.parse(d);if(pend.has(m.id)){pend.get(m.id)(m.error?Promise.reject(new Error(m.error.message)):m.result);pend.delete(m.id);}});
  await cmd('Runtime.enable');
  const box=await cmd('Runtime.evaluate',{
    expression:'(()=>{const el=document.querySelector("YOUR_SELECTOR");if(!el)return null;const r=el.getBoundingClientRect();return{x:r.x,y:r.y,w:r.width,h:r.height}})()',
    returnByValue:true
  });
  console.log(JSON.stringify(box?.result?.value));
  ws.close();
})().catch(e=>console.error(e.message));
"
```

### Step 3 — Calculate absolute coordinates and click

```bash
# From CDP: {x:57, y:139, w:406, h:33}
BTN_X=$(( $WIN_X + ELEMENT_X + ELEMENT_W / 2 ))
BTN_Y=$(( $WIN_Y + ELEMENT_Y + ELEMENT_H / 2 ))
cliclick c:$BTN_X,$BTN_Y
sleep 1
```

### Step 4 — Screenshot to verify

```bash
node -e "const WebSocket=require('ws');const http=require('http');const fs=require('fs');
(async()=>{
  const pages=await new Promise((r,j)=>{http.get('http://127.0.0.1:9243/json',res=>{let b='';res.on('data',c=>b+=c);res.on('end',()=>r(JSON.parse(b)))}).on('error',j)});
  const pg=pages.find(p=>p.type==='page');
  const ws=new WebSocket(pg.webSocketDebuggerUrl);
  await new Promise(r=>ws.on('open',r));
  let mid=0;const pend=new Map();
  function cmd(m,p={}){const id=++mid;ws.send(JSON.stringify({id,method:m,params:p}));return new Promise((r,j)=>{pend.set(id,r);setTimeout(()=>{pend.delete(id);j(new Error('timeout'))},5000)});}
  ws.on('message',d=>{const m=JSON.parse(d);if(pend.has(m.id)){pend.get(m.id)(m.error?Promise.reject(new Error(m.error.message)):m.result);pend.delete(m.id);}});
  const scr=await cmd('Page.captureScreenshot',{format:'png'});
  fs.writeFileSync('/tmp/test.png',Buffer.from(scr.data,'base64'));
  ws.close();
})().catch(e=>console.error(e.message));
"
```
Use `read_image` tool to visually verify the screenshot.

### Step 5 — Type text

```bash
cliclick t:"linkedin.com/in/conductal"
cliclick kp:tab; cliclick kp:enter
```

## Verification Checklist

- [ ] Platform modal opens when clicking "Add Profile"
- [ ] Platform cards visible: Instagram, LinkedIn, Twitter/X render inside modal
- [ ] LinkedIn label: "LinkedIn Profile URL" (not "Handle")
- [ ] LinkedIn URL saves without `@` prefix
- [ ] Instagram profile saves with correct badge
- [ ] Twitter/X profile saves with correct badge
- [ ] All 3 profiles coexist independently

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| CDP connection refused | App not running. Check `ps aux \| grep Electron` |
| Window not centered | App remembers position. Reset: `defaults delete com.eldato.dmeer` |
| Title bar offset causes Y miss | Always use osascript for window position (Step 1) |
| Window not found by osascript | Electron windows use a11y API inconsistently. Use centered fallback |
| Platform cards empty | `init()` may have failed silently — see #110 |
| Multiple DMeer icons | `pkill -9 Electron`, clean SingletonLock |

## Why Not Playwright/CDP Clicks?

Electron's `contextIsolation` blocks CDP `Runtime.evaluate` from accessing page JS. CDP `Input.dispatchMouseEvent` doesn't reliably trigger inline `onclick` handlers. `cliclick` sends REAL system-level mouse events via CoreGraphics that ALWAYS work — exactly what a human user generates.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
