// No remote API script and no player state in LiveView. A fresh local button
// activation is the only place that creates an iframe or assigns its URL.
export function embedURL(id) {
  return typeof id === "string" && id.length === 11 && /^[A-Za-z0-9_-]{11}$/.test(id)
    ? `https://www.youtube-nocookie.com/embed/${id}?autoplay=0&rel=0`
    : null
}

export default {
  mounted() {
    this.document = this.el.ownerDocument
    this.window = this.document.defaultView
    this.identity = this.fence()
    this.connected = true
    this.load = event => {
      if (!this.connected || !event.isTrusted || !event.target.closest("[data-youtube-load]")) return
      const url = embedURL(this.el.dataset.videoId)
      if (!url || this.identity !== this.fence()) return
      this.stop()
      const frame = this.document.createElement("iframe")
      frame.title = "Official YouTube video player"
      frame.referrerPolicy = "strict-origin-when-cross-origin"
      frame.allow = "encrypted-media; fullscreen; picture-in-picture"
      frame.allowFullscreen = true
      frame.src = url
      this.el.querySelector("[data-youtube-player-host]").append(frame)
      this.loaded = true
      this.controls()
      this.el.querySelector("[data-youtube-unload]").focus()
    }
    this.unload = event => {
      if (event.target.closest("[data-youtube-unload]")) {
        this.stop()
        this.el.querySelector("[data-youtube-load]").focus()
      }
    }
    this.stop = () => {
      // Removing the browsing context stops audio before visual scenery mode.
      for (const frame of this.el.querySelectorAll("iframe")) frame.remove()
      this.loaded = false
      this.controls()
    }
    this.onKey = event => { if (event.key === "Escape") this.stop() }
    this.onLock = event => { if (event.target.id === "owner-lock-form") this.stop() }
    this.el.addEventListener("click", this.load)
    this.el.addEventListener("click", this.unload)
    this.document.addEventListener("keydown", this.onKey, true)
    this.document.addEventListener("lovelace:player-stop", this.stop)
    this.document.addEventListener("submit", this.onLock, true)
    this.window.addEventListener("phx:page-loading-start", this.stop)
    this.window.addEventListener("pagehide", this.stop)
    this.stopEvent = this.handleEvent("youtube:stop", this.stop)
    this.controls()
  },
  fence() {
    return [this.el.dataset.accountId, this.el.dataset.generation, this.el.dataset.revision,
      this.el.dataset.selection, this.el.dataset.videoId].join("|")
  },
  controls() {
    this.el.querySelector("[data-youtube-load]").hidden = !!this.loaded
    this.el.querySelector("[data-youtube-unload]").hidden = !this.loaded
    this.el.querySelector("[data-youtube-player-status]").textContent = this.loaded
      ? "YouTube player loaded. Use its standard controls to play." : "Player unloaded. YouTube is not contacted until you load the player."
  },
  updated() {
    if (this.identity !== this.fence()) this.stop()
    this.identity = this.fence()
    this.controls()
  },
  disconnected() { this.connected = false; this.stop() },
  reconnected() { this.connected = true },
  destroyed() {
    this.stop()
    this.el.removeEventListener("click", this.load)
    this.el.removeEventListener("click", this.unload)
    this.document.removeEventListener("keydown", this.onKey, true)
    this.document.removeEventListener("lovelace:player-stop", this.stop)
    this.document.removeEventListener("submit", this.onLock, true)
    this.window.removeEventListener("phx:page-loading-start", this.stop)
    this.window.removeEventListener("pagehide", this.stop)
    this.removeHandleEvent(this.stopEvent)
  },
}
