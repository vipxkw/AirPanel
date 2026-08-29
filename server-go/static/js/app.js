// 应用逻辑：登录、导航、设备列表、任务执行、任务记录、设置
(function () {
  'use strict';

  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => Array.from(document.querySelectorAll(sel));

  let currentPage = 'devices';
  let devices = [];

  // ---------------- 工具函数 ----------------

  function fmtTime(ts) {
    if (!ts) return '—';
    const d = new Date(ts * 1000);
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  let toastTimer = null;
  function toast(msg, ok = true) {
    const el = $('#toast');
    el.textContent = msg;
    el.className = 'fixed top-5 left-1/2 -translate-x-1/2 z-50 rounded-lg px-4 py-2.5 text-sm text-white shadow-lg ' +
      (ok ? 'bg-slate-800' : 'bg-red-600');
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.add('hidden'), 3000);
  }

  // ---------------- 登录 / 登出 ----------------

  async function handleLogin(e) {
    e.preventDefault();
    const username = $('#login-username').value.trim();
    const password = $('#login-password').value;
    const errEl = $('#login-error');
    errEl.classList.add('hidden');
    const btn = $('#login-btn');
    btn.disabled = true;
    btn.textContent = '登录中...';
    try {
      const data = await API.login(username, password);
      API.setToken(data.token);
      localStorage.setItem('panel_username', username);
      enterMain();
    } catch (err) {
      errEl.textContent = err.message;
      errEl.classList.remove('hidden');
    } finally {
      btn.disabled = false;
      btn.textContent = '登 录';
    }
  }

  async function handleLogout() {
    try { await API.logout(); } catch (_) { /* 忽略 */ }
    API.clearToken();
    showLogin();
  }

  function showLogin() {
    toggleSidebar(false);
    $('#main-view').classList.add('hidden');
    $('#login-view').classList.remove('hidden');
    $('#login-password').value = '';
  }

  function enterMain() {
    $('#login-view').classList.add('hidden');
    $('#main-view').classList.remove('hidden');
    const uname = localStorage.getItem('panel_username') || 'admin';
    $('#user-name').textContent = uname;
    $('#user-avatar').textContent = (uname.charAt(0) || 'U').toUpperCase();
    $('#m-user-name').textContent = uname;
    loadDevices();
    switchPage('devices');
  }

  // ---------------- 导航 ----------------

  // 移动端抽屉开关（内联样式避免依赖 Tailwind 未生成的工具类）
  function toggleSidebar(open) {
    const sb = $('#sidebar');
    sb.style.transform = open ? 'translateX(0)' : '';
    $('#sidebar-overlay').classList.toggle('hidden', !open);
  }

  function switchPage(name) {
    currentPage = name;
    $$('.page').forEach((s) => s.classList.toggle('hidden', s.id !== 'page-' + name));
    $$('.nav-item').forEach((a) => {
      const active = a.dataset.nav === name;
      a.classList.toggle('bg-slate-800', active);
      a.classList.toggle('text-white', active);
      a.classList.toggle('text-slate-300', !active);
    });
    if (name === 'devices') loadDevices();
    if (name === 'tasks') renderDeviceSelect();
    if (name === 'schedules') { renderSchDeviceSelect(); renderSchTaskSelect(); onSchCycleChange(); onSchTaskChange(); loadSchedules(); }
    if (name === 'logs') loadTasks();
    if (name === 'settings') {
      const uname = localStorage.getItem('panel_username') || 'admin';
      const cur = $('#set-current-username');
      if (cur) {
        cur.value = uname;
        $('#set-new-username').placeholder = '当前：' + uname;
      }
    }
  }

  // ---------------- 设备列表 ----------------

  async function loadDevices() {
    try {
      devices = await API.userPool();
      renderDevices();
      renderDeviceSelect();
    } catch (err) {
      $('#devices-tbody').innerHTML = `<tr><td colspan="7" class="px-4 py-10 text-center text-red-500">${esc(err.message)}</td></tr>`;
    }
  }

  function renderDevices() {
    const tbody = $('#devices-tbody');
    if (!devices.length) {
      tbody.innerHTML = '<tr><td colspan="7" class="px-4 py-10 text-center text-slate-400">暂无设备接入</td></tr>';
      return;
    }
    tbody.innerHTML = devices.map((d) => `
      <tr class="hover:bg-slate-50">
        <td class="px-4 py-3 font-mono text-slate-700">${esc(d.imei)}</td>
        <td class="px-4 py-3 text-slate-600">
          <div class="flex items-center gap-1.5 min-w-32">
            <span class="remark-name truncate max-w-28">${esc(d.name || '—')}</span>
            <button class="shrink-0 text-slate-400 hover:text-blue-600 transition-colors" data-remark="${esc(d.imei)}" title="设置备注">
              <svg xmlns="http://www.w3.org/2000/svg" class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"/></svg>
            </button>
          </div>
        </td>
        <td class="px-4 py-3 text-slate-600">${esc(d.phone || '—')}</td>
        <td class="px-4 py-3">${d.connected ? '<span class="badge-online">● 在线</span>' : '<span class="badge-offline">○ 离线</span>'}</td>
        <td class="px-4 py-3 text-slate-500">${fmtTime(d.firstSeen)}</td>
        <td class="px-4 py-3 text-slate-500">${fmtTime(d.lastSeen)}</td>
        <td class="px-4 py-3 text-right">
          <button class="btn btn-ghost !px-3 !py-1.5 text-xs" data-run="${esc(d.imei)}">执行任务</button>
        </td>
      </tr>`).join('');
  }

  // 内联编辑设备备注
  function startEditRemark(imei) {
    const dev = devices.find((d) => d.imei === imei);
    const td = document.querySelector(`[data-remark="${CSS.escape(imei)}"]`)?.closest('td');
    if (!td) return;
    td.innerHTML = `
      <div class="flex items-center gap-1">
        <input type="text" class="input !py-1 !px-2 text-xs min-w-32" maxlength="30" value="${esc(dev ? dev.name : '')}" placeholder="备注">
        <button class="shrink-0 text-emerald-600 hover:scale-110 transition" title="保存" data-remark-save="1">✓</button>
        <button class="shrink-0 text-slate-400 hover:text-red-500 transition" title="取消" data-remark-cancel="1">✕</button>
      </div>`;
    const input = td.querySelector('input');
    input.focus();
    input.select();

    const finish = async (save) => {
      if (save) {
        const name = input.value.trim();
        try {
          await API.updateDeviceRemark({ imei, name });
          if (dev) dev.name = name;
          renderDevices();
          toast(name ? '备注已保存' : '备注已清除');
        } catch (err) {
          renderDevices();
          toast(err.message, false);
        }
      } else {
        renderDevices();
      }
    };
    td.querySelector('[data-remark-save]').addEventListener('click', () => finish(true));
    td.querySelector('[data-remark-cancel]').addEventListener('click', () => finish(false));
    input.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter') finish(true);
      if (ev.key === 'Escape') finish(false);
    });
  }

  // ---------------- 任务执行 ----------------

  function renderDeviceSelect(selected) {
    const sel = $('#task-imei');
    const count = $('#task-device-count');
    if (!sel) return;
    if (!devices.length) {
      sel.innerHTML = '<option value="">暂无设备</option>';
      if (count) count.textContent = '0 台设备';
      return;
    }
    const online = devices.filter((d) => d.connected).length;
    sel.innerHTML = '<option value="">请选择设备</option>' + devices.map((d) =>
      `<option value="${esc(d.imei)}" ${d.imei === selected ? 'selected' : ''}>${d.name ? esc(d.name) + ' · ' : ''}${esc(d.imei)}（${esc(d.phone || '未知号码')}）${d.connected ? '' : ' [离线]'}</option>`).join('');
    if (selected) sel.value = selected;
    if (count) count.textContent = `${devices.length} 台设备 · ${online} 台在线`;
  }

  const TASK_LABELS = {
    get_temperature: '查询温度',
    send_sms: '发送短信',
    get_config: '读取配置',
    set_config: '写入配置',
  };

  // 命令详细说明（任务说明弹窗内容）
  const TASK_HELP = {
    get_temperature: {
      title: '查询温度',
      desc: '读取设备（Air724UG 模组）当前的芯片温度，用于远程监控设备运行状态。',
      params: [],
      result: '返回温度数值（摄氏度），如 <code class="font-mono">38.28</code>。温度异常偏高可能意味着供电或散热问题。',
      note: '无需任何参数，点击下方"下发任务"即可执行。设备必须在线。',
    },
    send_sms: {
      title: '发送短信',
      desc: '通过设备内置的 SIM 卡向外发送一条短信，收件方看到的是设备本机号码。',
      params: [
        ['rcv_phone', '接收手机号，如 13800138000'],
        ['content', '短信内容。中文每 70 字一条，超出自动拆分为长短信（计多条费用）'],
      ],
      result: '成功返回 <code class="font-mono">"短信发送成功"</code>；失败返回具体原因（如 AT 指令错误、短信中心未配置）。',
      note: '需设备 SIM 卡已注册网络且信号正常；短信费用由 SIM 卡套餐承担。',
    },
    get_config: {
      title: '读取配置',
      desc: '读取设备上的运行时配置文件 <code class="font-mono">/nvm_para.lua</code> 全文。该文件存放可远程修改的参数（通知渠道、MQTT 地址等），优先级高于编译进固件的 config.lua。',
      params: [],
      result: '返回 nvm_para.lua 的完整 Lua 源码文本。',
      note: '如需修改，先读取当前配置作为底稿，改好后用"写入配置"写回，避免覆盖丢失其他参数。',
    },
    set_config: {
      title: '写入配置',
      desc: '用提交的 Lua 配置文本<b>整体覆盖</b>设备的 <code class="font-mono">/nvm_para.lua</code>，并立即生效（无需重启）。',
      params: [
        ['configText', '完整的 Lua 配置源码，必须以 <code class="font-mono">module(..., package.seeall)</code> 开头的合法 Lua 文件'],
      ],
      result: '成功返回 <code class="font-mono">{"success": true}</code>；语法错误时返回解析失败原因（此时不会写入文件）。',
      note: '覆盖式写入！建议先执行"读取配置"拿到当前内容再修改提交，避免遗漏参数。写入失败（如断电）可能导致文件丢失，需重刷脚本恢复。',
    },
    get_status: {
      title: '查询状态',
      desc: '一次性汇总设备的运行状态：电压、温度、信号强度（RSSI/RSRP）、运营商、本机号码、当前 SIM 卡槽、网络注册状态。',
      params: [],
      result: '返回 JSON，如 <code class="font-mono">{"voltage":3856,"temperature":38.28,"rssi":25,"operator":"中国电信",...}</code>。电压单位 mV；RSSI 范围 0-31，越大信号越好。',
      note: '无需参数。适合放在首页定期轮询，作为设备健康巡检。',
    },
    dial_call: {
      title: '拨打电话',
      desc: '通过设备 SIM 卡向外拨打电话。可用于触发目标手机的来电提醒（免打通话的变相通知方式）。',
      params: [
        ['phone', '被叫号码，如 13800138000'],
      ],
      result: '返回 <code class="font-mono">"拨打指令已执行: xxx"</code>。通话最长 300 秒自动挂断，可配合"挂断通话"提前结束。',
      note: '按运营商通话资费计费。通话期间设备会暂停音频播放。',
    },
    hang_up: {
      title: '挂断通话',
      desc: '挂断设备当前正在进行中的通话。',
      params: [],
      result: '有通话时返回 <code class="font-mono">"挂断指令已执行"</code>；无通话时返回 <code class="font-mono">"当前无通话"</code>。',
      note: '无需参数。常与"拨打电话"配合使用：拨通对方接听后（或响铃数秒后）挂断。',
    },
    tts_speak: {
      title: '语音播报',
      desc: '让设备扬声器用 TTS 朗读一段中文文本，适合远程寻人、现场提醒等场景。',
      params: [
        ['text', '要朗读的文本，如 "快递已到，请下楼取件"'],
      ],
      result: '返回 <code class="font-mono">"TTS 播报已执行"</code>。播报音量跟随设备当前音量设置。',
      note: '通话进行中不会播放；设备音量为 0 时静音。可用"设置音量"命令先调高音量。',
    },
    set_volume: {
      title: '设置音量',
      desc: '同时设置设备的扬声器音量与通话音量（写入 nvm_para.lua 持久保存）。',
      params: [
        ['vol', '音量值，0-10 的整数。0 为静音'],
      ],
      result: '返回 <code class="font-mono">"音量已设置为 N"</code>。设置即时生效且重启后保留。',
      note: '音量为 0 会同时静音扬声器与通话（通话录音无声）。通话中调节会即时生效。',
    },
    query_traffic: {
      title: '查询流量',
      desc: '按当前 SIM 卡运营商自动发送流量查询短信（移动发 10086、联通发 10010、电信发 10001）。运营商回复短信后，会自动触发通知推送。',
      params: [],
      result: '返回 <code class="font-mono">"流量查询短信已发送，运营商回复将推送通知"</code>，实际流量数据在回复短信里。',
      note: '消耗一条普通短信费用。广电卡不支持自动查询代码。',
    },
    set_ccfc: {
      title: '设置呼转',
      desc: '设置无条件呼叫转移：所有来电转接到指定号码。传 <code class="font-mono">phone=0</code> 则取消所有呼转。',
      params: [
        ['phone', '呼转目标号码（5 位以上）；传 0 取消呼转'],
      ],
      result: '返回 <code class="font-mono">"呼转指令已下发: xxx"</code>。指令为异步下发，运营商生效结果以通知推送为准。',
      note: '呼转生效后设备不再振铃，来电全部转接。取消时传 phone=0。',
    },
    switch_sim: {
      title: '切换SIM',
      desc: '在主/副卡槽之间切换 SIM 卡，设备将在 10 秒后自动重启使切换生效（与短信指令 SIMSWITCH 行为一致）。',
      params: [],
      result: '返回 <code class="font-mono">"切换SIM: 主卡槽 -> 副卡槽, 10秒后重启生效"</code>（方向视当前卡槽而定）。',
      note: '设备会重启，期间 MQTT 短暂离线属正常现象。重启后约 1-2 分钟恢复在线。',
    },
    reboot: {
      title: '重启设备',
      desc: '远程重启设备（软重启），用于排除运行异常、恢复网络注册等。设备将在 10 秒后执行重启。',
      params: [],
      result: '返回 <code class="font-mono">"重启指令已接收, 10秒后重启"</code>，之后设备离线再自动恢复上线。',
      note: '重启期间设备约 1-2 分钟离线。频繁重启请先排查供电稳定性（劣质充电器会导致反复重启）。',
    },
    get_device_info: {
      title: '设备信息',
      desc: '读取设备硬件标识：IMEI（模块串号）、SN、ICCID（SIM 卡序列号）、固件版本、模块型号。',
      params: [],
      result: '返回 JSON，如 <code class="font-mono">{"imei":"8681...","sn":"...","iccid":"8986...","version":"...","model":"..."}</code>',
      note: '无需参数。设备首次接入面板后可通过此命令核对硬件身份。',
    },
    ussd_query: {
      title: 'USSD 查询',
      desc: '发送 USSD 交互码查询话费/流量余额（如电信 <code class="font-mono">*108#</code>）。运营商回复后，结果通过通知渠道（如 message-pusher）推送给你。',
      params: [
        ['code', 'USSD 查询码，如 *108#（各运营商不同，请自行确认）'],
      ],
      result: '返回 <code class="font-mono">"USSD 查询已发送: *108#，运营商回复将通过通知推送"</code>，实际余额在推送的通知里。',
      note: 'USSD 会话会占用话音通道，查询后几秒内不要拨打/接听电话。物联网卡可能不支持 USSD。',
    },
    send_dtmf: {
      title: '发送按键',
      desc: '通话过程中向对端发送 DTMF 按键音。典型场景：自动拨打客服后输入分机号、语音信箱选单。',
      params: [
        ['dtmf', '按键字符串，仅支持数字和 ABCD*#，如 "123"'],
      ],
      result: '通话中返回 <code class="font-mono">"DTMF 已发送: xxx"</code>；无通话时报错"当前无通话"。',
      note: '必须先"拨打电话"且通话建立后使用，每个按键默认播放 100ms。常与拨打电话配合实现自动语音流程。',
    },
    set_gpio: {
      title: 'GPIO 控制',
      desc: '设置指定 GPIO 引脚的输出电平（高/低）。外接继电器或 MOS 管即可实现远程控制电器开关、门禁等。',
      params: [
        ['pin', 'GPIO 引脚编号（数字），参考开发板引脚图'],
        ['level', '输出电平：1 高电平（通常闭合继电器），0 低电平（断开）'],
      ],
      result: '返回 <code class="font-mono">"GPIOn 已输出 1"</code>。输出状态保持到下次修改或重启（重启后恢复默认）。',
      note: 'GPIO 带载能力有限（毫安级），控制大电流设备务必经继电器隔离。引脚接错可能损坏模块，接线前核对引脚图。',
    },
  };

  // 命令大全分组（"任务说明"弹窗与命令大全共用 TASK_HELP 数据）
  const TASK_GROUPS = [
    { name: '查询类', icon: '🔍', tasks: ['get_temperature', 'get_status', 'get_device_info', 'get_config', 'query_traffic'] },
    { name: '通信类', icon: '💬', tasks: ['send_sms', 'dial_call', 'hang_up', 'send_dtmf', 'tts_speak', 'set_ccfc', 'ussd_query'] },
    { name: '配置与系统', icon: '⚙️', tasks: ['set_config', 'set_volume', 'set_gpio', 'switch_sim', 'reboot'] },
  ];

  // 命令大全：手风琴模式，始终只展开一个分组
  let libOpenGroup = 0;

  function renderTaskLibrary() {
    const body = $('#task-library-body');
    body.innerHTML = TASK_GROUPS.map((g, gi) => {
      const open = gi === libOpenGroup;
      return `
      <div>
        <button type="button" class="task-lib-group w-full flex items-center justify-between gap-3 px-4 py-3 rounded-xl bg-slate-50 hover:bg-slate-100 transition-colors" data-group="${gi}">
          <span class="flex items-center gap-2 text-sm font-semibold text-slate-800">${g.icon} ${g.name}</span>
          <svg class="w-4 h-4 text-slate-400 shrink-0" style="transform: ${open ? 'rotate(90deg)' : 'none'}; transition: transform .2s" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
        </button>
        ${open ? `<ul class="mt-2 rounded-xl border border-slate-100 divide-y divide-slate-100 overflow-hidden">
          ${g.tasks.map((t) => {
            const h = TASK_HELP[t];
            return h ? `<li>
              <a href="javascript:void(0)" class="task-lib-item flex items-center justify-between gap-3 px-4 py-3 hover:bg-blue-50/60 transition-colors" data-task="${t}">
                <span class="flex items-center gap-2.5 min-w-0">
                  <span class="font-medium text-sm text-slate-800">${h.title}</span>
                  <code class="font-mono text-xs text-blue-600 bg-blue-50 rounded px-1.5 py-0.5 shrink-0">${t}</code>
                </span>
                <svg class="w-4 h-4 text-slate-300 shrink-0" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7"/></svg>
              </a>
            </li>` : '';
          }).join('')}
        </ul>` : ''}
      </div>`;
    }).join('');
  }

  function showTaskLibrary() {
    renderTaskLibrary();
    $('#task-library-modal').classList.remove('hidden');
  }
  function closeTaskLibrary() {
    $('#task-library-modal').classList.add('hidden');
  }

  function showTaskHelp(task) {
    const h = TASK_HELP[task];
    if (!h) return;
    $('#task-help-title').textContent = h.title;
    $('#task-help-cmd').textContent = task;
    let html = `<p>${h.desc}</p>`;
    if (h.params.length) {
      html += '<div><p class="font-semibold text-slate-800 text-xs mb-1.5">请求参数</p><ul class="space-y-1 list-disc pl-5">'
        + h.params.map((p) => `<li><code class="font-mono text-xs bg-slate-100 rounded px-1.5 py-0.5">${p[0]}</code> — ${p[1]}</li>`).join('')
        + '</ul></div>';
    }
    html += `<div><p class="font-semibold text-slate-800 text-xs mb-1.5">返回结果</p><p>${h.result}</p></div>`;
    html += `<div class="rounded-lg bg-amber-50 border border-amber-100 px-3.5 py-2.5 text-xs text-amber-700">⚠️ ${h.note}</div>`;
    $('#task-help-body').innerHTML = html;
    $('#task-help-modal').classList.remove('hidden');
  }
  function closeTaskHelp() {
    $('#task-help-modal').classList.add('hidden');
  }

  function onTaskTypeChange() {
    const checked = document.querySelector('input[name="task-type"]:checked');
    if (!checked) return;
    const type = checked.value;
    ['params-send_sms', 'params-set_config', 'params-__custom__'].forEach((id) => {
      const el = $('#' + id);
      if (el) el.classList.toggle('hidden', id !== 'params-' + type);
    });
  }

  // 终端控制台输出
  function consoleLine(box, text, cls) {
    const div = document.createElement('div');
    div.className = cls || '';
    div.textContent = text;
    box.appendChild(div);
    box.scrollTop = box.scrollHeight;
  }
  function resetConsole() {
    const box = $('#task-result');
    box.innerHTML = '<p class="text-slate-500">// 等待下发任务...</p>';
  }

  async function handleTaskSubmit(e) {
    e.preventDefault();
    const imei = $('#task-imei').value;
    if (!imei) { toast('请选择目标设备', false); return; }
    const checked = document.querySelector('input[name="task-type"]:checked');
    let type = checked ? checked.value : '';
    const payload = { imei, task: type };

    if (type === '__custom__') {
      const cmd = $('#task-custom-cmd').value.trim();
      if (!cmd) { toast('请输入命令名称', false); return; }
      const params = $('#task-custom-params').value.trim();
      let extraObj = {};
      if (params) {
        try { extraObj = JSON.parse(params); }
        catch (_) { toast('命令参数不是合法 JSON', false); return; }
      }
      type = cmd;
      payload.task = cmd;
      Object.assign(payload, extraObj);
    } else if (type === 'send_sms') {
      const phone = $('#task-rcv-phone').value.trim();
      const content = $('#task-content').value.trim();
      if (!phone || !content) { toast('请填写手机号和短信内容', false); return; }
      payload.rcv_phone = phone;
      payload.content = content;
    } else if (type === 'set_config') {
      const text = $('#task-config-text').value;
      if (!text.trim()) { toast('请填写配置内容', false); return; }
      payload.configText = text;
    }

    const extra = $('#task-extra').value.trim();
    if (extra) {
      try { Object.assign(payload, JSON.parse(extra)); }
      catch (_) { toast('附加参数不是合法 JSON', false); return; }
    }

    const btn = $('#task-btn');
    btn.disabled = true;
    btn.textContent = '下发中...';
    const box = $('#task-result');
    resetConsole();
    consoleLine(box, `▶ 下发任务 → ${imei}（${TASK_LABELS[type] || type}）`, 'text-sky-400');
    consoleLine(box, '⏳ 等待设备回报（最长 30 秒）...', 'text-slate-400');
    try {
      const data = await API.executeTask(payload);
      const result = data.result;
      if (result && typeof result === 'object' && result.error) {
        throw new Error(result.error);
      }
      const pretty = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
      consoleLine(box, '✔ 设备已回报：', 'text-emerald-400');
      consoleLine(box, pretty, 'text-emerald-200 whitespace-pre-wrap break-all');
      toast('任务执行成功');
    } catch (err) {
      consoleLine(box, `✘ 执行失败：${err.message}`, 'text-red-400');
      toast('任务执行失败', false);
    } finally {
      btn.disabled = false;
      btn.textContent = '⚡ 下发任务';
    }
  }

  // ---------------- 任务记录 ----------------

  let tasksPage = 1;

  async function loadTasks(page) {
    if (typeof page === 'number') tasksPage = page;
    try {
      const data = await API.tasks(tasksPage);
      tasksPage = data.page || tasksPage;
      const tasks = data.tasks || [];
      const tbody = $('#tasks-tbody');
      if (!tasks.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="px-4 py-10 text-center text-slate-400">暂无任务记录</td></tr>';
        renderTaskPagination(0, 1);
        return;
      }
      tbody.innerHTML = tasks.map((t) => {
        let result = t.result || t.error || '';
        if (result.length > 120) result = result.slice(0, 120) + '…';
        const ok = t.status === 'done' && !t.error;
        const deviceLabel = t.deviceName || t.imei;
        const isName = !!t.deviceName;
        return `
        <tr class="hover:bg-slate-50 align-top">
          <td class="px-4 py-3 text-slate-500 whitespace-nowrap">${fmtTime(t.createdAt)}</td>
          <td class="px-4 py-3 text-slate-700">${esc(deviceLabel)}${isName ? `<span class="block text-xs font-mono text-slate-400 mt-0.5">${esc(t.imei)}</span>` : ''}</td>
          <td class="px-4 py-3 text-slate-600">${esc(t.task)}</td>
          <td class="px-4 py-3">${ok ? '<span class="badge-online">成功</span>' : '<span class="badge-offline">失败</span>'}</td>
          <td class="px-4 py-3 text-slate-500 max-w-xs"><pre class="text-xs font-mono whitespace-pre-wrap break-all">${esc(result)}</pre></td>
        </tr>`;
      }).join('');
      renderTaskPagination(data.total || 0, tasksPage);
    } catch (err) {
      $('#tasks-tbody').innerHTML = `<tr><td colspan="5" class="px-4 py-10 text-center text-red-500">${esc(err.message)}</td></tr>`;
      renderTaskPagination(0, 1);
    }
  }

  // 渲染任务记录分页控件（每页 10 条）
  function renderTaskPagination(total, page) {
    const wrap = $('#tasks-pagination');
    const info = $('#tasks-page-info');
    const btns = $('#tasks-page-btns');
    const totalPages = Math.max(1, Math.ceil(total / 10));

    if (total <= 0) {
      wrap.classList.add('hidden');
      return;
    }
    wrap.classList.remove('hidden');
    info.textContent = `共 ${total} 条记录 · 第 ${page} / ${totalPages} 页`;

    // 页码列表：首末页 + 当前页相邻页，中间以省略号折叠
    const list = [];
    for (let i = 1; i <= totalPages; i++) {
      if (i === 1 || i === totalPages || Math.abs(i - page) <= 1) list.push(i);
      else if (list[list.length - 1] !== '…') list.push('…');
    }

    // 按钮样式以已有 Tailwind 类为主，缺失的工具类用内联样式补充
    const btnCls = 'h-8 px-2 rounded-lg text-sm transition-colors';
    const btnStyle = (dis) => `style="min-width:2rem${dis ? ';opacity:.4;cursor:not-allowed' : ''}"`;
    let html = `
      <button type="button" data-page="${page - 1}" class="${btnCls} text-slate-600" ${btnStyle(page <= 1)} ${page <= 1 ? 'disabled' : ''}>‹</button>`;
    html += list.map((p) => p === '…'
      ? '<span class="text-slate-300" style="width:1.5rem;text-align:center;line-height:2rem">…</span>'
      : `<button type="button" data-page="${p}" class="${btnCls} ${p === page ? 'bg-blue-600 text-white' : 'text-slate-600'}" style="min-width:2rem">${p}</button>`
    ).join('');
    html += `
      <button type="button" data-page="${page + 1}" class="${btnCls} text-slate-600" ${btnStyle(page >= totalPages)} ${page >= totalPages ? 'disabled' : ''}>›</button>`;
    btns.innerHTML = html;
  }

  // ---------------- 定时任务（计划任务） ----------------

  const WEEKDAY_NAMES = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

  let schedules = [];
  let schEditingId = 0;
  let schedulesPage = 1;

  function renderSchDeviceSelect(selected) {
    const sel = $('#sch-imei');
    if (!sel) return;
    if (!devices.length) {
      sel.innerHTML = '<option value="">暂无设备</option>';
      return;
    }
    sel.innerHTML = '<option value="">请选择设备</option>' + devices.map((d) =>
      `<option value="${esc(d.imei)}" ${d.imei === selected ? 'selected' : ''}>${d.name ? esc(d.name) + ' · ' : ''}${esc(d.imei)}${d.connected ? '' : ' [离线]'}</option>`).join('');
  }

  function renderSchTaskSelect(selected) {
    const sel = $('#sch-task');
    if (!sel) return;
    let html = TASK_GROUPS.map((g) =>
      `<optgroup label="${g.name}">` + g.tasks.map((t) => {
        const h = TASK_HELP[t];
        return h ? `<option value="${t}">${h.title}</option>` : '';
      }).join('') + '</optgroup>').join('');
    html += '<optgroup label="其他"><option value="__custom__">自定义命令</option></optgroup>';
    sel.innerHTML = html;
    if (selected && sel.querySelector(`option[value="${CSS.escape(selected)}"]`)) sel.value = selected;
  }

  // 周期类型变化：渲染对应参数控件（宝塔面板风格，参数下拉框统一固定宽度保持一行紧凑）
  function onSchCycleChange() {
    const type = $('#sch-cycle').value;
    const box = $('#sch-cycle-detail');
    const numSel = (id, from, to, def, w) => {
      let opts = '';
      for (let i = from; i <= to; i++) {
        opts += `<option value="${i}" ${i === def ? 'selected' : ''}>${String(i).padStart(2, '0')}</option>`;
      }
      return `<select id="${id}" class="input !py-1.5 !px-3 text-sm" style="width:${w || '4.2rem'}">${opts}</select>`;
    };
    const selCls = 'input !py-1.5 !px-3 text-sm';
    if (type === 'weekly') {
      box.innerHTML = `<span class="text-slate-500">每</span>` +
        `<select id="sch-c-weekday" class="${selCls}" style="width:4rem">` + WEEKDAY_NAMES.map((w, i) => `<option value="${i}">${w}</option>`).join('') + `</select>` +
        `<span class="text-slate-500">的</span>` + numSel('sch-c-hour', 0, 23, 8, '4.2rem') + `<span class="text-slate-500">点</span>` + numSel('sch-c-minute', 0, 59, 0, '4.2rem') + `<span class="text-slate-500">分</span>`;
    } else if (type === 'monthly') {
      box.innerHTML = `<span class="text-slate-500">每月</span>` + numSel('sch-c-day', 1, 31, 1, '4.2rem') + `<span class="text-slate-500">日</span>` + numSel('sch-c-hour', 0, 23, 8, '4.2rem') + `<span class="text-slate-500">点</span>` + numSel('sch-c-minute', 0, 59, 0, '4.2rem') + `<span class="text-slate-500">分</span>`;
    } else if (type === 'daily') {
      box.innerHTML = numSel('sch-c-hour', 0, 23, 8, '4.2rem') + `<span class="text-slate-500">点</span>` + numSel('sch-c-minute', 0, 59, 0, '4.2rem') + `<span class="text-slate-500">分</span>`;
    } else if (type === 'hourly') {
      box.innerHTML = `<span class="text-slate-500">每小时的</span>` + numSel('sch-c-minute', 0, 59, 0, '4.2rem') + `<span class="text-slate-500">分</span>`;
    } else if (type === 'interval_min') {
      box.innerHTML = `<span class="text-slate-500">每</span>` + numSel('sch-c-n', 1, 59, 5, '4.2rem') + `<span class="text-slate-500">分钟执行一次</span>`;
    } else if (type === 'interval_hour') {
      box.innerHTML = `<span class="text-slate-500">每</span>` + numSel('sch-c-n', 1, 23, 2, '4.2rem') + `<span class="text-slate-500">小时执行一次</span>`;
    } else {
      box.innerHTML = '';
    }
  }

  // 收集表单中的执行周期
  function getSchCycleSpec() {
    const type = $('#sch-cycle').value;
    const val = (id) => {
      const el = $('#' + id);
      return el ? parseInt(el.value, 10) : 0;
    };
    if (type === 'weekly') return { type: 'weekly', weekday: val('sch-c-weekday'), hour: val('sch-c-hour'), minute: val('sch-c-minute') };
    if (type === 'monthly') return { type: 'monthly', day: val('sch-c-day'), hour: val('sch-c-hour'), minute: val('sch-c-minute') };
    if (type === 'daily') return { type: 'daily', hour: val('sch-c-hour'), minute: val('sch-c-minute') };
    if (type === 'hourly') return { type: 'hourly', minute: val('sch-c-minute') };
    if (type === 'interval_min') return { type: 'interval', n: val('sch-c-n'), unit: 'minute' };
    if (type === 'interval_hour') return { type: 'interval', n: val('sch-c-n'), unit: 'hour' };
    return null;
  }

  // 编辑时把 spec 回填到表单
  function specToForm(spec) {
    if (!spec || !spec.type) return;
    $('#sch-cycle').value = spec.type === 'interval'
      ? (spec.unit === 'hour' ? 'interval_hour' : 'interval_min')
      : spec.type;
    onSchCycleChange();
    const set = (id, v) => {
      const el = $('#' + id);
      if (el && v != null) el.value = String(v);
    };
    set('sch-c-weekday', spec.weekday);
    set('sch-c-day', spec.day);
    set('sch-c-hour', spec.hour);
    set('sch-c-minute', spec.minute);
    set('sch-c-n', spec.n);
  }

  // 任务类型变化：渲染参数表单（基于 TASK_HELP 参数定义）
  function onSchTaskChange() {
    const task = $('#sch-task').value;
    const box = $('#sch-params');
    if (task === '__custom__') {
      box.innerHTML = `
        <div class="border-t border-slate-100 pt-4 grid gap-4 grid-cols-2">
          <div>
            <label class="label" for="sch-custom-cmd">命令名称</label>
            <input id="sch-custom-cmd" type="text" class="input font-mono text-xs" placeholder="如 ussd_query、get_status、set_gpio">
          </div>
          <div>
            <label class="label" for="sch-custom-params">命令参数 <span class="text-slate-400 font-normal">（可选 JSON 对象）</span></label>
            <textarea id="sch-custom-params" rows="2" class="input font-mono text-xs" placeholder='{"pin": 15, "level": 1}'></textarea>
          </div>
        </div>`;
      return;
    }
    const h = TASK_HELP[task];
    if (!h || !h.params.length) {
      box.innerHTML = '<p class="text-xs text-slate-400 border-t border-slate-100 pt-3">该任务无需参数</p>';
      return;
    }
    box.innerHTML = '<div class="border-t border-slate-100 pt-4 grid gap-4 grid-cols-2">' + h.params.map((p) => {
      const isLong = p[0] === 'configText' || p[0] === 'content';
      return `<div>
        <label class="label" for="sch-p-${esc(p[0])}">${esc(p[0])}</label>
        ${isLong
          ? `<textarea id="sch-p-${esc(p[0])}" rows="3" class="input font-mono text-xs"></textarea>`
          : `<input id="sch-p-${esc(p[0])}" type="text" class="input">`}
        <p class="text-xs text-slate-400 mt-1">${p[1]}</p>
      </div>`;
    }).join('') + '</div>';
  }

  // 收集表单中的任务参数
  function getSchParams() {
    const task = $('#sch-task').value;
    if (task === '__custom__') {
      const raw = $('#sch-custom-params') ? $('#sch-custom-params').value.trim() : '';
      let obj = {};
      if (raw) {
        try { obj = JSON.parse(raw); }
        catch (_) { throw new Error('命令参数不是合法 JSON'); }
      }
      return obj;
    }
    const h = TASK_HELP[task];
    const obj = {};
    if (h && h.params.length) {
      h.params.forEach((p) => {
        const el = $('#sch-p-' + p[0]);
        if (el) obj[p[0]] = el.value.trim();
      });
    }
    return obj;
  }

  function specDescribe(spec) {
    if (!spec || !spec.type) return '—';
    const p2 = (n) => String(n).padStart(2, '0');
    switch (spec.type) {
      case 'weekly': return '每周' + (WEEKDAY_NAMES[spec.weekday] || '') + ' ' + p2(spec.hour) + ':' + p2(spec.minute);
      case 'monthly': return '每月 ' + spec.day + ' 日 ' + p2(spec.hour) + ':' + p2(spec.minute);
      case 'daily': return '每天 ' + p2(spec.hour) + ':' + p2(spec.minute);
      case 'hourly': return '每小时 ' + p2(spec.minute) + ' 分';
      case 'interval': return spec.unit === 'hour' ? '每 ' + spec.n + ' 小时' : '每 ' + spec.n + ' 分钟';
    }
    return '—';
  }

  async function loadSchedules(page) {
    if (typeof page === 'number') schedulesPage = page;
    try {
      const data = await API.schedules(schedulesPage);
      schedulesPage = data.page || schedulesPage;
      schedules = data.schedules || [];
      // 当前页被删空时自动回退一页
      if (!schedules.length && schedulesPage > 1) {
        schedulesPage -= 1;
        return loadSchedules(schedulesPage);
      }
      renderSchedules();
      renderSchedulePagination(data.total || 0, schedulesPage);
    } catch (err) {
      $('#schedules-tbody').innerHTML = `<tr><td colspan="7" class="px-4 py-10 text-center text-red-500">${esc(err.message)}</td></tr>`;
      renderSchedulePagination(0, 1);
    }
  }

  // 渲染定时任务分页控件（每页 5 条）
  function renderSchedulePagination(total, page) {
    const wrap = $('#schedules-pagination');
    const info = $('#schedules-page-info');
    const btns = $('#schedules-page-btns');
    const pageSize = 5;
    const totalPages = Math.max(1, Math.ceil(total / pageSize));

    if (total <= 0) {
      wrap.classList.add('hidden');
      return;
    }
    wrap.classList.remove('hidden');
    info.textContent = `共 ${total} 条 · 第 ${page} / ${totalPages} 页`;

    const list = [];
    for (let i = 1; i <= totalPages; i++) {
      if (i === 1 || i === totalPages || Math.abs(i - page) <= 1) list.push(i);
      else if (list[list.length - 1] !== '…') list.push('…');
    }
    const btnCls = 'h-8 px-2 rounded-lg text-sm transition-colors';
    const btnStyle = (dis) => `style="min-width:2rem${dis ? ';opacity:.4;cursor:not-allowed' : ''}"`;
    let html = `
      <button type="button" data-page="${page - 1}" class="${btnCls} text-slate-600" ${btnStyle(page <= 1)} ${page <= 1 ? 'disabled' : ''}>‹</button>`;
    html += list.map((p) => p === '…'
      ? '<span class="text-slate-300" style="width:1.5rem;text-align:center;line-height:2rem">…</span>'
      : `<button type="button" data-page="${p}" class="${btnCls} ${p === page ? 'bg-blue-600 text-white' : 'text-slate-600'}" style="min-width:2rem">${p}</button>`
    ).join('');
    html += `
      <button type="button" data-page="${page + 1}" class="${btnCls} text-slate-600" ${btnStyle(page >= totalPages)} ${page >= totalPages ? 'disabled' : ''}>›</button>`;
    btns.innerHTML = html;
  }

  function renderSchedules() {
    const tbody = $('#schedules-tbody');
    if (!schedules.length) {
      tbody.innerHTML = '<tr><td colspan="7" class="px-4 py-10 text-center text-slate-400">暂无定时任务</td></tr>';
      return;
    }
    tbody.innerHTML = schedules.map((s) => {
      const taskLabel = TASK_HELP[s.task] ? TASK_HELP[s.task].title : s.task;
      const deviceLabel = s.deviceName || s.imei;
      const name = s.name || ('任务 #' + s.id);
      return `
      <tr class="hover:bg-slate-50 align-top">
        <td class="px-4 py-3 text-slate-700">${esc(name)}</td>
        <td class="px-4 py-3 text-slate-600">${esc(deviceLabel)}${s.deviceName ? `<span class="block text-xs font-mono text-slate-400 mt-0.5">${esc(s.imei)}</span>` : ''}</td>
        <td class="px-4 py-3 text-slate-600"><span class="font-medium">${esc(taskLabel)}</span><span class="block text-xs font-mono text-slate-400 mt-0.5">${esc(s.task)}</span></td>
        <td class="px-4 py-3 text-slate-600 whitespace-nowrap">${esc(specDescribe(s.spec))}</td>
        <td class="px-4 py-3 text-slate-500 whitespace-nowrap">${fmtTime(s.lastExecuted)}</td>
        <td class="px-4 py-3">${s.enabled ? '<span class="badge-online">已启用</span>' : '<span class="badge-offline">已停用</span>'}</td>
        <td class="px-4 py-3 text-right whitespace-nowrap">
          <button class="btn btn-ghost !px-3 !py-1.5 text-xs" data-sch-run="${s.id}">执行</button>
          <button class="btn btn-ghost !px-3 !py-1.5 text-xs" data-sch-toggle="${s.id}" data-next="${s.enabled ? 0 : 1}">${s.enabled ? '停用' : '启用'}</button>
          <button class="btn btn-ghost !px-3 !py-1.5 text-xs" data-sch-edit="${s.id}">编辑</button>
          <button class="btn btn-ghost !px-3 !py-1.5 text-xs text-red-600 hover:text-red-700" data-sch-del="${s.id}">删除</button>
        </td>
      </tr>`;
    }).join('');
  }

  async function handleScheduleSubmit(e) {
    e.preventDefault();
    const imei = $('#sch-imei').value;
    if (!imei) { toast('请选择目标设备', false); return; }
    let params;
    try { params = getSchParams(); }
    catch (err) { toast(err.message, false); return; }
    const taskSel = $('#sch-task').value;
    let task = taskSel;
    if (taskSel === '__custom__') {
      const cmd = $('#sch-custom-cmd') ? $('#sch-custom-cmd').value.trim() : '';
      if (!cmd) { toast('请输入命令名称', false); return; }
      task = cmd;
    }
    const spec = getSchCycleSpec();
    if (!spec) { toast('请选择执行周期', false); return; }

    const payload = {
      name: $('#sch-name').value.trim(),
      imei, task, params, spec,
      enabled: $('#sch-enabled').checked,
    };
    const btn = $('#sch-btn');
    const wasEditing = !!schEditingId;
    btn.disabled = true;
    try {
      const data = wasEditing
        ? await API.updateSchedule(Object.assign({ id: schEditingId }, payload))
        : await API.addSchedule(payload);
      toast(data.message);
      cancelScheduleEdit();
      loadSchedules(wasEditing ? schedulesPage : 1);
    } catch (err) {
      toast(err.message, false);
    } finally {
      btn.disabled = false;
    }
  }

  function editSchedule(id) {
    const s = schedules.find((x) => x.id === id);
    if (!s) return;
    schEditingId = s.id;
    $('#sch-edit-id').value = String(s.id);
    $('#sch-name').value = s.name || '';
    renderSchDeviceSelect(s.imei);
    let params = {};
    try { params = JSON.parse(s.params || '{}'); } catch (_) { /* 忽略 */ }
    if (TASK_HELP[s.task]) {
      renderSchTaskSelect(s.task);
      onSchTaskChange();
      Object.keys(params).forEach((k) => {
        const el = $('#sch-p-' + k);
        if (el) el.value = params[k] != null ? String(params[k]) : '';
      });
    } else {
      renderSchTaskSelect('__custom__');
      onSchTaskChange();
      if ($('#sch-custom-cmd')) $('#sch-custom-cmd').value = s.task;
      if ($('#sch-custom-params')) $('#sch-custom-params').value = s.params && s.params !== '{}' ? s.params : '';
    }
    specToForm(s.spec);
    $('#sch-enabled').checked = s.enabled;
    $('#sch-btn').textContent = '保存修改';
    $('#sch-cancel').classList.remove('hidden');
    toast('正在编辑任务 #' + s.id);
    $('#schedule-form').scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function cancelScheduleEdit() {
    schEditingId = 0;
    $('#sch-edit-id').value = '';
    $('#sch-name').value = '';
    renderSchDeviceSelect();
    renderSchTaskSelect();
    $('#sch-task').selectedIndex = 0;
    onSchTaskChange();
    $('#sch-cycle').value = 'daily';
    onSchCycleChange();
    $('#sch-enabled').checked = true;
    $('#sch-btn').textContent = '添加任务';
    $('#sch-cancel').classList.add('hidden');
  }

  async function runScheduleNow(id) {
    toast('正在下发任务，等待设备回报...');
    try {
      const data = await API.runSchedule({ id });
      const result = data.result;
      if (result && typeof result === 'object' && result.error) throw new Error(result.error);
      toast('执行成功，结果见任务记录');
      loadSchedules();
    } catch (err) {
      toast(err.message, false);
    }
  }

  async function toggleScheduleRow(id, next) {
    try {
      const data = await API.toggleSchedule({ id, enabled: !!next });
      toast(data.message);
      loadSchedules();
    } catch (err) {
      toast(err.message, false);
    }
  }

  async function deleteScheduleRow(id) {
    const s = schedules.find((x) => x.id === id);
    const ok = await showConfirm(`确定删除定时任务「${s ? (s.name || '#' + s.id) : '#' + id}」吗？删除后不可恢复。`);
    if (!ok) return;
    try {
      const data = await API.deleteSchedule({ id });
      toast(data.message);
      loadSchedules();
    } catch (err) {
      toast(err.message, false);
    }
  }

  // ---------------- 自定义确认弹窗 ----------------

  let confirmResolver = null;

  // 打开确认弹窗，返回 Promise<boolean>（确认=true / 取消=false）
  function showConfirm(message, title = '确认操作', okText = '确认删除') {
    $('#confirm-title').textContent = title;
    $('#confirm-message').textContent = message;
    $('#confirm-ok').textContent = okText;
    $('#confirm-modal').classList.remove('hidden');
    $('#confirm-ok').focus();
    return new Promise((resolve) => { confirmResolver = resolve; });
  }

  function closeConfirm(result) {
    $('#confirm-modal').classList.add('hidden');
    if (confirmResolver) {
      confirmResolver(result);
      confirmResolver = null;
    }
  }

  // 清理任务日志（days > 0 删除 days 天前旧日志，days <= 0 删除全部）
  async function clearTasks(days) {
    const ok = await showConfirm(
      days > 0 ? '确定删除 7 天前的旧日志吗？删除后不可恢复。' : '确定删除全部任务记录吗？删除后不可恢复。'
    );
    if (!ok) return;
    try {
      const data = await API.clearTasks({ days });
      toast(`已删除 ${data.deleted} 条记录`);
      loadTasks(1);
    } catch (err) {
      toast(err.message, false);
    }
  }

  // ---------------- 设置 ----------------

  async function handleSettings(e) {
    e.preventDefault();
    const oldPassword = $('#set-old-password').value;
    const newUsername = $('#set-new-username').value.trim();
    const newPassword = $('#set-new-password').value;
    if (!oldPassword) { toast('请填写原密码', false); return; }
    const msg = $('#settings-msg');
    msg.className = 'hidden';
    try {
      const data = await API.changeUserInfo({ oldPassword, newUsername, newPassword });
      msg.textContent = data.message;
      msg.className = 'text-sm ' + (data.needRelogin ? 'text-amber-600' : 'text-emerald-600');
      if (data.needRelogin) {
        if (newUsername) localStorage.setItem('panel_username', newUsername);
        toast('信息已修改，请重新登录');
        setTimeout(handleLogout, 1200);
      } else {
        toast('保存成功');
      }
      $('#set-old-password').value = '';
      $('#set-new-password').value = '';
    } catch (err) {
      msg.textContent = err.message;
      msg.className = 'text-sm text-red-600';
    }
  }

  // ---------------- 初始化 ----------------

  function bindEvents() {
    $('#login-form').addEventListener('submit', handleLogin);
    $('#logout-btn').addEventListener('click', handleLogout);
    $('#refresh-devices').addEventListener('click', loadDevices);
    $('#task-form').addEventListener('submit', handleTaskSubmit);
    $$('input[name="task-type"]').forEach((r) => r.addEventListener('change', onTaskTypeChange));
    $('#console-clear').addEventListener('click', resetConsole);
    $('#settings-form').addEventListener('submit', handleSettings);
    $('#clear-tasks-7d').addEventListener('click', () => clearTasks(7));
    $('#clear-tasks-all').addEventListener('click', () => clearTasks(0));
    // 定时任务
    $('#schedule-form').addEventListener('submit', handleScheduleSubmit);
    $('#sch-cycle').addEventListener('change', onSchCycleChange);
    $('#sch-task').addEventListener('change', onSchTaskChange);
    $('#sch-cancel').addEventListener('click', cancelScheduleEdit);
    $('#schedules-tbody').addEventListener('click', (ev) => {
      const run = ev.target.closest('[data-sch-run]');
      if (run) { runScheduleNow(parseInt(run.dataset.schRun, 10)); return; }
      const toggle = ev.target.closest('[data-sch-toggle]');
      if (toggle) { toggleScheduleRow(parseInt(toggle.dataset.schToggle, 10), parseInt(toggle.dataset.next, 10)); return; }
      const edit = ev.target.closest('[data-sch-edit]');
      if (edit) { editSchedule(parseInt(edit.dataset.schEdit, 10)); return; }
      const del = ev.target.closest('[data-sch-del]');
      if (del) { deleteScheduleRow(parseInt(del.dataset.schDel, 10)); return; }
    });
    // 定时任务分页（事件委托）
    $('#schedules-page-btns').addEventListener('click', (ev) => {
      const btn = ev.target.closest('button[data-page]');
      if (!btn || btn.disabled) return;
      const p = parseInt(btn.dataset.page, 10);
      if (p >= 1) loadSchedules(p);
    });
    // 任务记录分页（事件委托）
    $('#tasks-page-btns').addEventListener('click', (ev) => {
      const btn = ev.target.closest('button[data-page]');
      if (!btn || btn.disabled) return;
      const p = parseInt(btn.dataset.page, 10);
      if (p >= 1) loadTasks(p);
    });
    $('#confirm-cancel').addEventListener('click', () => closeConfirm(false));
    $('#confirm-ok').addEventListener('click', () => closeConfirm(true));
    $('#confirm-overlay').addEventListener('click', () => closeConfirm(false));

    // 命令大全弹窗
    $('#task-library-link').addEventListener('click', showTaskLibrary);
    $('#task-custom-help').addEventListener('click', showTaskLibrary);
    $('#task-library-close').addEventListener('click', closeTaskLibrary);
    $('#task-library-ok').addEventListener('click', closeTaskLibrary);
    $('#task-library-overlay').addEventListener('click', closeTaskLibrary);
    // 命令大全内点击分组标题 -> 切换手风琴展开（关闭其他组）
    $('#task-library-body').addEventListener('click', (ev) => {
      const group = ev.target.closest('.task-lib-group');
      if (group) {
        const gi = parseInt(group.dataset.group, 10);
        libOpenGroup = (libOpenGroup === gi) ? -1 : gi; // 再点一次收起
        renderTaskLibrary();
        return;
      }
      const item = ev.target.closest('.task-lib-item');
      if (!item) return;
      closeTaskLibrary();
      showTaskHelp(item.dataset.task);
    });
    $('#task-help-close').addEventListener('click', closeTaskHelp);
    $('#task-help-ok').addEventListener('click', closeTaskHelp);
    $('#task-help-overlay').addEventListener('click', closeTaskHelp);
    document.addEventListener('keydown', (ev) => {
      if (ev.key === 'Escape') {
        if (!$('#confirm-modal').classList.contains('hidden')) closeConfirm(false);
        else if (!$('#task-help-modal').classList.contains('hidden')) closeTaskHelp();
        else if (!$('#task-library-modal').classList.contains('hidden')) closeTaskLibrary();
      }
    });
    $('#menu-btn').addEventListener('click', () => toggleSidebar(true));
    $('#sidebar-overlay').addEventListener('click', () => toggleSidebar(false));

    $$('.nav-item').forEach((a) =>
      a.addEventListener('click', (e) => { e.preventDefault(); switchPage(a.dataset.nav); toggleSidebar(false); }));

    // 设备表格里"执行任务"按钮 / 备注编辑
    $('#devices-tbody').addEventListener('click', (e) => {
      const runBtn = e.target.closest('[data-run]');
      if (runBtn) {
        renderDeviceSelect(runBtn.dataset.run);
        switchPage('tasks');
        return;
      }
      const remarkBtn = e.target.closest('[data-remark]');
      if (remarkBtn) startEditRemark(remarkBtn.dataset.remark);
    });
  }

  function init() {
    bindEvents();
    onTaskTypeChange();
    if (API.token) {
      enterMain();
    } else {
      showLogin();
    }
  }

  init();
})();
