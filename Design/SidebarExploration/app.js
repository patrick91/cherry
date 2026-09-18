const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icon = (name, cls='') => `<span class="icon ${cls}" style="--icon:url(assets/${name}.svg)" aria-hidden="true"></span>`;
const button = (action, text, cls='', attrs='') => `<button type="button" data-action="${action}" class="${cls}" ${attrs}>${text}</button>`;
let nextID = 100;
let variant = new URLSearchParams(location.search).get('layout') === 'outline' ? 'outline' : 'focused';
let scenario = new URLSearchParams(location.search).get('state') || 'working';
if (![...$('#scenario').options].some(o=>o.value === scenario)) scenario = 'working';
let projects, activeProject, selected, menuOpen=false, mobileOpen=false, remoteOnline=false;
let expandedProjects = new Set(['cherry','fizzup']);
let toolsExpanded = {commands:false,notes:false};
const folderLabel=(p,id)=>{const f=p.folders.find(f=>f.id===id);return !f?'Choose folder':p.folders.filter(x=>x.name===f.name).length>1?f.path:f.name;};
const project = () => projects.find(p=>p.id===activeProject);
const allTerminals = p => p.folders.flatMap(f=>f.terminals);
const makeTerminal = (id,title,program,status='ready',extra={}) => ({id,title,program,status,output:[],...extra});
function fixture() {
  return [
    {id:'cherry',name:'Cherry',location:'This Mac',folders:[
      {id:'app',name:'app',path:'~/Code/cherry',expanded:true,terminals:[makeTerminal('sidebar','Rethink the sidebar','Codex','working'),makeTerminal('shell','Shell','zsh'),makeTerminal('tests','Test suite','swift','ready',{command:'swift test --no-parallel'})]},
      {id:'website',name:'website',path:'~/Code/cherry-website',expanded:true,terminals:[makeTerminal('homepage','Homepage polish','Claude','attention')]},
      {id:'docs',name:'docs',path:'~/Code/cherry-docs',expanded:false,terminals:[]}
    ],commands:[{id:'dev',name:'Start website',folder:'website',command:'npm run dev'},{id:'check',name:'Check app',folder:'app',command:'swift test --no-parallel'}],notes:[{id:'ideas',title:'Sidebar ideas',text:'A place for the whole project.\n\nFolders hold terminals. A shell, an agent, or a running server all live in the same list.\n\nCommands know where they run. Notes stay with the project.\n\nThings to try\n• Close the last terminal in a folder\n• Add a second folder\n• Move between two projects'}]},
    {id:'fizzup',name:'fizzup.club',location:'This Mac',folders:[{id:'fizz-web',name:'website',path:'~/Code/fizzup.club',expanded:true,terminals:[makeTerminal('fizz-shell','Shell','zsh')]}],commands:[],notes:[]},
    {id:'personal',name:'Personal',location:'This Mac',folders:[{id:'scripts',name:'scripts',path:'~/Code/scripts',expanded:true,terminals:[]}],commands:[],notes:[]}
  ];
}
function loadScenario(value) {
  scenario=value; projects=fixture(); activeProject='cherry'; selected={type:'terminal',id:'sidebar',folder:'app'};menuOpen=false;mobileOpen=false;remoteOnline=false;expandedProjects=new Set(['cherry','fizzup']);
  if(value==='no-projects'){projects=[];activeProject=null;selected=null;}
  if(value==='empty-project'){projects=[projects[0]];projects[0].folders=[];projects[0].commands=[];projects[0].notes=[];selected=null;}
  if(value==='empty-folder'||value==='single'){
    projects=[projects[0]];projects[0].folders=[projects[0].folders[0]];projects[0].commands=[];projects[0].notes=[];
    projects[0].folders[0].terminals=value==='single'?[makeTerminal('fresh','Shell','zsh')]:[];
    selected=value==='single'?{type:'terminal',id:'fresh',folder:'app'}:{type:'folder',id:'app'};
  }
  if(value==='nothing-open') selected=null;
  if(value==='no-commands'){projects[0].commands=[];selected={type:'commands'};}
  if(value==='no-notes'){projects[0].notes=[];selected={type:'notes'};}
  if(value==='missing'){projects[0].folders[2].expanded=true;projects[0].folders[2].missing=true;selected={type:'folder',id:'docs'};}
  if(value==='remote'){projects=[projects[0]];projects[0].location='patmini';projects[0].remote=true;selected=null;}
  toolsExpanded={commands:value==='no-commands',notes:value==='no-notes'};$('#scenario').value=scenario;syncURL();render();
}
function syncURL(){try{history.replaceState(null,'',`?layout=${variant}&state=${scenario}`);}catch{/* Some file previews disallow URL updates; controls still work. */}}
function announce(text){$('#announcement').textContent=text;}
function setProject(id){activeProject=id;expandedProjects.add(id);selected=null;menuOpen=false;render();}
function renderProjectPicker(){
  const p=project();
  return `<div class="project-switch">${button('project-menu',`<span class="project-monogram">${p?esc(p.name[0]):'C'}</span><div class="project-label"><span class="project-name">${esc(p?.name || 'Your projects')}</span><div class="project-location">${p?`${icon('computer-desktop')}${esc(p.location)}`:'Make room for something new'}</div></div>${icon('chevron-down')}`,'project-button',`aria-expanded="${menuOpen}" aria-label="Switch project"`)}${menuOpen?`<div class="project-list" aria-label="Projects">${projects.map(p=>button('select-project',`<span class="menu-copy">${esc(p.name)}<small>${esc(p.location)} · ${p.folders.length} folder${p.folders.length!==1?'s':''}</small></span>${p.id===activeProject?icon('check'):''}`,'',`data-id="${p.id}"`)).join('')}${button('create-project','New project…','new-project')}</div>`:''}</div>`;
}
function renderFolder(f,p){
 const isOffline=p.remote&&!remoteOnline;
 return `<section class="folder" aria-label="${esc(f.name)} folder"><div class="folder-heading">${button('toggle-folder',icon(f.expanded?'chevron-down':'chevron-right','chevron'),'folder-disclosure',`data-id="${f.id}" data-project="${p.id}" aria-label="Toggle ${esc(f.name)} folder" aria-expanded="${f.expanded}"`)}${button('select-folder',`${icon('folder','folder-icon')}<span class="name">${esc(f.name)}</span><span class="folder-count">${f.terminals.length||''}</span>`,'folder-button',`data-id="${f.id}" data-project="${p.id}" ${selected?.type==='folder'&&selected.id===f.id?'aria-current="true"':''}`)}${button('launch',icon('plus'),'add-terminal',`data-folder="${f.id}" data-project="${p.id}" aria-label="Open terminal in ${esc(f.name)}" ${f.missing||isOffline?'disabled':''}`)}</div>${f.expanded?`<div class="terminals">${f.missing?`<div class="warning-row">${icon('exclamation-circle')}Folder unavailable</div>`:f.terminals.length?f.terminals.map(t=>`<div class="terminal-row ${selected?.type==='terminal'&&selected.id===t.id?'selected':''}">${button('select-terminal',`<span class="dot ${isOffline?'ready':t.status}" title="${isOffline?'Connection unavailable':t.status==='working'?'Working':t.status==='attention'?'Needs attention':'Ready'}" aria-hidden="true"></span><span class="terminal-title">${esc(t.title)}</span><span class="program">${esc(t.program)}</span>`,'terminal-button',`data-id="${t.id}" data-folder="${f.id}" data-project="${p.id}" aria-label="${esc(t.title)}, ${esc(t.program)}, ${isOffline?'offline':t.status==='attention'?'needs attention':t.status}" ${selected?.id===t.id?'aria-current="true"':''}`)}${button('close-terminal',icon('x-mark'),'close',`data-id="${t.id}" data-folder="${f.id}" data-project="${p.id}" aria-label="Close ${esc(t.title)}" ${isOffline?'disabled':''}`)}</div>`).join(''):button('launch',`${icon('plus')}Open terminal`,'inline-empty',`data-folder="${f.id}" data-project="${p.id}" ${isOffline?'disabled':''}`)}</div>`:''}</section>`;
}
function renderTree(){
 if(!projects.length)return `<div class="empty-sidebar">${button('create-project',`${icon('plus')}Create project`)}<p>Keep related folders and terminals together.</p></div>`;
 if(variant==='focused'){
   const p=project();return `${p.folders.map(f=>renderFolder(f,p)).join('')}${button('add-folder',`${icon('folder-plus')}Add folder…`,'add-folder',`${p.remote&&!remoteOnline?'disabled':''}`)}`;
 }
 return projects.map(p=>`<section class="project-group" aria-label="${esc(p.name)} project"><div class="project-heading ${p.id===activeProject?'active':''}">${button('toggle-project',icon(expandedProjects.has(p.id)?'chevron-down':'chevron-right'),'project-disclosure',`data-id="${p.id}" aria-label="Toggle ${esc(p.name)} project" aria-expanded="${expandedProjects.has(p.id)}"`)}${button('outline-project',`<span class="label">${esc(p.name)}</span><span class="count">${allTerminals(p).length||''}</span>`,'project-group-button',`data-id="${p.id}"`)}</div>${expandedProjects.has(p.id)?`<div class="project-contents">${p.folders.map(f=>renderFolder(f,p)).join('')}${button('add-folder',`${icon('folder-plus')}Add folder…`,'add-folder',`data-project="${p.id}" ${p.remote&&!remoteOnline?'disabled':''}`)}</div>`:''}</section>`).join('');
}
function renderTools(){
 const p=project();if(!p)return '';
 const offline=p.remote&&!remoteOnline;
 const headings=(key,label,count,add)=>`<div class="tool-heading">${button('toggle-tools',`${icon(key==='commands'?'play':'document-text')}<strong>${label}</strong><span class="count">${count||''}</span>${icon(toolsExpanded[key]?'chevron-down':'chevron-right')}`,'tool-toggle',`data-id="${key}" aria-expanded="${toolsExpanded[key]}" aria-label="Show ${label.toLowerCase()}"`)}${button(add,icon('plus'),'',`aria-label="Add ${key==='commands'?'command':'note'}" ${offline||(key==='commands'&&!p.folders.length)?'disabled':''}`)}</div>`;
 const commandRows=p.commands.length?p.commands.map(c=>button('run-command',`<span>${esc(c.name)}</span><span class="target">${esc(folderLabel(p,c.folder))}</span>`,'tool-row',`data-id="${c.id}" title="${esc(folderLabel(p,c.folder))}" aria-label="Run ${esc(c.name)} in ${esc(folderLabel(p,c.folder))}" ${offline?'disabled':''}`)).join(''):button('add-command',p.folders.length?'Add a command…':'Add a folder to set up commands','inline-empty',`${!p.folders.length||offline?'disabled':''}`);
 const noteRows=p.notes.length?p.notes.map(n=>button('select-note',esc(n.title),'tool-row '+(selected?.type==='note'&&selected.id===n.id?'selected':''),`data-id="${n.id}" ${offline?'disabled':''}`)).join(''):button('add-note','Write a note…','inline-empty',`${offline?'disabled':''}`);
 return `<div class="tools"><div class="tools-caption">For ${esc(p.name)}</div><section class="tool-group" aria-label="Project commands">${headings('commands','Commands',p.commands.length,'add-command')}${toolsExpanded.commands?commandRows:''}</section><section class="tool-group" aria-label="Project notes">${headings('notes','Notes',p.notes.length,'add-note')}${toolsExpanded.notes?noteRows:''}</section></div>`;
}
function empty(title,copy,actions,hint=''){
 return `<div class="empty"><img class="empty-mark" src="assets/cherry.png" alt="" width="58" height="58"><h2>${title}</h2><p>${copy}</p><div class="actions">${actions}</div>${hint?`<p class="hint">${hint}</p>`:''}</div>`;
}
function renderContent(){
 const p=project();
 if(!p)return empty('A place to begin.','Bring your folders, terminals, and ideas together in a project.',button('create-project','Create project','primary'),'A project can start with a single folder.');
 if(p.remote&&!remoteOnline)return empty('Your project is still here.','Cherry can’t reach patmini. Reconnect to check on your terminals.',button('reconnect','Reconnect','primary'),'Future concept · No connection is made in this prototype.');
 if(selected?.type==='note'){
   const note=p.notes.find(n=>n.id===selected.id);return `<article class="note-editor"><div class="note-meta">${esc(p.name)} / Notes</div><h2>${esc(note.title)}</h2><label class="sr-only" for="note-body">Note content</label><textarea id="note-body" name="note-content" data-note="${note.id}" spellcheck="false">${esc(note.text)}</textarea></article>`;
 }
 if(selected?.type==='commands')return empty('Keep a good command handy.','Save a command and choose its folder. Its output opens as a terminal.',button('add-command','Add command','primary'));
 if(selected?.type==='notes')return empty('A thought worth keeping.','Notes belong to this project, so they stay with you as you move between folders.',button('add-note','Write a note','primary'));
 if(!p.folders.length)return empty(`${esc(p.name)} starts here.`,'Add the folders you want to work in. They can be repositories or any other directories.',button('add-folder','Add folder','primary'),'Commands and notes will stay with this project.');
 const f=p.folders.find(f=>f.id===(selected?.folder||selected?.id));
 if(f?.missing)return empty('This folder is unavailable.',`Cherry can’t find ${esc(f.path)}. Choose its new location to keep working.`,button('locate-folder','Locate folder…','primary',`data-folder="${f.id}"`),'The folder stays in your project.');
 if(selected?.type==='terminal'){
   const t=f?.terminals.find(t=>t.id===selected.id);if(t)return renderTerminal(t,f);
 }
 if(f&&!f.terminals.length)return empty(`Open a terminal in ${esc(f.name)}.`,'Start a shell, run an agent, or try a command. They all belong here.',button('launch','Open terminal','primary',`data-folder="${f.id}"`),esc(f.path));
 if(!allTerminals(p).length)return empty('Ready when you are.','Choose a folder and open your first terminal.',button('launch','Open terminal','primary',`data-folder="${p.folders[0].id}"`));
 return empty('A little room to think.','Choose a terminal from the sidebar, or open a new one.',button('launch','Open terminal','primary',`data-folder="${f?.id||p.folders[0].id}"`),`${allTerminals(p).length} terminals in ${esc(p.name)} · Your work stays in the sidebar.`);
}
function renderTerminal(t,f){
 let content='';
 if(t.program==='Codex')content=`<div class="greeting">Let’s give the sidebar some space.</div><p class="muted">Codex · ${esc(f.path)}</p><div class="terminal-divider"></div><pre><span class="accent">›</span> Explore a project made of folders, with terminals inside.\n\n  I’ll start with the everyday workflow, then work through\n  the empty states.\n\n  <span class="success">✓</span> Read the current sidebar\n  <span class="success">✓</span> Sketch the project and folder hierarchy\n  <span class="muted">•</span> Explore what happens when the last terminal closes</pre>`;
 else if(t.program==='Claude')content=`<div class="greeting">Homepage polish</div><p class="muted">Claude · ${esc(f.path)}</p><div class="terminal-divider"></div><pre>The first pass is ready.\n\nI’ve tightened the spacing and simplified the navigation.\n\n<span class="accent">›</span> Would you like to review the changes?</pre>`;
 else if(t.command)content=`<pre><span class="muted">${esc(f.path)}</span>\n<span class="accent">❯</span> ${esc(t.command)}\n\n${t.command.includes('swift')?'<span class="success">Build complete.</span>\nTest Suite passed.':'<span class="success">Ready.</span>\nLocal preview: http://localhost:3000'}\n\n<span class="muted">Sample output for this design prototype.</span></pre>`;
 else content=`<pre><span class="muted">${esc(f.path)}</span></pre>`;
 return `<section class="terminal" aria-label="${esc(t.title)} terminal preview"><div class="terminal-meta"><span class="type">${esc(t.program)}</span><span>${esc(f.name)}</span><span>${esc(project().location)}</span></div>${content}<div class="output">${t.output.map(x=>`<pre>${esc(x)}</pre>`).join('')}</div><form class="terminal-form" id="terminal-form"><label for="terminal-input">❯</label><input type="text" id="terminal-input" name="terminal-input" aria-label="Simulated terminal input" autocomplete="off" spellcheck="false"></form><p class="demo-hint">Preview terminal · Try “pwd” or “ls”. No commands are executed.</p></section>`;
}
function render(){
 const p=project(), f=p?.folders.find(f=>f.id===(selected?.folder||selected?.id));
 const t=selected?.type==='terminal'?f?.terminals.find(t=>t.id===selected.id):null;
 const note=selected?.type==='note'?p?.notes.find(n=>n.id===selected.id):null;
 const title=t?.title||note?.title|| (selected?.type==='commands'?'Commands':selected?.type==='notes'?'Notes':f?.name||p?.name||'Cherry');
 document.querySelectorAll('[data-variant]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.variant===variant));
 $('#direction-label').textContent=variant==='focused'?'A / Focused project · Recommended starting point':'B / Project outline';
 $('#direction-note').textContent=variant==='focused'?'One project at a time. The switcher holds your projects; the sidebar gives its folders room. A good fit for longer stretches of focused work.':'Keep several projects expanded at once. Select a folder or terminal to switch context; commands and notes follow the active project. More visibility, with a little more nesting.';
 $('#app').className=`app-window ${variant} ${mobileOpen?'mobile-open':''}`;
 $('#app').innerHTML=`<aside class="sidebar" aria-label="Project sidebar"><div class="window-controls"><span class="traffic" aria-hidden="true"></span><span class="traffic" aria-hidden="true"></span><span class="traffic" aria-hidden="true"></span><span class="wordmark">cherry</span>${button('mobile-menu',icon('bars-3'),'side-toggle mobile-menu','aria-label="Close sidebar"')}</div>${variant==='focused'?renderProjectPicker():`<div class="outline-top"><h2>Projects</h2>${button('create-project',icon('plus'),'','aria-label="Create project"')}</div>`}<nav class="tree" aria-label="Folders and terminals">${renderTree()}</nav>${renderTools()}<div class="sidebar-foot">${icon('computer-desktop')}${esc(p?.location||'This Mac')}${p?.remote?` · ${remoteOnline?'Connected (preview)':'Offline'}`:''}</div></aside><main class="main"><header class="main-bar">${button('mobile-menu',icon('bars-3'),'mobile-menu','aria-label="Open sidebar"')}${t?icon('command-line'):note?icon('document-text'):icon('folder')}<span class="title">${esc(title)}</span>${t?`<span> / ${esc(f.name)}</span>`:''}<span class="spacer"></span><span class="location">${esc(t?f.path:p?.location||'')}</span>${selected?button('clear-selection',icon('x-mark'),'','aria-label="Clear selection"'):''}</header>${p?.remote?`<div class="remote-banner">${icon(remoteOnline?'check':'exclamation-circle')}<span>${remoteOnline?'Connected to patmini':'Connection to patmini lost'}</span><small>Future concept</small></div>`:''}<div class="content">${renderContent()}</div><footer class="statusbar">${t?`<span class="dot ${p.remote&&!remoteOnline?'ready':t.status}"></span><span class="${p.remote&&!remoteOnline?'':t.status}">${p.remote&&!remoteOnline?'Offline · Status unavailable':t.status==='attention'?'Needs your attention':t.status==='working'?'Working':'Ready'}</span>`:`<span>${esc(p?.name||'No project open')}</span>`}<span class="right">${p?`${p.folders.length} folder${p.folders.length===1?'':'s'} · ${allTerminals(p).length} terminals`:'Your work, in one place'}</span></footer></main>`;
}
function closeDialog(){ $('#editor').close();$('#editor').innerHTML='';}
function formDialog(title,description,fields,submit,onSubmit){
 const d=$('#editor');d.innerHTML=`<form id="edit-form"><h2 id="dialog-title">${title}</h2><p class="dialog-description">${description}</p>${fields}<div class="dialog-actions">${button('cancel','Cancel','secondary')}<button type="submit" class="primary">${submit}</button></div></form>`;
 $('#edit-form').addEventListener('submit',e=>{e.preventDefault();const data=new FormData(e.target);onSubmit(data);closeDialog();render();});d.showModal();
}
const field=(label,name,value='',placeholder='')=>`<label>${label}<input type="text" name="${name}" value="${esc(value)}" placeholder="${esc(placeholder)}" required></label>`;
function addTerminal(folderID,program){
 const p=project(),f=p.folders.find(f=>f.id===folderID);if(!f||f.missing)return;
 const id=`t${nextID++}`;const t=makeTerminal(id,program==='zsh'?'Shell':program,program,program==='zsh'?'ready':'working');f.terminals.push(t);f.expanded=true;selected={type:'terminal',id,folder:f.id};mobileOpen=false;announce(`Opened ${t.title} in ${f.name}.`);render();
}
document.addEventListener('click',e=>{
 const v=e.target.closest('[data-variant]');if(v){variant=v.dataset.variant;menuOpen=false;syncURL();render();return;}
 const b=e.target.closest('[data-action]');if(!b)return;
 const a=b.dataset.action;
 if(a==='cancel'){closeDialog();return;}
 if(a==='project-menu'){menuOpen=!menuOpen;render();return;}
 if(a==='select-project'||a==='outline-project'){setProject(b.dataset.id);return;}
 if(a==='toggle-project'){expandedProjects.has(b.dataset.id)?expandedProjects.delete(b.dataset.id):expandedProjects.add(b.dataset.id);render();return;}
 if(a==='mobile-menu'){mobileOpen=!mobileOpen;render();return;}
 if(a==='toggle-tools'){toolsExpanded[b.dataset.id]=!toolsExpanded[b.dataset.id];render();return;}
 if(a==='clear-selection'){selected=null;render();return;}
 if(a==='create-project'){
  formDialog('Create a project','A project keeps related folders, terminals, and notes together.',field('Project name','name','','e.g. Cherry'),'Create project',d=>{
   const id=`p${nextID++}`;projects.push({id,name:d.get('name').trim()||'Untitled',location:'This Mac',folders:[],commands:[],notes:[]});activeProject=id;expandedProjects.add(id);selected=null;menuOpen=false;announce('Project created. Add a folder next.');
  });return;
 }
 if(b.dataset.project&&a!=='toggle-folder'&&activeProject!==b.dataset.project){activeProject=b.dataset.project;selected=null;render();}
 const p=project();if(!p)return;
 if(a==='toggle-folder'){const f=projects.find(p=>p.id===b.dataset.project).folders.find(f=>f.id===b.dataset.id);f.expanded=!f.expanded;render();return;}
 if(a==='select-folder'){const f=p.folders.find(f=>f.id===b.dataset.id);f.expanded=true;selected={type:'folder',id:f.id};render();return;}
 if(a==='select-terminal'){selected={type:'terminal',id:b.dataset.id,folder:b.dataset.folder};mobileOpen=false;render();return;}
 if(a==='close-terminal'){
  const f=p.folders.find(f=>f.id===b.dataset.folder);f.terminals=f.terminals.filter(t=>t.id!==b.dataset.id);
  if(selected?.id===b.dataset.id)selected=f.terminals.length?{type:'terminal',id:f.terminals[0].id,folder:f.id}:{type:'folder',id:f.id};announce('Terminal closed in the prototype.');render();return;
 }
 if(a==='add-folder'||a==='locate-folder'){
  const existing=a==='locate-folder'?p.folders.find(f=>f.id===b.dataset.folder):null;
  formDialog(existing?'Locate folder':'Add a folder',existing?'Choose the updated location. This preview only changes its sample path.':'The native app would use a folder picker. Enter a sample path here; no files are accessed.',field('Folder path','path',existing?.path||'','~/Code/my-folder'),existing?'Use this folder':'Add folder',d=>{
   const path=d.get('path').trim();if(existing){existing.path=path;existing.missing=false;selected={type:'folder',id:existing.id};return;}
   const name=path.replace(/\/$/,'').split('/').pop()||'folder';const id=`f${nextID++}`;p.folders.push({id,name,path,expanded:true,terminals:[]});selected={type:'folder',id};announce(`Added ${name}.`);
  });return;
 }
 if(a==='launch'){
  const f=p.folders.find(f=>f.id===b.dataset.folder);if(!f)return;
  const d=$('#editor');d.innerHTML=`${button('cancel',icon('x-mark'),'launcher-close','aria-label="Cancel"')}<h2 id="dialog-title">Open a terminal</h2><p class="dialog-description">In ${esc(f.name)} · ${esc(f.path)}</p>${[['zsh','Shell','A plain terminal, ready for anything.'],['Codex','Codex','Start Codex in this folder.'],['Claude','Claude','Start Claude in this folder.']].map(([program,name,copy])=>button('launch-program',`${icon('command-line')}<span class="copy">${name}<small>${copy}</small></span>`,'launch-option',`data-program="${program}" data-folder="${f.id}"`)).join('')}`;d.showModal();return;
 }
 if(a==='launch-program'){closeDialog();addTerminal(b.dataset.folder,b.dataset.program);return;}
 if(a==='add-command'){
  if(!p.folders.length)return;
  formDialog('Save a command','Choose its folder once. Running it opens a terminal there.',field('Name','name','','e.g. Start server')+field('Command','command','','npm run dev')+`<label>Run in folder<select name="folder">${p.folders.map(f=>`<option value="${f.id}">${esc(folderLabel(p,f.id))}</option>`).join('')}</select></label>`,'Save command',d=>{toolsExpanded.commands=true;p.commands.push({id:`c${nextID++}`,name:d.get('name').trim(),command:d.get('command').trim(),folder:d.get('folder')});selected={type:'folder',id:d.get('folder')};announce('Command saved.');});return;
 }
 if(a==='run-command'){
  const c=p.commands.find(c=>c.id===b.dataset.id),f=p.folders.find(f=>f.id===c.folder);if(!f||f.missing){selected={type:'folder',id:c.folder};render();return;}
  let t=f.terminals.find(t=>t.commandID===c.id);if(!t){t=makeTerminal(`t${nextID++}`,c.name,c.command.split(' ')[0],'working',{command:c.command,commandID:c.id});f.terminals.push(t);}f.expanded=true;selected={type:'terminal',id:t.id,folder:f.id};mobileOpen=false;announce(`Showing ${c.name} in ${f.name}.`);render();return;
 }
 if(a==='add-note'){
  formDialog('Write a note',`Saved with ${esc(p.name)}, across all its folders.`,field('Title','title','','e.g. Release checklist'),'Create note',d=>{const id=`n${nextID++}`;toolsExpanded.notes=true;p.notes.push({id,title:d.get('title').trim(),text:''});selected={type:'note',id};mobileOpen=false;});return;
 }
 if(a==='select-note'){selected={type:'note',id:b.dataset.id};mobileOpen=false;render();return;}
 if(a==='reconnect'){remoteOnline=true;announce('Simulated connection restored.');render();return;}
});
document.addEventListener('input',e=>{if(e.target.matches('[data-note]')){const n=project().notes.find(n=>n.id===e.target.dataset.note);n.text=e.target.value;}});
document.addEventListener('submit',e=>{
 if(e.target.id!=='terminal-form')return;e.preventDefault();const value=$('#terminal-input').value.trim();if(!value)return;
 const f=project().folders.find(f=>f.id===selected.folder),t=f.terminals.find(t=>t.id===selected.id);t.output.push(`❯ ${value}`);
 t.output.push(value==='pwd'?f.path:value==='ls'?'Sources/  Tests/  README.md':value==='clear'?'':'This is a design preview; no command was executed.');if(value==='clear')t.output=[];render();$('#terminal-input')?.focus();
});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('#editor').open&&(menuOpen||mobileOpen)){menuOpen=false;mobileOpen=false;render();}});
$('#scenario').addEventListener('change',e=>loadScenario(e.target.value));
$('#reset').addEventListener('click',()=>loadScenario(scenario));
loadScenario(scenario);
