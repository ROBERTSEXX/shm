const session_id = localStorage.getItem('session_id');
fetch('/shm/object.cgi?object=User&method=get_menu&session_id=' + session_id)
  .then(r => r.json())
  .then(data => {
    const menu = data.menu || [];
    const nav = document.getElementById('admin-nav');
    if (!nav) return;
    nav.innerHTML = '';
    menu.forEach(item => {
      const li = document.createElement('li');
      li.textContent = item;
      nav.appendChild(li);
    });
  });