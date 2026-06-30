// The "task complete" popup, shown when an individual task is ticked off in the
// tasks panel (see src/tasks/client.lua). Smaller and sparkle-free: just the
// heading with the completed task's name beneath it.
(function () {
  Popup.on("task", (msg) => {
    Popup.setTitle("Task Complete");
    Popup.subEl.textContent = msg.name || "";   // task name is plain text, not HTML
    Popup.setRegion("");
    Popup.play();
  });
})();
