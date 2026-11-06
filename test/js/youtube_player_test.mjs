import assert from "node:assert/strict"
import test from "node:test"
import YouTubePlayer, {embedURL} from "../../assets/js/hooks/youtube_player.js"

class Target {
  listeners = new Map()
  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set())
    this.listeners.get(name).add(callback)
  }
  removeEventListener(name, callback) { this.listeners.get(name)?.delete(callback) }
  emit(name, event = {}) { for (const callback of this.listeners.get(name) ?? []) callback(event) }
  count() { return [...this.listeners.values()].reduce((n, callbacks) => n + callbacks.size, 0) }
}

function fixture(t) {
  const root = new Target(), document = new Target(), window = new Target()
  const frames = [], load = {hidden: false, focus() { document.activeElement = this }},
    unload = {hidden: true, focus() { document.activeElement = this }}, status = {}
  root.dataset = {accountId: "account-a", generation: "generation-a", revision: "selection-a", selection: "channel-a", videoId: "aaaaaaaaaaa"}
  root.ownerDocument = document
  document.defaultView = window
  document.createElement = name => {
    assert.equal(name, "iframe")
    const frame = {remove() { frames.splice(frames.indexOf(frame), 1) }}
    return frame
  }
  root.querySelectorAll = () => [...frames]
  root.querySelector = selector => ({
    "[data-youtube-player-host]": {append(frame) { frames.push(frame) }},
    "[data-youtube-load]": load, "[data-youtube-unload]": unload,
    "[data-youtube-player-status]": status,
  })[selector]
  let serverStop
  const hook = Object.assign({}, YouTubePlayer, {el: root,
    handleEvent(name, callback) { assert.equal(name, "youtube:stop"); serverStop = callback; return "stop-handler" },
    removeHandleEvent(id) { assert.equal(id, "stop-handler"); serverStop = null },
  })
  const click = (trusted = true) => root.emit("click", {isTrusted: trusted,
    target: {closest(selector) { return selector === "[data-youtube-load]" ? load : null }}})
  hook.mounted()
  t.after(() => hook.destroyed())
  return {root, document, window, hook, frames, load, unload, click, serverStop: () => serverStop()}
}

test("only exact validated IDs produce the official no-autoplay privacy-enhanced URL", () => {
  assert.equal(embedURL("aA0_-123456"), "https://www.youtube-nocookie.com/embed/aA0_-123456?autoplay=0&rel=0")
  for (const id of [null, "short", "aaaaaaaaaaa?autoplay=1", "https://evil.test", "aaaaaaaaaa/", "aaaaaaaaaaa\n"]) assert.equal(embedURL(id), null)
})

test("mount, patch, synthetic activation and reconnection never authorize a player", t => {
  const {hook, frames, click} = fixture(t)
  assert.equal(frames.length, 0)
  hook.updated()
  click(false)
  assert.equal(frames.length, 0)
  click()
  assert.equal(frames.length, 1)
  assert.equal(frames[0].referrerPolicy, "strict-origin-when-cross-origin")
  hook.disconnected()
  assert.equal(frames.length, 0)
  hook.updated()
  assert.equal(frames.length, 0)
})

test("a disconnected surface refuses a fresh load until its LiveView reconnects", t => {
  const {hook, frames, click} = fixture(t)
  hook.disconnected()
  click()
  assert.equal(frames.length, 0)
  hook.reconnected()
  assert.equal(frames.length, 0)
  click()
  assert.equal(frames.length, 1)
})

test("explicit Unload restores Load focus but unrelated revocation does not steal focus", t => {
  const f = fixture(t)
  f.click()
  assert.equal(f.document.activeElement, f.unload)
  f.root.emit("click", {target: {closest: selector => selector === "[data-youtube-unload]" ? f.unload : null}})
  assert.equal(f.frames.length, 0)
  assert.equal(f.document.activeElement, f.load)
  f.click()
  const otherControl = {}
  f.document.activeElement = otherControl
  f.serverStop()
  assert.equal(f.document.activeElement, otherControl)
})

test("account, generation, revision, selection and video changes independently revoke the browsing context", async t => {
  for (const field of ["accountId", "generation", "revision", "selection", "videoId"]) {
    await t.test(field, t => {
      const {root, hook, click, frames} = fixture(t)
      click()
      assert.equal(frames.length, 1)
      root.dataset[field] = "changed"
      hook.updated()
      assert.equal(frames.length, 0)
    })
  }
})

test("Escape, idle reset, Lock, route leave, page leave and server invalidation stop playback", async t => {
  for (const stop of [f => f.document.emit("keydown", {key: "Escape"}),
    f => f.document.emit("lovelace:player-stop"),
    f => f.document.emit("submit", {target: {id: "owner-lock-form"}}),
    f => f.window.emit("phx:page-loading-start"),
    f => f.window.emit("pagehide"), f => f.serverStop()]) {
    await t.test("revocation", t => {
      const f = fixture(t)
      f.click()
      assert.equal(f.frames.length, 1)
      stop(f)
      assert.equal(f.frames.length, 0)
    })
  }
})

test("teardown removes listeners and the iframe without reviving on later events", t => {
  const f = fixture(t)
  f.click()
  f.hook.destroyed()
  assert.equal(f.frames.length, 0)
  assert.equal(f.root.count() + f.document.count() + f.window.count(), 0)
})
