(() => {
  const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
  const toast = s => { const e=$("#toast"); e.textContent=s; e.classList.add("show"); setTimeout(()=>e.classList.remove("show"),2800); };
  let token="", snapshot=null, busy=false;
  try { token=location.hash.slice(1)||sessionStorage.getItem("yilinghui.session")||""; } catch {}
  try { if(location.hash && token) sessionStorage.setItem("yilinghui.session",token); } catch {}
  history.replaceState(null,"",location.pathname+location.search);

  async function api(path, body) {
    const headers={"X-Session-Token":token}; if(body!==undefined)headers["Content-Type"]="application/json";
    const res=await fetch(path,{method:body===undefined?"GET":"POST",headers,body:body===undefined?undefined:JSON.stringify(body)});
    const data=await res.json(); if(!res.ok){const e=new Error(data.error||`请求失败 (${res.status})`);e.status=res.status;e.snapshot=data.snapshot;throw e;} return data;
  }
  const pairCard=$("#pair-card");
  function showPair(message="") { pairCard.hidden=false; $("#pair-error").textContent=message; }
  function saveToken(value) { token=value; try{sessionStorage.setItem("yilinghui.session",token);}catch{} }
  function handleAuthError(e) {
    if(e.status!==401)return false;
    token="";try{sessionStorage.removeItem("yilinghui.session");}catch{}
    if(!e.snapshot)syncState({state_known:false,state:null,mode:"deepseek",model:snapshot?.model,connected:snapshot?.connected,trace:["会话已失效"]});
    showPair("服务可能已重启，请输入新的配对令牌。");return true;
  }
  async function connect(value) {
    const candidate=(value||"").trim(); if(!candidate){showPair("请输入启动窗口提供的配对令牌。");return;}
    saveToken(candidate); busy=true; refreshBusy(); $("#pair-error").textContent="正在验证会话并读取网关状态…";
    try { const s=await api("/api/refresh",{}); syncState(s); pairCard.hidden=true; $("#pair-token").value=""; }
    catch(e){if(!handleAuthError(e))showPair(e.message); token="";try{sessionStorage.removeItem("yilinghui.session");}catch{} }
    finally{busy=false;refreshBusy();}
  }
  $("#pair-submit").addEventListener("click",()=>connect($("#pair-token").value));
  $("#pair-token").addEventListener("keydown",e=>{if(e.key==="Enter")connect(e.currentTarget.value);});

  /* ---------- 预览：板2 真实 MJPEG 直通（30 fps） ---------- */
  const liveVideo=$("#live-video"), preview=$("#preview"), pctx=preview.getContext("2d");
  const SW=320,SH=180,source=document.createElement("canvas");
  source.width=SW; source.height=SH;
  const sx=source.getContext("2d",{willReadFrequently:true});
  let paused=false, hasFrame=false;
  const LIVE_URL=`http://${location.hostname}:8080/stream`;
  function updateSourceUI(){
    const live=!!(liveVideo&&liveVideo.naturalWidth>0);
    const tag=$("#source-tag");if(tag)tag.textContent=live?"Ti60F225I3 · LIVE":"Ti60F225I3 · NO SIGNAL";
    const cap=$("#source-caption");if(cap)cap.textContent=live?"板2 实拍 · 实拍直通":"等待板2 实拍视频";
    const badge=$("#link-badge");if(badge)badge.textContent=live?"实板视频":"无实拍信号";
    const foot=$("#foot-source");if(foot)foot.textContent=live?"板2 实拍视频 · 手动控制走真实 UART":"未连接板2 实拍视频";
    const wr=$("#wipe-row");if(wr)wr.style.display="none";
    const vc=$("#view-caption");if(vc)vc.textContent=paused?"已暂停":(live?"实拍直通":"等待实拍");
  }
  async function grabBitmap(){
    const resp=await fetch("/real/snapshot.jpg?t="+Date.now(),{cache:"no-store"});
    if(!resp.ok) throw new Error("no frame");
    const blob=await resp.blob();
    return await createImageBitmap(blob);
  }
  async function grabSnapshot(){
    try{
      const bmp=await grabBitmap();
      sx.drawImage(bmp,0,0,SW,SH);
      bmp.close();
      hasFrame=true;
      return true;
    }catch(e){ return false; }
  }
  async function setPaused(next){
    if(next){
      try{
        const bmp=await grabBitmap();
        pctx.drawImage(bmp,0,0,preview.width,preview.height);
        bmp.close();
      }catch(e){ toast("画面尚未就绪"); return; }
      preview.style.display="block";
      if(liveVideo){ liveVideo.style.display="none"; liveVideo.src=""; }
      paused=true;
    }else{
      preview.style.display="none";
      if(liveVideo){ liveVideo.style.display="block"; liveVideo.src=LIVE_URL+"?t="+Date.now(); }
      paused=false;
    }
    $("#pause-top").textContent=paused?"►":"▮▮";
    $("#pending-note").hidden=!paused;
    updateSourceUI();
  }
  if(liveVideo){
    liveVideo.src=LIVE_URL;
    liveVideo.addEventListener("load",updateSourceUI);
    liveVideo.addEventListener("error",()=>{updateSourceUI();setTimeout(()=>{if(!paused)liveVideo.src=LIVE_URL+"?t="+Date.now();},2000);});
  }
  updateSourceUI();

  /* ---------- 动态渲染：调色表网格 + 灵感配方 ---------- */
  const KIND_LABEL={identity:"原始",grade:"调色 · 曲线模式",grade_bw:"调色 · 黑白",gradient:"渐变映射 · 配灰度",curve:"曲线"};
  const grad=t=>`linear-gradient(90deg,${t.swatch.map(cc=>`rgb(${cc.join(",")})`).join(",")})`;
  const STYLE_GLYPH = {
    vangogh:"✺", popcomic:"◑", candy:"✤", pointillism:"∴", blueprint:"▤",
    neon:"≋", graffiti:"⌇", cyberpunk:"⌁", aurora:"∿", inkwash:"▒",
    picasso:"▙", pixel:"▦", papercut:"✁", cartoon:"◔", woodcut:"▞",
    ukiyoe:"▟", sketch:"✎", minimal:"─", cyanotype:"◫", inkcarve:"⌐",
    tiktok:"♪", sunrise:"☀", rust:"▚", dither:"⣿", retro:"⟲", psy:"◎"
  };
  function renderStyles(){
    const row=document.getElementById("style-row");if(!row)return;row.replaceChildren();
    const styles=snapshot?.capabilities?.styles||{};
    const selected=null; // No board1 state report: never highlight simulated state.
    Object.entries(styles).forEach(([id,cn],i)=>{
      const hue=(i*137.508)%360;
      const btn=document.createElement("button");btn.className="style-chip"+(selected===id?" selected":"");btn.dataset.style=id;
      const sw=document.createElement("span");sw.className="swatch";
      sw.textContent=STYLE_GLYPH[id]||"◆";
      sw.style.color=`hsl(${hue} 70% 62%)`;
      const nm=document.createElement("span");
      const b=document.createElement("b");b.textContent=cn;
      nm.append(b);btn.append(sw,nm);
      btn.addEventListener("click",()=>realAction("model_set_"+i));
      row.append(btn);
    });
  }
  function renderLuts(){
    const grid=$("#lut-grid");if(!grid)return;grid.replaceChildren();
    const tables=snapshot?.capabilities?.tables||{};
    const selected=null; // ACK is acceptance, not current-state readback.
    for(const [i,[id,t]] of Object.entries(tables).entries()){
      const btn=document.createElement("button");btn.className="lut-card"+(selected===id?" selected":"");btn.dataset.curve=id;
      const sw=document.createElement("span");sw.className="lut-swatch";sw.style.background=grad(t);
      const nm=document.createElement("span");nm.className="lut-name";
      const b=document.createElement("b");b.textContent=t.cn;
      nm.append(b);btn.append(sw,nm);
      btn.title=(t.desc?t.desc+" · ":"")+(KIND_LABEL[t.kind]||"");
      btn.addEventListener("click",()=>realAction("table_set_"+i));
      grid.append(btn);
    }
  }

  function syncState(s){
    if(!s)return;snapshot=s;
    $("#sync-state").textContent=s.state_known?`已读回 · r${s.revision}`:"状态未知";
    $("#sync-state").classList.toggle("unknown",!s.state_known);
    $("#mode-status").textContent=s.connected?"DeepSeek · 已配置":"DeepSeek · 未配置 Key";
    $("#scene-status").textContent=s.scene?"已分析":"尚未分析";
    $("#model").value=s.model||"deepseek-flash";
    if(s.scene)$("#scene-status").textContent="已分析";
    renderLuts();renderStyles();
    if(!s.state_known||!s.state){refreshBusy();updateSourceUI();return;}
    const st=s.state;
    for(const [id,key] of [["saturation","saturation"],["wipe","wipe"]]){$("#"+id).value=st[key];const out=$("#"+({"ai-strength":"ai-out","fx-strength":"fx-out","saturation":"sat-out","wipe":"wipe-out"})[id]);out.textContent=st[key]+"%";}
        if(!paused)$("#pause-top").textContent="▮▮";
    $$("[data-view]").forEach(b=>b.classList.toggle("active",b.dataset.view===st.view));
    if(!paused)$("#pending-note").hidden=true;
    if(Array.isArray(st.keep_box)){
      const hex="#"+st.keep_box.slice(0,1).concat().map(()=>0)&&"";
      const r=Math.round((st.keep_box[0]+st.keep_box[1])/2),g=Math.round((st.keep_box[2]+st.keep_box[3])/2),b=Math.round((st.keep_box[4]+st.keep_box[5])/2);
      document.getElementById("keep-color-pick").value="#"+[r,g,b].map(v=>v.toString(16).padStart(2,"0")).join("");
    }
    $("#wipe-row").style.opacity=st.view==="wipe"?1:.35;
    refreshBusy();updateSourceUI();
  }
  function setTrace(rows){const list=$("#trace-list");list.replaceChildren();(rows||[]).forEach(t=>{const row=document.createElement("div");row.className="trace-item";const ok=document.createElement("span");ok.className="trace-check";ok.textContent="✓";const box=document.createElement("span"),b=document.createElement("b"),small=document.createElement("small");b.textContent=t;small.textContent="软件语义模拟 · 状态版本校验";box.append(b,small);row.append(ok,box);list.append(row);});}
  function showUart(u){const o=$("#uart-output");if(!u){o.textContent="此操作没有 UART 映射帧。";return;}const lines=(u.frames||[]).map(f=>`${f.type} · ${f.bytes} bytes\n${f.hex}`);if(u.unmapped?.length)lines.push("待适配参数: "+u.unmapped.join(", "));lines.push(u.note);o.textContent=lines.join("\n");}
  function chatMessage(text,type="assistant",detail=""){const row=document.createElement("div");row.className="message "+type;if(type!=="user"){const icon=document.createElement("span");icon.className="bot-avatar";icon.textContent=type==="error"?"!":">";row.append(icon);}const b=document.createElement("div");b.className="bubble";const p=document.createElement("p");p.textContent=text;b.append(p);if(detail){const sm=document.createElement("small");sm.textContent=detail;b.append(sm);}row.append(b);$("#chat-body").append(row);$("#chat-body").scrollTop=$("#chat-body").scrollHeight;}
  function refreshBusy(){
    const known=!!snapshot?.state_known,disabled=busy||!known;
    $$(".control-grid button,.control-grid input,.control-grid select,.quick-controls button,.quick-controls input,.quick-controls select,.preview-actions button,#chat-input,#send,.lut-card,.style-chip,.mode-btn,.scene-btn").forEach(e=>e.disabled=disabled);
    $("#refresh-state").disabled=busy||!token; $("#settings-open").disabled=busy;
    $$("#settings input,#settings select,#settings button").forEach(e=>e.disabled=busy);
    $$(".suggestions button").forEach(e=>e.disabled=disabled);
    $("#pair-submit").disabled=busy;
    updateSourceUI();
  }
  async function refresh(){busy=true;refreshBusy();$("#sync-state").textContent="正在网关读回…";try{const s=await api("/api/refresh",{});syncState(s);setTrace(s.trace);toast("已从网关读取最新状态");}catch(e){if(!handleAuthError(e)){if(e.snapshot)syncState(e.snapshot);else syncState({state_known:false,state:null,mode:"deepseek",model:snapshot?.model,connected:snapshot?.connected,trace:["网关状态读回失败"]});toast(e.message);}}finally{busy=false;refreshBusy();}}
  $("#refresh-state").addEventListener("click",refresh);
  async function control(changes){if(busy||!snapshot?.state_known)return;busy=true;refreshBusy();try{const d=await api("/api/control",{revision:snapshot.revision,changes});syncState({...snapshot,state:d.state,revision:d.revision,state_known:true});setTrace(d.trace);showUart(d.uart);}catch(e){if(!handleAuthError(e)){if(e.snapshot)syncState(e.snapshot);else await refresh();toast(e.message);}}finally{busy=false;refreshBusy();}}

  /* ---------- 画面分析 → Agent 推荐 ---------- */
  function computeStats(){
    const d=sx.getImageData(0,0,SW,SH).data,n=SW*SH;
    let sum=0,sum2=0,satSum=0,rSum=0,bSum=0;
    const hist=new Array(16).fill(0),buckets=new Map();
    for(let i=0;i<n;i++){
      const r=d[i*4],g=d[i*4+1],bl=d[i*4+2];
      const l=.2126*r+.7152*g+.0722*bl;
      sum+=l;sum2+=l*l;hist[Math.min(15,l>>4)]++;
      const mx=Math.max(r,g,bl),mn=Math.min(r,g,bl);
      satSum+=mx===0?0:(mx-mn)/mx;
      rSum+=r;bSum+=bl;
      const key=((r>>5)*25+(g>>5)*5+(bl>>5));
      buckets.set(key,(buckets.get(key)||0)+1);
    }
    const mean=sum/n,std=Math.sqrt(Math.max(0,sum2/n-mean*mean));
    const top=[...buckets.entries()].sort((a,b)=>b[1]-a[1]).slice(0,4)
      .map(([key,cnt])=>({rgb:[(key/25|0)*32+16,(key/5%5|0)*32+16,(key%5)*32+16],ratio:+(cnt/n).toFixed(3)}));
    return {brightness_mean:+mean.toFixed(1),brightness_std:+std.toFixed(1),
            saturation_mean:+(satSum/n*255).toFixed(1),warmth:+((rSum-bSum)/(255*n)).toFixed(3),
            dominant_colors:top,histogram:hist.map(v=>+(v/n).toFixed(4))};
  }
  function updateScenePanel(stats){
    if(!stats)return;
    const set=(bar,out,frac,txt)=>{$("#"+bar).style.width=(Math.max(0,Math.min(1,frac))*100).toFixed(1)+"%";$("#"+out).textContent=txt;};
    set("m-bright","m-bright-v",stats.brightness_mean/255,Math.round(stats.brightness_mean));
    set("m-contrast","m-contrast-v",stats.brightness_std/128,Math.round(stats.brightness_std));
    set("m-sat","m-sat-v",stats.saturation_mean/255,Math.round(stats.saturation_mean));
    const w=stats.warmth||0;
    $("#m-warm").style.left=(w>=0?50:50+w*50)+"%";$("#m-warm").style.width=Math.abs(w)*50+"%";
    $("#m-warm-v").textContent=(w>0?"+":"")+w.toFixed(2);
    const row=$("#scene-swatches");row.replaceChildren();
    (stats.dominant_colors||[]).slice(0,4).forEach(c=>{
      const hex="#" + c.rgb.map(v=>v.toString(16).padStart(2,"0")).join("");
      const chip=document.createElement("span");chip.className="scene-chip";
      const dot=document.createElement("i");dot.style.background=hex;
      const t=document.createElement("small");t.textContent=hex+" · "+Math.round(c.ratio*100)+"%";
      chip.append(dot,t);row.append(chip);
    });
    $("#scene-panel-state").textContent="已更新";
  }
  async function sendChat(text, image=null, display=null){
    if(!text||busy||!snapshot?.state_known)return false;
    chatMessage(display||text,"user");busy=true;refreshBusy();$("#send").textContent="…";
    try{
      const body={text,revision:snapshot.revision};
      if(image)body.image=image;
      const d=await api("/api/chat",body);
      chatMessage(d.plan.reply,"assistant",Object.keys(d.plan.changes||{}).length?`模拟状态已更新 · r${d.execution.revision}`:"没有参数变更");
      syncState(d.snapshot);setTrace(d.execution.trace);showUart(d.execution.uart);
      return true;
    }catch(err){
      chatMessage(err.message,"error","云端请求未完成；未应用任何参数。");
      if(!handleAuthError(err)){if(err.snapshot)syncState(err.snapshot);else await refresh();toast(err.message);}
      return false;
    }finally{busy=false;$("#send").textContent="↑";refreshBusy();}
  }
  async function sceneAnalyze(){
    if(busy)return;
    let bmp;
    try{ bmp=await grabBitmap(); }catch(e){ toast("画面尚未就绪"); return; }
    sx.drawImage(bmp,0,0,SW,SH);
    const small=document.createElement("canvas");
    small.width=480;small.height=Math.max(1,Math.round(480*source.height/source.width));
    small.getContext("2d").drawImage(bmp,0,0,small.width,small.height);
    bmp.close();
    updateScenePanel(computeStats());
    const image=small.toDataURL("image/jpeg",0.7);
    $("#scene-status").textContent="云端分析中…";
    const ok=await sendChat("请分析当前画面，说明亮度/对比/冷暖/主色，并推荐 1-2 个适合的风格组合和理由；如果合适可以直接应用最推荐的一个。", image, "分析当前画面");
    $("#scene-status").textContent=ok?"已分析":"分析失败";
  }
  $("#scene-analyze").addEventListener("click",sceneAnalyze);
  $("#chat-form").addEventListener("submit",async e=>{e.preventDefault();const field=$("#chat-input"),text=field.value.trim();if(!text)return;field.value="";await sendChat(text);});
  $("#chat-input").addEventListener("keydown",e=>{if(e.key==="Enter"&&!e.shiftKey){e.preventDefault();$("#chat-form").requestSubmit();}});

  async function realAction(action){
    if(busy)return;
    const log=document.getElementById((action.startsWith("model")||action.startsWith("ai_"))?"model-log":"lut-log");
    if(log)log.textContent="TX · "+action+" · 等 A 回执";
    busy=true;refreshBusy();
    try{
      const r=await api("/api/real-action",{action});
      if(log)log.textContent=r.ok?`LAST · ${action} · A ACCEPTED`:`FAIL · ${action} · ${String(r.err||r.state||"UNKNOWN").slice(0,40)}`;
      toast(r.ok?`板1 已接收：${action}`:`板1 未接收：${r.err||r.state||"未知"}`);
    }catch(e){
      if(log)log.textContent="FAIL · "+action+" · LINK ERROR";
      toast("真实控制失败："+e.message);
    }
    finally{busy=false;refreshBusy();}
  }
  $$("[data-real-action]").forEach(b=>b.addEventListener("click",()=>realAction(b.dataset.realAction)));
  $("#keep-color").addEventListener("change",()=>realAction("keep_toggle"));
  $("#wave-source").addEventListener("change",e=>realAction("wave_set_"+e.target.value));
  function keepBoxFromUI(){
    const hex=document.getElementById("keep-color-pick").value;
    const t=Number(document.getElementById("keep-tol").value);
    const r=parseInt(hex.slice(1,3),16),g=parseInt(hex.slice(3,5),16),b=parseInt(hex.slice(5,7),16);
    const cl=v=>Math.max(0,Math.min(255,v));
    return [cl(r-t),cl(r+t),cl(g-t),cl(g+t),cl(b-t),cl(b+t)];
  }
  let keepTimer=null;
  function keepBoxChanged(){
    clearTimeout(keepTimer);
    keepTimer=setTimeout(()=>{ if(snapshot?.state_known) control({keep_box:keepBoxFromUI()}); },250);
  }
  $("#keep-color-pick").addEventListener("change",()=>{keepBoxChanged();});
  $("#keep-tol").addEventListener("input",e=>{$("#keep-tol-out").textContent=e.target.value;});
  $("#keep-tol").addEventListener("change",keepBoxChanged);
  $("#video-mode").addEventListener("change",e=>realAction("video_mode_"+e.target.selectedIndex));
  for(const [id,key] of [["ai-strength","ai_strength"],["fx-strength","fx_strength"],["saturation","saturation"],["wipe","wipe"]])$("#"+id).addEventListener("input",e=>{$("#"+({"ai-strength":"ai-out","fx-strength":"fx-out","saturation":"sat-out","wipe":"wipe-out"})[id]).textContent=e.target.value+"%";});
  for(const [id,key] of [["ai-strength","ai_strength"],["fx-strength","fx_strength"],["saturation","saturation"],["wipe","wipe"]])$("#"+id).addEventListener("change",e=>{
    if(id==="ai-strength"||id==="fx-strength")realAction((id==="ai-strength"?"ai_set_":"fx_set_")+Number(e.target.value));
    else control({[key]:Number(e.target.value)});
  });
  const togglePause=()=>setPaused(!paused);$("#pause-top").addEventListener("click",togglePause);
  $("#reset").addEventListener("click",()=>control({style:"vangogh",effect:"direct",color:"curve",curve:"identity",view:"wipe",video_mode:"480p30",ai_strength:100,fx_strength:100,saturation:100,wipe:50,paused:false}));
  const dlg=$("#settings");$("#settings-open").addEventListener("click",()=>dlg.showModal());dlg.addEventListener("close",()=>{$("#api-key").value="";});
  $("#save-settings").addEventListener("click",async e=>{e.preventDefault();if(busy)return;busy=true;refreshBusy();try{const s=await api("/api/settings",{mode:"deepseek",model:$("#model").value,api_key:$("#api-key").value});syncState(s);dlg.close();toast("连接设置已保存");}catch(err){if(!handleAuthError(err))toast(err.message);}finally{busy=false;refreshBusy();}});
  $("#clear-key").addEventListener("click",async()=>{if(busy)return;busy=true;refreshBusy();try{const s=await api("/api/settings",{mode:"deepseek",model:$("#model").value,clear_key:true});syncState(s);$("#api-key").value="";toast("服务端 Key 已清除");}catch(err){if(!handleAuthError(err))toast(err.message);}finally{busy=false;refreshBusy();}});
  // 聊天卡与预览卡等高（底部对齐）；窄屏恢复自然高度
  function syncChatHeight(){
    const p=document.querySelector(".preview-card"),c=document.querySelector(".chat-card");
    if(!p||!c)return;
    if(innerWidth<=780){c.style.height="";return;}
    c.style.height=p.offsetHeight+"px";
  }
  new ResizeObserver(syncChatHeight).observe(document.querySelector(".preview-card"));
  addEventListener("resize",syncChatHeight);syncChatHeight();
  updateSourceUI();
  refresh();   // 配对已移除：打开即用
})();
