// Generic popup framework shared by every popup loaded into popup.html.
// It owns the card element, the entrance/exit animation, the sparkle burst and
// the Lua message bridge. A specific popup (popups/<name>.js) registers one
// handler per message type with Popup.on(type, fn) and fills the card in with
// the setTitle / setSub / setRegion helpers before calling Popup.play().
(function () {
  const card = document.getElementById("card");
  const titleEl = document.getElementById("title");
  const subEl = document.getElementById("sub");
  const regionEl = document.getElementById("region");

  const handlers = {};

  function sparkle() {
    const n = 14;
    for (let i = 0; i < n; i++) {
      const s = document.createElement("div");
      s.className = "spark";
      const ang = (Math.PI * 2 * i) / n + Math.random() * 0.4;
      const dist = 90 + Math.random() * 70;
      s.style.setProperty("--dx", Math.cos(ang) * dist + "px");
      s.style.setProperty("--dy", Math.sin(ang) * dist + "px");
      s.style.animationDelay = (Math.random() * 0.15) + "s";
      card.appendChild(s);
    }
  }

  // (re)play the pop animation, then fade out and ask Lua to close us. Sparkles
  // are a separate opt-in (Popup.sparkle), so a variant can play without them.
  function play() {
    // restart the pop animation in case the card is being reused
    card.classList.remove("out");
    card.style.animation = "none";
    void card.offsetWidth;
    card.style.animation = "";
    setTimeout(() => { card.classList.add("out"); }, 2600);
    setTimeout(() => { fetch("https://bolt-api/close-request"); }, 3200);
  }

  // The API exposed to the per-popup module loaded after this script.
  window.Popup = {
    card, titleEl, subEl, regionEl,
    // register a handler for an incoming message type
    on(type, fn) { handlers[type] = fn; },
    setTitle(text) { titleEl.textContent = text; },
    setSub(html) { subEl.innerHTML = html; },
    setRegion(text) { regionEl.textContent = text || ""; },
    sparkle,
    play,
    // tell Lua the handlers are registered and we're ready for a payload
    ready() { fetch("https://bolt-api/send-message", { method: "POST", body: "ready" }); },
  };

  window.addEventListener("message", (event) => {
    if (typeof event.data !== "object" || !event.data) return;
    if (event.data.type !== "pluginMessage") return;
    let msg;
    try { msg = JSON.parse(new TextDecoder().decode(event.data.content)); }
    catch (err) { return; }
    const fn = handlers[msg && msg.type];
    if (fn) fn(msg);
  });
})();
