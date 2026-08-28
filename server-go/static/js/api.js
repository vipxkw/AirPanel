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
  executeTask(payload) {
    return this.request('POST', '/executeTask', payload);
  },
  tasks(page = 1) {
    return this.request('GET', '/tasks?page=' + encodeURIComponent(page));
  },
  clearTasks(payload) {
    return this.request('POST', '/tasks/clear', payload);
  },
  changeUserInfo(payload) {
    return this.request('POST', '/change-user-info', payload);
  },
};
