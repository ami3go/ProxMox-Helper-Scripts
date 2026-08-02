(() => {
  const navToggle = document.querySelector('.nav-toggle');
  const nav = document.querySelector('.site-nav');

  if (navToggle && nav) {
    navToggle.addEventListener('click', () => {
      const open = nav.classList.toggle('open');
      navToggle.setAttribute('aria-expanded', String(open));
    });

    nav.addEventListener('click', (event) => {
      if (event.target instanceof HTMLAnchorElement) {
        nav.classList.remove('open');
        navToggle.setAttribute('aria-expanded', 'false');
      }
    });
  }

  document.querySelectorAll('[data-copy-target]').forEach((button) => {
    button.addEventListener('click', async () => {
      const target = document.getElementById(button.dataset.copyTarget);
      if (!target) return;
      try {
        await navigator.clipboard.writeText(target.textContent.trim());
        const previous = button.textContent;
        button.textContent = 'Copied';
        window.setTimeout(() => { button.textContent = previous; }, 1600);
      } catch {
        button.textContent = 'Select text';
      }
    });
  });

  const catalog = document.getElementById('helper-catalog');
  const count = document.getElementById('helper-count');
  const error = document.getElementById('catalog-error');

  const renderCatalog = async () => {
    if (!catalog) return;
    try {
      const response = await fetch('data/helpers.json', { cache: 'no-store' });
      if (!response.ok) throw new Error(`Catalog request failed: ${response.status}`);
      const payload = await response.json();
      const helpers = Array.isArray(payload.helpers) ? payload.helpers : [];
      if (count) count.textContent = String(helpers.length);
      catalog.replaceChildren(...helpers.map((helper) => {
        const card = document.createElement('article');
        card.className = 'catalog-card';

        const heading = document.createElement('div');
        heading.className = 'catalog-heading';
        const title = document.createElement('h3');
        title.textContent = helper.name;
        const version = document.createElement('span');
        version.className = 'version-badge';
        version.textContent = `v${helper.version}`;
        heading.append(title, version);

        const metadata = document.createElement('p');
        metadata.className = 'catalog-meta';
        metadata.textContent = `${helper.category} · ${helper.target} · ${helper.id}`;

        const description = document.createElement('p');
        description.textContent = helper.description;

        const command = document.createElement('code');
        command.className = 'catalog-command';
        command.textContent = `./bin/proxmox-helper-scripts run ${helper.id}`;

        const downloads = document.createElement('div');
        downloads.className = 'catalog-downloads';
        const bundle = document.createElement('a');
        bundle.className = 'button secondary';
        bundle.href = `downloads/${helper.bundle}`;
        bundle.textContent = 'Download bundle';
        downloads.append(bundle);
        if (helper.standalone) {
          const standalone = document.createElement('a');
          standalone.className = 'button secondary';
          standalone.href = `downloads/${helper.id}.sh`;
          standalone.textContent = 'Standalone script';
          downloads.append(standalone);
        }

        card.append(heading, metadata, description, command, downloads);
        return card;
      }));
    } catch (catalogError) {
      catalog.replaceChildren();
      if (error) error.hidden = false;
      console.error(catalogError);
    }
  };

  renderCatalog();
})();
