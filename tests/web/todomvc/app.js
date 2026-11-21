// Vanilla-JS TodoMVC for Wiffer (Phase 9J). One model, one render function,
// event delegation on the list, the filter in location.hash, persistence in
// localStorage. document.title mirrors the state so the harness can follow.
(function () {
  'use strict';
  var KEY = 'todos-wiffer';
  var ENTER = 13, ESCAPE = 27;
  var todos = [];
  try { todos = JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { todos = []; }
  var nextId = todos.reduce(function (m, t) { return Math.max(m, t.id); }, 0) + 1;

  var $ = function (sel) { return document.querySelector(sel); };
  var newTodo = $('.new-todo'), list = $('.todo-list'), main = $('.main'), footer = $('.footer');
  var toggleAll = $('.toggle-all'), count = $('.todo-count'), clear = $('.clear-completed');

  function filter() {
    var h = location.hash.replace(/^#\/?/, '');
    return h === 'active' || h === 'completed' ? h : 'all';
  }
  function visible(t) {
    var f = filter();
    return f === 'all' || (f === 'active' ? !t.completed : t.completed);
  }
  function save() { localStorage.setItem(KEY, JSON.stringify(todos)); }
  function escapeHTML(s) {
    return s.replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; });
  }

  function render() {
    var html = '';
    todos.filter(visible).forEach(function (t) {
      html += '<li data-id="' + t.id + '"' + (t.completed ? ' class="completed"' : '') + '>' +
        '<div class="view"><input class="toggle" type="checkbox"' + (t.completed ? ' checked' : '') + '>' +
        '<label>' + escapeHTML(t.title) + '</label><button class="destroy"></button></div></li>';
    });
    list.innerHTML = html;
    var active = todos.filter(function (t) { return !t.completed; }).length;
    var done = todos.length - active;
    main.style.display = todos.length ? 'block' : 'none';
    footer.style.display = todos.length ? 'block' : 'none';
    toggleAll.checked = todos.length > 0 && active === 0;
    count.innerHTML = '<strong>' + active + '</strong> item' + (active === 1 ? '' : 's') + ' left';
    clear.style.display = done ? 'inline' : 'none';
    var links = document.querySelectorAll('.filters a');
    for (var i = 0; i < links.length; i++) {
      links[i].classList.toggle('selected', links[i].getAttribute('href') === '#/' + (filter() === 'all' ? '' : filter()));
    }
    document.title = 'TodoMVC ' + todos.length + ' ' + active + ' ' + filter();
    save();
  }

  function idOf(el) {
    var li = el.closest('li');
    return li ? Number(li.getAttribute('data-id')) : -1;
  }
  function find(id) {
    for (var i = 0; i < todos.length; i++) if (todos[i].id === id) return i;
    return -1;
  }

  newTodo.addEventListener('keydown', function (e) {
    if (e.keyCode !== ENTER) return;
    var title = newTodo.value.trim();
    if (!title) return;
    todos.push({ id: nextId++, title: title, completed: false });
    newTodo.value = '';
    render();
  });
  list.addEventListener('change', function (e) {
    if (!e.target.classList.contains('toggle')) return;
    var i = find(idOf(e.target));
    if (i >= 0) todos[i].completed = e.target.checked;
    render();
  });
  list.addEventListener('click', function (e) {
    if (!e.target.classList.contains('destroy')) return;
    var i = find(idOf(e.target));
    if (i >= 0) todos.splice(i, 1);
    render();
  });
  list.addEventListener('dblclick', function (e) {
    if (e.target.tagName !== 'LABEL') return;
    var li = e.target.closest('li'), i = find(idOf(e.target));
    if (i < 0) return;
    li.classList.add('editing');
    var input = document.createElement('input');
    input.className = 'edit';
    input.value = todos[i].title;
    li.appendChild(input);
    input.focus();
    var finish = function (keep) {
      if (keep) {
        var v = input.value.trim();
        if (v) todos[i].title = v; else todos.splice(i, 1);
      }
      render();
    };
    input.addEventListener('keydown', function (k) {
      if (k.keyCode === ENTER) finish(true);
      else if (k.keyCode === ESCAPE) finish(false);
    });
    input.addEventListener('blur', function () { finish(true); });
  });
  toggleAll.addEventListener('change', function () {
    var on = toggleAll.checked;
    todos.forEach(function (t) { t.completed = on; });
    render();
  });
  clear.addEventListener('click', function () {
    todos = todos.filter(function (t) { return !t.completed; });
    render();
  });
  window.addEventListener('hashchange', render);
  render();
})();
