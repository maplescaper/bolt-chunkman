// Every-startup "switch your plugin update URL to GitHub" notice (shown from
// main.lua while cfg.showUpdateNotice is true). Like notice.js it stays up
// until dismissed rather than using Popup.play()'s short lifetime, and it has
// no auto-dismiss at all: the migration matters enough that the card waits for
// the user, however long they idle at the login screen.
// The OK button only closes the popup; it never touches the hidden toggle.
(function () {
  const URL = "https://github.com/maplescaper/bolt-chunkman#migrating-from-codeberg-to-github";

  function dismiss() {
    Popup.card.classList.add("out");
    setTimeout(() => { fetch("https://bolt-api/close-request"); }, 550);
  }

  // Copy via the async clipboard API when available, falling back to a
  // temporary textarea + execCommand for older CEF builds.
  function copyFallback() {
    const ta = document.createElement("textarea");
    ta.value = URL;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    ta.style.userSelect = "text";
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (err) {}
    ta.remove();
    return ok;
  }

  function copyUrl(btn) {
    const flash = (ok) => {
      btn.textContent = ok ? "Copied!" : "Copy failed";
      setTimeout(() => { btn.textContent = "Copy URL"; }, 1500);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(URL).then(
        () => flash(true),
        () => flash(copyFallback())
      );
    } else {
      flash(copyFallback());
    }
  }

  Popup.on("update", () => {
    Popup.setTitle("Chunk Man Plugin Moving to Github");
    Popup.setSub(
      "Please change this plugin's <b>update URL</b> " +
      "in the Bolt launcher to the new GitHub one. " +
      "Instructions are on the page below:"
    );
    Popup.setRegion("");

    const url = document.createElement("div");
    url.id = "url";
    url.textContent = URL;
    Popup.card.appendChild(url);

    const row = document.createElement("div");
    row.id = "buttons";

    const copy = document.createElement("button");
    copy.id = "copy";
    copy.textContent = "Copy URL";
    copy.addEventListener("click", () => copyUrl(copy));
    row.appendChild(copy);

    const ok = document.createElement("button");
    ok.id = "ok";
    ok.textContent = "OK";
    ok.addEventListener("click", dismiss);
    row.appendChild(ok);

    Popup.card.appendChild(row);
  });
})();
