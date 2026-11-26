// Teknoir: the EMQX dashboard opens without its own login. Istio admits only teamspace
// owners and the proxy adds the EMQX credential to API calls, so the dashboard's store
// only needs a placeholder session for its router to skip the login page.
(function () {
  var TOKEN = 'teknoir-istio';
  function start(tries) {
    var el = document.getElementById('app');
    var app = el && el.__vue_app__;
    if (!app) { if (tries < 400) setTimeout(function () { start(tries + 1); }, 25); return; }
    var gp = app.config.globalProperties, store = gp.$store, router = gp.$router;
    if (!store || !router) return;
    function ensure() {
      // Replace any other stored session too: an owner who once logged in to EMQX's own
      // login keeps that JWT in localStorage, and the SPA would keep sending it.
      if (!store.state.user || store.state.user.token !== TOKEN) {
        store.commit('UPDATE_USER_INFO', { token: TOKEN, username: 'teknoir' });
        store.commit('UPDATE_EDITION', 'opensource');
      }
    }
    function target(r) {
      var to = r && r.query && r.query.to;
      return (typeof to === 'string' && to.charAt(0) === '/' && to.charAt(1) !== '/') ? to : '/dashboard';
    }
    function leaveLogin() {
      var cur = router.currentRoute.value;
      if (cur.path === '/login') { ensure(); router.replace(target(cur)); }
    }
    ensure();
    router.afterEach(function () { setTimeout(leaveLogin, 0); });
    router.isReady().then(leaveLogin);
  }
  start(0);
})();
