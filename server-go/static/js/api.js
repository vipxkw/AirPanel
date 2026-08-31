// API 封装：与服务端 REST 接口交互
const API = {
  token: localStorage.getItem('panel_token') || '',

  async request(method, path, body) {
    const headers = { 'Content-Type': 'application/json' };
    if (this.token) headers['Authorization'] = 'Bearer ' + this.token;
    const res = await fetch('/api' + path, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    const data = await res.json().catch(() => ({}));
    if (res.status === 401 || res.status === 403) {
      this.clearToken();
      throw new Error(data.message || '登录已失效，请重新登录');
    }
    if (!res.ok) throw new Error(data.message || '请求失败');
    return data;
  },

  setToken(t) {
    this.token = t;
    localStorage.setItem('panel_token', t);
  },
  clearToken() {
    this.token = '';
    localStorage.removeItem('panel_token');
  },

  login(username, password) {
    return this.request('POST', '/login', { username, password });
  },
  logout() {
    return this.request('POST', '/logout');
  },
  userPool() {
    return this.request('GET', '/userPool');
  },
  updateDeviceRemark(payload) {
    return this.request('POST', '/device/remark', payload);
  },
  deleteDevice(payload) {
    return this.request('POST', '/device/delete', payload);
  },
  executeTask(payload) {
    return this.request('POST', '/executeTask', payload);
  },
  tasks(page = 1) {
    return this.request('GET', '/tasks?page=' + encodeURIComponent(page));
  },
  clearTasks(payload) {
    return this.request('POST', '/tasks/clear', payload);
  },
  schedules(page = 1) {
    return this.request('GET', '/schedules?page=' + encodeURIComponent(page));
  },
  addSchedule(payload) {
    return this.request('POST', '/schedules/add', payload);
  },
  updateSchedule(payload) {
    return this.request('POST', '/schedules/update', payload);
  },
  toggleSchedule(payload) {
    return this.request('POST', '/schedules/toggle', payload);
  },
  deleteSchedule(payload) {
    return this.request('POST', '/schedules/delete', payload);
  },
  runSchedule(payload) {
    return this.request('POST', '/schedules/run', payload);
  },
  changeUserInfo(payload) {
    return this.request('POST', '/change-user-info', payload);
  },
  // 设置：离线判定超时 + 离线通知
  getSettings() {
    return this.request('GET', '/settings');
  },
  saveSettings(payload) {
    return this.request('POST', '/settings/save', payload);
  },
  notifyChannels() {
    return this.request('GET', '/notify/channels');
  },
  testNotify(payload) {
    return this.request('POST', '/notify/test', payload);
  },
};
