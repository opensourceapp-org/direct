const portInput = document.querySelector('#port');
const toggle = document.querySelector('#toggle');
const error = document.querySelector('#error');
const share = document.querySelector('#share');
const urls = document.querySelector('#urls');
const users = document.querySelector('#users');
const empty = document.querySelector('#empty');
let shownUrls = '';

function showError(message) {
  error.hidden = !message;
  error.textContent = message || '';
}

function renderUrls(status) {
  urls.replaceChildren();
  for (const url of status.urls) {
    const item = document.createElement('li');
    item.className = 'url';
    const code = document.createElement('code');
    code.textContent = url;
    const copy = document.createElement('button');
    copy.type = 'button';
    copy.className = 'secondary';
    copy.textContent = 'Copy';
    copy.addEventListener('click', async () => {
      await window.directServer.copy(url);
      copy.textContent = 'Copied';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1200);
    });
    item.append(code, copy);
    urls.append(item);
  }
  if (status.running && status.urls.length === 0) {
    const item = document.createElement('li');
    item.className = 'hint';
    item.textContent = 'No local network address was found. Use a tunnel or this computer’s public address on both phones.';
    urls.append(item);
  }
}

function render(status) {
  const live = Boolean(status.running);
  portInput.disabled = live;
  toggle.textContent = live ? 'Stop server' : 'Start server';
  toggle.classList.toggle('secondary', live);
  showError(status.error);
  share.hidden = !live;
  const urlKey = `${live}\n${(status.urls || []).join('\n')}`;
  if (urlKey !== shownUrls) {
    shownUrls = urlKey;
    renderUrls(status);
  }
  users.replaceChildren();
  for (const user of status.users || []) {
    const item = document.createElement('li');
    item.className = 'user';
    const name = document.createElement('strong');
    name.textContent = user.name || 'Unnamed';
    const id = document.createElement('code');
    id.textContent = user.directId;
    item.append(name, id);
    users.append(item);
  }
  empty.hidden = (status.users || []).length > 0;
}

async function refresh() {
  render(await window.directServer.status());
}

toggle.addEventListener('click', async () => {
  const status = toggle.classList.contains('secondary')
    ? await window.directServer.stop()
    : await window.directServer.start(portInput.value);
  render(status);
});

refresh();
setInterval(refresh, 1000);
