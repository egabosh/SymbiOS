/* Shared sidebar behaviour for the settings and services menus.
 *
 * Expert mode: expert items are hidden until enabled (localStorage).
 * Collapse state: every collapsible group remembers its open/closed state.
 * Active item: the link matching the current path is highlighted and its group
 * expanded; expert-only pages auto-enable expert mode so the marker is visible.
 */
(function () {
  'use strict';

  var PREFIX = 'symbios_sidebar_v1_';
  var EXPERT_KEY = PREFIX + 'expert';
  var COLLAPSED_KEY = PREFIX + 'collapsed';

  function storageGet(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
  }
  function storageSet(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* private mode */ }
  }
  function isExpert() { return storageGet(EXPERT_KEY) === '1'; }

  function collapsedState() {
    try {
      var parsed = JSON.parse(storageGet(COLLAPSED_KEY) || '{}');
      return (parsed && typeof parsed === 'object') ? parsed : {};
    } catch (e) { return {}; }
  }
  function saveCollapsed(id, collapsed) {
    var state = collapsedState();
    state[id] = collapsed;
    storageSet(COLLAPSED_KEY, JSON.stringify(state));
  }

  function cleanPath(path) {
    if (!path || path === '/') return '/';
    return path.replace(/\/+$/, '');
  }

  function findActiveLink() {
    var path = cleanPath(window.location.pathname);
    var links = document.querySelectorAll('.sidebar a.svc-item');
    var found = null;
    for (var i = 0; i < links.length; i++) {
      var href = cleanPath(links[i].getAttribute('href') || '');
      if (href && href === path) found = links[i];
    }
    return found;
  }

  function applyMode() {
    var expert = isExpert();
    document.body.classList.toggle('sb-expert', expert);

    var labels = document.querySelectorAll('[data-sidebar-mode]');
    for (var i = 0; i < labels.length; i++) {
      var span = labels[i];
      span.textContent = expert
        ? span.getAttribute('data-collapse-label')
        : span.getAttribute('data-expand-label');
      var btn = span.closest('button');
      if (btn) btn.setAttribute('aria-pressed', expert ? 'true' : 'false');
    }

    // A group with no visible item in the current mode is hidden entirely.
    var groups = document.querySelectorAll('.sidebar-group');
    for (var j = 0; j < groups.length; j++) {
      var group = groups[j];
      var items = group.querySelectorAll('a.svc-item[data-level]');
      var visible = 0;
      for (var k = 0; k < items.length; k++) {
        if (items[k].getAttribute('data-level') !== 'expert' || expert) visible++;
      }
      group.style.display = visible ? '' : 'none';
    }
  }

  function collapseInstance(el) {
    if (!window.bootstrap || !window.bootstrap.Collapse) return null;
    return window.bootstrap.Collapse.getOrCreateInstance(el, {toggle: false});
  }

  function restoreCollapses() {
    var state = collapsedState();
    var collapses = document.querySelectorAll('.sidebar .collapse[id]');
    for (var i = 0; i < collapses.length; i++) {
      var el = collapses[i];
      var saved = state[el.id];
      var defaultClosed = el.getAttribute('data-default-collapsed') === 'true';
      if (saved === false) {
        // A remembered expanded state must be restored, not just left alone:
        // the markup renders these groups closed on every page load.
        var inst = collapseInstance(el);
        if (inst) inst.show();
      } else if (saved === true || (saved === undefined && defaultClosed)) {
        var inst = collapseInstance(el);
        if (inst) inst.hide();
      }
      // Persist later user toggles (closure keeps the right element id).
      (function (target) {
        target.addEventListener('shown.bs.collapse', function () { saveCollapsed(target.id, false); });
        target.addEventListener('hidden.bs.collapse', function () { saveCollapsed(target.id, true); });
      })(el);
    }
  }

  function finalizeActive() {
    var active = findActiveLink();
    if (!active) return;
    active.classList.add('active');
    if (active.getAttribute('data-level') === 'expert' && !isExpert()) {
      storageSet(EXPERT_KEY, '1');
      applyMode();
    }
    var collapse = active.closest('.collapse');
    if (collapse) {
      var inst = collapseInstance(collapse);
      if (inst) inst.show();
    }
  }

  document.addEventListener('DOMContentLoaded', function () {
    var toggle = document.getElementById('sidebarExpertToggle');
    if (toggle) {
      toggle.addEventListener('click', function () {
        storageSet(EXPERT_KEY, isExpert() ? '0' : '1');
        applyMode();
        finalizeActive();
      });
    }
    applyMode();
    restoreCollapses();
    finalizeActive();
  });
})();
