/*
 * SymbiOS WebUI - block device helpers.
 *
 * RAID members are frequently mappers (/dev/mapper/symbios-media-1) or
 * partitions (/dev/sdb3). Neither carries a model or a serial, so two
 * identical disks cannot be told apart from a member list alone - which is
 * exactly what is needed when one of them has to be replaced.
 *
 * Every disk related page already loads the full lsblk tree from
 * /settings/disk/list/. This helper indexes that tree and walks up from a
 * member to the physical disk that holds it, so the templates can show the
 * disk path, serial, model and transport next to the member.
 *
 * Paths follow the kernel/udev view: a mapper node keeps its mapper name
 * (symbios-media-1) and is reported as /dev/mapper/symbios-media-1.
 *
 * A disk flagged by the disk healthcheck carries a `health` object on its
 * node (severity fail/warn, alert list) - the RAID member inherits it through
 * the same walk, so a failing disk is marked on every page that shows it.
 *
 * API:
 *   SymbiOS.blockdev.index(devices)     index the lsblk tree (per data load)
 *   SymbiOS.blockdev.describe(path)     resolved disk info for one device
 *   SymbiOS.blockdev.memberHtml(path)   two line HTML for table cells
 *   SymbiOS.blockdev.memberLabel(path)  one line text for <option> elements
 *   SymbiOS.blockdev.healthBadge(health)  badge HTML for a flagged disk
 *   SymbiOS.blockdev.alertHtml(health)    alert list HTML for a flagged disk
 */
window.SymbiOS = window.SymbiOS || {};
window.SymbiOS.blockdev = (function() {
  var byName = {};    /* device name (sdb, sdb3, symbios-media-1) -> node */
  var parentOf = {};  /* child path -> parent node */

  /* Walk the tree once and remember every node and its parent. */
  function walk(node, parent) {
    if (!node || !node.name) return;
    byName[node.name] = node;
    if (parent) parentOf[node.path] = parent;
    (node.children || []).forEach(function(child) { walk(child, node); });
  }

  /* Rebuild the index from a fresh lsblk tree. */
  function index(devices) {
    byName = {};
    parentOf = {};
    (devices || []).forEach(function(dev) { walk(dev, null); });
  }

  /* Find a node by path. Mapper paths (/dev/mapper/x) and kernel names
     (/dev/dm-1, /dev/sdb3) both resolve through the device name. */
  function nodeFor(path) {
    if (!path) return null;
    return byName[String(path).split('/').pop()] || null;
  }

  /* Climb to the physical disk (or loopback) that holds the node. */
  function diskOf(node) {
    var cur = node;
    while (cur && cur.type !== 'disk' && cur.type !== 'loop') {
      cur = parentOf[cur.path] || null;
    }
    return cur;
  }

  /* Resolved device description used by the templates. */
  function describe(path) {
    var node = nodeFor(path);
    var disk = node ? diskOf(node) : null;
    return {
      path: path,
      known: !!node,
      mapper: !!node && node.type === 'crypt',
      via: node && disk && node !== disk ? node.path : '',
      diskPath: disk ? disk.path : '',
      model: disk ? (disk.model || '') : '',
      serial: disk ? (disk.serial || '') : '',
      byid: disk ? (disk.byid || '') : '',
      tran: disk ? (disk.tran || '') : '',
      ident: disk ? (disk.serial || disk.byid || '') : '',
      health: disk && disk.health ? disk.health : null
    };
  }

  /* Escape a value for safe use in HTML text and attributes. */
  function esc(text) {
    return String(text == null ? '' : text).replace(/[&<>"]/g, function(c) {
      return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c];
    });
  }

  /* Severity of a health entry: 'fail', 'warn' or '' (not flagged). */
  function sevOf(health) {
    if (!health) return '';
    if (health.severity === 'fail') return 'fail';
    if (health.severity === 'warn') return 'warn';
    return '';
  }

  /* Badge HTML for a failed/warning disk. The alert texts become the
     tooltip, so a RAID member cell stays compact. */
  function healthBadge(health) {
    var sev = sevOf(health);
    if (!sev) return '';
    var cls = sev === 'fail' ? 'bg-danger' : 'bg-warning text-dark';
    var label = sev === 'fail' ? 'Defective' : 'Disk warning';
    if (health.snoozed) label += ' (acknowledged)';
    var alerts = health.alerts || [];
    var title = alerts.length ? ' title="' + esc(alerts.join(' | ')) + '"' : '';
    return '<span class="badge ' + cls + '"' + title + '>' + label + '</span>';
  }

  /* Alert list for the details area. */
  function alertHtml(health) {
    if (!sevOf(health) || !health.alerts || !health.alerts.length) return '';
    var items = health.alerts.map(function(a) { return '<li>' + esc(a) + '</li>'; }).join('');
    return '<ul class="mb-0 small">' + items + '</ul>';
  }

  /* One line label for <option> elements:
     "/dev/mapper/symbios-media-1 (on /dev/sdb3 -> /dev/sdb, VJH5312X, ...)" */
  function memberLabel(path) {
    var info = describe(path);
    if (!info.diskPath) return path;
    var parts = [info.diskPath];
    if (info.ident) parts.push(info.ident);
    if (info.model) parts.push(info.model);
    var via = info.via && info.via !== path ? 'on ' + info.via + ' -> ' : '';
    var prefix = '';
    if (sevOf(info.health) === 'fail') prefix = '[DEFECTIVE] ';
    else if (sevOf(info.health)) prefix = '[WARNING] ';
    return prefix + path + ' (' + via + parts.join(', ') + ')';
  }

  /* Two line HTML for table cells: the member path plus its physical disk. */
  function memberHtml(path) {
    var info = describe(path);
    var html = '<code>' + esc(path) + '</code>' + healthBadge(info.health);
    if (!info.diskPath) return html;
    var chain = [];
    if (info.via && info.via !== path) chain.push(esc(info.via));
    chain.push(esc(info.diskPath));
    var details = [chain.join(' &rarr; ')];
    if (info.ident) details.push(esc(info.ident));
    if (info.model) details.push(esc(info.model));
    if (info.tran) details.push(esc(info.tran));
    var title = info.byid ? ' title="' + esc(info.byid) + '"' : '';
    return html + '<div class="text-muted small"' + title + '>' +
      details.join(' &middot; ') + '</div>';
  }

  return {
    index: index,
    describe: describe,
    memberHtml: memberHtml,
    memberLabel: memberLabel,
    healthBadge: healthBadge,
    alertHtml: alertHtml
  };
})();
