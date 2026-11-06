// Keep idle state outside server assigns: a LiveView patch is not user activity.
// Execute the shared HEEx commands so aria-pressed stays sticky across patches.
const activityEvents = ["pointerdown", "click", "keydown", "wheel", "scroll", "touchstart", "touchmove"]
const wakeEvents = new Set(["pointerdown", "click", "keydown", "touchstart"])

export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.window = this.document.defaultView
    this.lastActivity = this.window.Date.now()
    this.idle = false
    this.playerActive = false
    this.wasHidden = !!this.document.hidden

    this.onActivity = event => {
      // A throttled timer may not have run yet after tab/system sleep.
      this.expireIfNeeded()
      this.lastActivity = this.window.Date.now()
      if (wakeEvents.has(event.type) && !(event.type === "keydown" && event.key === "Escape")) {
        if (this.idle || this.el.querySelector("#workspace-pane").getAttribute("aria-pressed") !== "true") {
          this.command("focus")
        }
        this.idle = false
      }
      this.schedule()
    }
    this.onVisibility = () => {
      if (this.document.hidden && this.playerActive) {
        this.playerActive = false
        this.lastActivity = this.window.Date.now()
      }
      this.expireIfNeeded(this.wasHidden)
      this.wasHidden = !!this.document.hidden
      this.schedule()
    }
    this.onPlayerFocus = () => {
      const focused = this.playerFocused()
      if (focused || this.playerActive) {
        this.playerActive = focused
        this.lastActivity = this.window.Date.now()
        this.schedule()
      }
    }
    this.onWindowBlur = () => {
      this.window.clearTimeout(this.focusTimer)
      this.focusTimer = this.window.setTimeout(this.onPlayerFocus, 0)
    }
    this.onModalClosed = () => {
      this.lastActivity = this.window.Date.now()
      this.schedule()
    }
    this.document.addEventListener("lovelace:modal-closed", this.onModalClosed)

    // Capture scroll (which doesn't bubble) and input without preventing its
    // normal action or moving keyboard focus. Mouse movement is never observed.
    for (const event of activityEvents) {
      this.document.addEventListener(event, this.onActivity, {capture: true, passive: true})
    }
    this.document.addEventListener("visibilitychange", this.onVisibility)
    this.document.addEventListener("focusin", this.onPlayerFocus)
    this.window.addEventListener("blur", this.onWindowBlur)
    this.schedule()
  },

  duration() {
    const minutes = Number(this.el.dataset.idleMinutes)
    return (Number.isFinite(minutes) && minutes > 0 ? minutes : 3) * 60_000
  },

  command(name) {
    this.js().exec(this.el.getAttribute(`data-workspace-${name}`))
  },

  modalOpen() {
    // Presence also covers the patch before the dialog's hook calls showModal.
    return !!this.el.querySelector("dialog[data-modal]")
  },

  playerFocused() {
    return !this.document.hidden &&
      !!this.document.activeElement?.matches?.("[data-youtube-player-host] iframe")
  },

  expireIfNeeded(returningFromHidden = false) {
    if (this.modalOpen()) return
    // Cross-origin player input cannot reach this document. Visible player
    // focus suspends scenery idle; returning from a hidden tab still expires.
    if (!returningFromHidden && this.playerFocused()) {
      this.playerActive = true
      this.lastActivity = this.window.Date.now()
      return
    }
    if (!this.idle && this.window.Date.now() - this.lastActivity >= this.duration()) {
      this.idle = true
      // This command sets aria-pressed=false AND resets the independent brand.
      // CSS visually defocuses content; never call DOM blur(): the next key
      // should still reach the existing control, sharpening it before input.
      this.command("reset")
    }
  },

  schedule() {
    this.window.clearTimeout(this.timer)
    if (this.idle || this.modalOpen()) return
    const remaining = this.playerFocused() ? this.duration() :
      this.duration() - (this.window.Date.now() - this.lastActivity)
    this.timer = this.window.setTimeout(() => {
      this.expireIfNeeded()
      this.schedule()
    }, Math.min(Math.max(remaining, 1), 2_147_483_647))
  },

  updated() {
    // New background/status/config markup must not renew the activity timestamp.
    this.expireIfNeeded()
    this.schedule()
  },

  destroyed() {
    this.window.clearTimeout(this.timer)
    this.window.clearTimeout(this.focusTimer)
    for (const event of activityEvents) {
      this.document.removeEventListener(event, this.onActivity, true)
    }
    this.document.removeEventListener("visibilitychange", this.onVisibility)
    this.document.removeEventListener("lovelace:modal-closed", this.onModalClosed)
    this.document.removeEventListener("focusin", this.onPlayerFocus)
    this.window.removeEventListener("blur", this.onWindowBlur)
  },
}
