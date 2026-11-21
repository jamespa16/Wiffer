// An external classic script: runs after the parse (as if deferred), so the
// body is there already.
document.addEventListener('DOMContentLoaded', function () {
  document.title = 'JS title ok';
});
console.log('external script ran, body ' + (document.body ? 'present' : 'missing'));
