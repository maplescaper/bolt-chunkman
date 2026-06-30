// The "chunk unlocked" / "chunk complete" celebration popup. Registers the two
// message types the Lua side sends (see src/ui.lua showCongrats / showTasksComplete)
// and renders each into the shared card before playing the animation.
(function () {
  // a chunk was newly unlocked
  Popup.on("congrats", (msg) => {
    Popup.setTitle("Chunk Unlocked");
    Popup.setSub('You unlocked chunk <b id="chunkId"></b>');
    document.getElementById("chunkId").textContent = msg.id;
    Popup.setRegion("region " + msg.rx + ", " + msg.rz);
    Popup.play();
  });

  // every active task on the chunk is now complete
  Popup.on("complete", (msg) => {
    Popup.setTitle("Chunk Complete");
    Popup.setSub("<b></b> Tasks Complete");
    Popup.subEl.querySelector("b").textContent = msg.done + "/" + msg.total;
    Popup.setRegion("");
    Popup.play();
  });
})();
