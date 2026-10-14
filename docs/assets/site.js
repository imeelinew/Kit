// Keep the download in sync with the existing Sparkle release feed
async function updateRelease() {
  try {
    const response = await fetch('appcast.xml');
    if (!response.ok) return;
    const feed = new DOMParser().parseFromString(await response.text(), 'application/xml');
    if (feed.querySelector('parsererror')) return;
    const item = feed.querySelector('item');
    const url = item?.querySelector('enclosure')?.getAttribute('url');
    if (!url || !url.startsWith('https://github.com/imeelinew/Kit/releases/download/')) return;
    document.querySelector('[data-download]').href = url;
    const version = item.getElementsByTagNameNS('http://www.andymatuschak.org/xml-namespaces/sparkle', 'shortVersionString')[0]?.textContent;
    if (version) document.querySelector('[data-version]').textContent = `v${version}`;
  } catch {
    // The release page remains available when the feed cannot be loaded
  }
}
updateRelease();
