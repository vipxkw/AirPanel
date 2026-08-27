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

  function onTaskTypeChange() {
    const checked = document.querySelector('input[name="task-type"]:checked');
    if (!checked) return;
    const type = checked.value;
    ['params-send_sms', 'params-set_config'].forEach((id) => {
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
    const type = checked ? checked.value : '';
    const payload = { imei, task: type };

    if (type === 'send_sms') {
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

  async function loadTasks() {
    try {
      const tasks = await API.tasks();
      const tbody = $('#tasks-tbody');
      if (!tasks.length) {
        tbody.innerHTML = '<tr><td colspan="5" class="px-4 py-10 text-center text-slate-400">暂无任务记录</td></tr>';
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
    } catch (err) {
      $('#tasks-tbody').innerHTML = `<tr><td colspan="5" class="px-4 py-10 text-center text-red-500">${esc(err.message)}</td></tr>`;
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
      loadTasks();
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
    $('#confirm-cancel').addEventListener('click', () => closeConfirm(false));
    $('#confirm-ok').addEventListener('click', () => closeConfirm(true));
    $('#confirm-overlay').addEventListener('click', () => closeConfirm(false));
    document.addEventListener('keydown', (ev) => {
      if (ev.key === 'Escape' && !$('#confirm-modal').classList.contains('hidden')) closeConfirm(false);
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
