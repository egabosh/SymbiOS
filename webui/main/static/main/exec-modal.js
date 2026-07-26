/* SymbiOS exec output modal — shows live command output in an overlay.

Usage:
  SymbiOS.exec.start(jobId, title)  — open modal and poll a job
  SymbiOS.exec.open(title)          — open modal with spinner (no job yet)
  SymbiOS.exec.close()              — close modal
  SymbiOS.exec.isRunning()          — true while a job is being polled

Also intercepts all forms with data-exec="true" attribute:
  - Submits via AJAX (fetch)
  - If response contains a job id, opens the modal and polls it
  - If response is a redirect, follows it
  - Prevents double-execution while a job is running
*/
(function () {
  'use strict';

  const overlay = document.getElementById('execOverlay');
  const outputEl = document.getElementById('execOutput');
  const titleEl = document.getElementById('execTitle');
  const statusEl = document.getElementById('execStatus');
  const closeBtn = document.getElementById('execClose');
  const doneBtn = document.getElementById('execDone');
  const commandWrap = document.getElementById('execCommandWrap');
  const commandEl = document.getElementById('execCommand');

  let pollTimer = null;
  let running = false;
  let currentJob = null;
  let rawLen = 0;
  let _needsReload = false;

  /* Read CSRF token from cookie for fetch() POST requests */
  function getCsrfToken() {
    var name = 'csrftoken';
    if (document.cookie && document.cookie !== '') {
      var cookies = document.cookie.split(';');
      for (var i = 0; i < cookies.length; i++) {
        var cookie = cookies[i].trim();
        if (cookie.substring(0, name.length + 1) === (name + '=')) {
          return decodeURIComponent(cookie.substring(name.length + 1));
        }
      }
    }
    return '';
  }

  /* Append only the new tail of raw output as rendered HTML.
     Tracks the previous raw length so we only render the delta. */
  function appendDelta(raw) {
    if (!raw || raw.length <= rawLen) return;
    const delta = raw.slice(rawLen);
    rawLen = raw.length;
    const nearBottom = outputEl.scrollHeight - outputEl.scrollTop - outputEl.clientHeight < 60;
    outputEl.insertAdjacentHTML('beforeend', ansiToHtml(delta));
    if (nearBottom) outputEl.scrollTop = outputEl.scrollHeight;
  }

  function poll() {
    if (!currentJob) return;
    fetch('/exec/output/?job=' + currentJob)
      .then(function (r) { return r.json(); })
      .then(function (d) {
        appendDelta(d.output || '');
        if (d.done) {
          finish(d.success);
          return;
        }
        pollTimer = setTimeout(poll, 1000);
      })
      .catch(function () {
        pollTimer = setTimeout(poll, 2000);
      });
  }

  function finish(success) {
    running = false;
    currentJob = null;
    if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
    statusEl.innerHTML = success
      ? '<i class="bi bi-check-circle-fill text-success me-1"></i>Completed successfully'
      : '<i class="bi bi-x-circle-fill text-danger me-1"></i>Failed';
    doneBtn.classList.remove('d-none');
    /* Remove the spinner from the status line */
    var spinner = statusEl.querySelector('.spinner-border');
    if (spinner) spinner.remove();
    /* Reload page on close to reflect updated data */
    _needsReload = true;
  }

  function open(title, command) {
    outputEl.innerHTML = '';
    outputEl.dataset.rawLen = '0';
    rawLen = 0;
    titleEl.innerHTML = '<i class="bi bi-terminal me-2"></i>' + escapeHtml(title || 'Running command...');
    if (command) {
      commandEl.textContent = command;
      commandWrap.classList.remove('d-none');
    } else {
      commandWrap.classList.add('d-none');
    }
    statusEl.innerHTML = '<span class="spinner-border spinner-border-sm me-1" role="status"></span>Executing...';
    doneBtn.classList.add('d-none');
    overlay.classList.remove('d-none');
    document.body.style.overflow = 'hidden';
    running = true;
  }

  function close() {
    if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
    currentJob = null;
    running = false;
    overlay.classList.add('d-none');
    document.body.style.overflow = '';
    if (_needsReload) {
      _needsReload = false;
      window.location.reload();
    }
  }

  function start(jobId, title, command) {
    open(title, command);
    currentJob = jobId;
    poll();
  }

  /* Close handlers */
  closeBtn.addEventListener('click', close);
  doneBtn.addEventListener('click', close);
  /* Clicking the backdrop does NOT close the modal — only the X or Close button */
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && !overlay.classList.contains('d-none')) close();
  });

  /* ------------------------------------------------------------------ */
  /* Form interception: forms with data-exec="true" submit via AJAX.     */
  /* If the response contains a job id, the modal opens and polls it.    */
  /* ------------------------------------------------------------------ */
  document.addEventListener('submit', function (e) {
    var form = e.target;
    if (!form.dataset.exec) return;
    if (running) return;  /* prevent double-execution */
    e.preventDefault();

    var fd = new FormData(form);
    var url = form.action || window.location.href;
    var method = form.method || 'POST';

    /* Add headers so the view returns JSON and CSRF validation passes */
    fetch(url, {
      method: method,
      body: fd,
      credentials: 'same-origin',
      headers: {
        'X-Requested-With': 'XMLHttpRequest',
        'X-CSRFToken': getCsrfToken()
      }
    })
      .then(function (r) {
        return r.json().then(function (data) {
          return { status: r.status, data: data };
        });
      })
      .then(function (res) {
        var d = res.data;
        if (res.status >= 400) {
          /* Show error in a Bootstrap alert instead of the modal */
          showAlert(d.error || 'An error occurred', 'danger');
          return;
        }
        if (d.job) {
          start(d.job, d.title || 'Running...', d.command);
          if (d.message) showAlert(d.message, 'success');
        } else if (d.redirect) {
          window.location.href = d.redirect;
        } else {
          /* No job — just reload the page to show Django messages */
          window.location.reload();
        }
      })
      .catch(function (err) {
        showAlert('Network error: ' + err, 'danger');
      });
  });

  /* Show a dismissible Bootstrap alert at the top of the content area */
  function showAlert(message, type) {
    var container = document.querySelector('.col.py-3');
    if (!container) return;
    var icons = { success: 'check-circle-fill', danger: 'exclamation-triangle-fill', warning: 'info-circle-fill', info: 'info-circle-fill' };
    var alert = document.createElement('div');
    alert.className = 'alert alert-' + type + ' alert-dismissible fade show';
    alert.innerHTML =
      '<i class="bi bi-' + (icons[type] || 'info-circle-fill') + ' me-2"></i>' +
      '<span>' + escapeHtml(message) + '</span>' +
      '<button type="button" class="btn-close" data-bs-dismiss="alert"></button>';
    /* Insert after any existing messages */
    var first = container.querySelector('.alert');
    if (first) {
      first.parentNode.insertBefore(alert, first);
    } else {
      container.insertBefore(alert, container.firstChild);
    }
  }

  /* Public API */
  window.SymbiOS = window.SymbiOS || {};
  window.SymbiOS.exec = {
    start: start,
    open: open,
    close: close,
    isRunning: function () { return running; },
    showAlert: showAlert
  };
})();
