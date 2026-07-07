// One-time informational notice, currently used for the world-map grey-out
// feature announcement (see src/worldmap.lua). Unlike the celebration popups it
// does NOT use Popup.play()'s fixed ~3s lifetime: it stays up until the "Got it"
// button is clicked, with a generous auto-dismiss as a fallback so it can never
// linger over the map forever.
(function () {
  function dismiss() {
    Popup.card.classList.add("out");
    setTimeout(() => { fetch("https://bolt-api/close-request"); }, 550);
  }

  Popup.on("notice", () => {
    Popup.setTitle("New: World Map Integration");
    Popup.setSub(
      "Locked chunks are now <b>greyed out on the world map</b>, so you can " +
      "see your unlocked area at a glance.<br>" +
      "You can turn this off any time in the settings panel (gear icon " +
      "&rarr; <b>World Map</b>)."
    );
    Popup.setRegion("");

    const btn = document.createElement("button");
    btn.id = "ok";
    btn.textContent = "Got it";
    btn.addEventListener("click", dismiss);
    Popup.card.appendChild(btn);

    setTimeout(dismiss, 20000);   // fallback auto-dismiss
  });
})();
