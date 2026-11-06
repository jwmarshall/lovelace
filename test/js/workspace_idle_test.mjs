import assert from "node:assert/strict"
import test from "node:test"
import WorkspaceIdle from "../../assets/js/hooks/workspace_idle.js"
import StageBackground, {observeStageImage} from "../../assets/js/hooks/stage_background.js"

class FakeTarget {
  listeners = new Map()
  attributes = new Map()

  addEventListener(type, callback) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set())
    this.listeners.get(type).add(callback)
  }

  removeEventListener(type, callback) {
    this.listeners.get(type)?.delete(callback)
  }

  emit(type, details = {}) {
    const event = {type, ...details}
    for (const callback of this.listeners.get(type) ?? []) callback(event)
    return event
  }

  getAttribute(name) { return this.attributes.get(name) ?? null }
  setAttribute(name, value) { this.attributes.set(name, value) }
  get listenerCount() { return [...this.listeners.values()].reduce((n, listeners) => n + listeners.size, 0) }
}

class FakeClock extends FakeTarget {
  now = 0
  nextId = 0
  timers = new Map()
  Date = {now: () => this.now}

  setTimeout = (callback, delay) => {
    const id = ++this.nextId
    this.timers.set(id, {callback, at: this.now + delay})
    return id
  }

  clearTimeout = id => this.timers.delete(id)

  advance(ms, runTimers = true) {
    const end = this.now + ms
    if (runTimers) {
      while (true) {
        const next = [...this.timers].filter(([, timer]) => timer.at <= end)
          .sort((a, b) => a[1].at - b[1].at)[0]
        if (!next) break
        this.now = Math.max(this.now, next[1].at)
        this.timers.delete(next[0])
        next[1].callback()
      }
    }
    this.now = end
  }
}

function workspace(t, minutes = "3") {
  const clock = new FakeClock()
  const document = new FakeTarget()
  document.defaultView = clock
  const control = {blur() { assert.fail("idle must not blur the active control") }}
  document.activeElement = control
  const pane = new FakeTarget()
  pane.setAttribute("aria-pressed", "true")
  const root = new FakeTarget()
  root.ownerDocument = document
  root.dataset = {idleMinutes: minutes}
  root.querySelector = selector => {
    if (selector === "dialog[data-modal]") return root.modal ?? null
    assert.equal(selector, "#workspace-pane")
    return pane
  }
  root.setAttribute("data-workspace-focus", "focus-command")
  root.setAttribute("data-workspace-reset", "reset-command")
  const commands = []
  const brandEvents = []
  let stickyPressed = "true"
  const hook = Object.assign({}, WorkspaceIdle, {
    el: root,
    js: () => ({exec: command => {
      commands.push(command)
      assert.ok(["focus-command", "reset-command"].includes(command))
      stickyPressed = command === "focus-command" ? "true" : "false"
      pane.setAttribute("aria-pressed", stickyPressed)
      brandEvents.push(command === "focus-command" ? "lovelace:brand-focus" : "lovelace:brand-reset")
    }}),
  })
  hook.mounted()
  t.after(() => hook.destroyed())
  const patch = () => {
    // Model LiveView replaying sticky client commands over a server attribute.
    pane.setAttribute("aria-pressed", "false")
    pane.setAttribute("aria-pressed", stickyPressed)
    hook.updated()
  }
  return {clock, document, control, pane, root, hook, commands, brandEvents, patch}
}

test("three-minute deadline resets both focal plane and brand without blurring controls", t => {
  const {clock, pane, commands, brandEvents, document, control} = workspace(t)
  clock.advance(179_999)
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  clock.advance(1)
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.deepEqual(commands, ["reset-command"])
  assert.deepEqual(brandEvents, ["lovelace:brand-reset"])
  assert.equal(document.activeElement, control)
})

test("visible cross-origin player focus suspends idle and Tab return restarts its deadline", t => {
  const {clock, document, control, pane} = workspace(t)
  document.activeElement = {matches: selector => selector === "[data-youtube-player-host] iframe"}
  clock.emit("blur")
  clock.advance(0)
  clock.advance(600_000)
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  document.activeElement = control
  document.emit("focusin", {target: control})
  clock.advance(179_999)
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  clock.advance(1)
  assert.equal(pane.getAttribute("aria-pressed"), "false")
})

test("hidden-tab elapsed time expires even when its player retained iframe focus", t => {
  const {clock, document, pane} = workspace(t)
  document.activeElement = {matches: selector => selector === "[data-youtube-player-host] iframe"}
  clock.emit("blur")
  clock.advance(0)
  clock.advance(200_000)
  document.hidden = true
  document.emit("visibilitychange")
  clock.advance(180_000, false)
  document.hidden = false
  document.emit("visibilitychange")
  assert.equal(pane.getAttribute("aria-pressed"), "false")
})

test("each intentional action renews the activity timestamp", async t => {
  for (const type of ["pointerdown", "click", "keydown", "wheel", "scroll", "touchstart", "touchmove"]) {
    await t.test(type, t => {
      const {clock, document, pane} = workspace(t)
      clock.advance(170_000)
      document.emit(type, {key: "a"})
      clock.advance(179_999)
      assert.equal(pane.getAttribute("aria-pressed"), "true")
      clock.advance(1)
      assert.equal(pane.getAttribute("aria-pressed"), "false")
    })
  }
})

test("mouse movement neither renews the deadline nor wakes an idle workspace", t => {
  const {clock, document, pane, commands} = workspace(t)
  clock.advance(170_000)
  document.emit("mousemove")
  document.emit("pointermove")
  clock.advance(10_000)
  document.emit("mousemove")
  document.emit("pointermove")
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.deepEqual(commands, ["reset-command"])
})

test("click and keyboard wake even when controls retained focus, without consuming input", async t => {
  for (const type of ["pointerdown", "click", "keydown", "touchstart"]) {
    await t.test(type, t => {
      const {clock, document, pane, brandEvents, control} = workspace(t)
      clock.advance(180_000)
      const event = document.emit(type, {key: "a", target: control})
      assert.equal(event.defaultPrevented, undefined)
      assert.equal(pane.getAttribute("aria-pressed"), "true")
      assert.deepEqual(brandEvents, ["lovelace:brand-reset", "lovelace:brand-focus"])
      assert.equal(document.activeElement, control)
      clock.advance(180_000)
      assert.equal(pane.getAttribute("aria-pressed"), "false")
    })
  }
})

test("duplicate pointer/click input does not replay an active brand", t => {
  const {clock, document, commands} = workspace(t)
  clock.advance(180_000)
  document.emit("pointerdown")
  document.emit("click")
  assert.deepEqual(commands, ["reset-command", "focus-command"])
})

test("Escape does not wake; next key resumes, while scroll/wheel only renew activity", t => {
  const {clock, document, pane, commands} = workspace(t)
  clock.advance(180_000)
  for (const type of ["wheel", "scroll", "touchmove"]) document.emit(type)
  document.emit("keydown", {key: "Escape"})
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.deepEqual(commands, ["reset-command"])
  document.emit("keydown", {key: "Tab"})
  assert.equal(pane.getAttribute("aria-pressed"), "true")
})

test("keyboard input restores workspace after the existing Escape command too", t => {
  const {document, pane, commands} = workspace(t)
  document.emit("keydown", {key: "Escape"})
  // The existing phx-window-keydown command, not this hook, handles Escape.
  pane.setAttribute("aria-pressed", "false")
  document.emit("keydown", {key: "a"})
  assert.deepEqual(commands, ["focus-command"])
})

test("visibility elapsed time counts even when hidden timers were throttled", t => {
  const {clock, document, pane, brandEvents} = workspace(t)
  clock.advance(100_000)
  document.hidden = true
  document.emit("visibilitychange")
  clock.advance(100_000, false)
  document.hidden = false
  document.emit("visibilitychange")
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.deepEqual(brandEvents, ["lovelace:brand-reset"])
  document.emit("click")
  assert.equal(pane.getAttribute("aria-pressed"), "true")
})

test("a short hidden interval preserves the original deadline and never wakes on visibility", t => {
  const {clock, document, pane, commands} = workspace(t)
  clock.advance(100_000, false)
  document.emit("visibilitychange")
  clock.advance(79_999)
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  clock.advance(1)
  document.emit("visibilitychange")
  assert.deepEqual(commands, ["reset-command"])
})

test("first input after sleep resets then replays brand even before a timer callback", t => {
  const {clock, document, brandEvents} = workspace(t)
  clock.advance(300_000, false)
  document.emit("keydown", {key: "a"})
  assert.deepEqual(brandEvents, ["lovelace:brand-reset", "lovelace:brand-focus"])
})

test("patches preserve activity deadline and sticky idle/focus state", t => {
  const {clock, document, pane, patch, commands} = workspace(t)
  clock.advance(170_000)
  patch()
  clock.advance(10_000)
  patch()
  assert.equal(pane.getAttribute("aria-pressed"), "false")
  assert.deepEqual(commands, ["reset-command"])
  document.emit("keydown", {key: "a"})
  patch()
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  assert.deepEqual(commands, ["reset-command", "focus-command"])
})

test("config updates use elapsed time, not a new activity timestamp", t => {
  const {clock, root, hook, pane} = workspace(t, "7")
  clock.advance(180_000)
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  root.dataset.idleMinutes = "2"
  hook.updated()
  assert.equal(pane.getAttribute("aria-pressed"), "false")
})

test("invalid duration safely uses the three-minute default", async t => {
  for (const value of [undefined, "", "0", "-1", "NaN", "Infinity"]) {
    await t.test(String(value), t => {
      const {clock, pane} = workspace(t, value)
      clock.advance(180_000)
      assert.equal(pane.getAttribute("aria-pressed"), "false")
    })
  }
})

test("an open modal suspends scenery resets across deadlines, patches, sleep and Escape", t => {
  const {clock, document, root, hook, pane, commands, patch} = workspace(t)
  root.modal = {}
  clock.advance(180_000)
  patch()
  clock.advance(300_000, false)
  document.emit("visibilitychange")
  document.emit("keydown", {key: "Escape"})
  assert.equal(pane.getAttribute("aria-pressed"), "true")
  assert.deepEqual(commands, [])
  assert.equal(clock.timers.size, 0, "overdue modal does not spin a one-millisecond timer")
  root.modal = null
  document.emit("lovelace:modal-closed")
  clock.advance(179_999)
  assert.deepEqual(commands, [])
  clock.advance(1)
  assert.deepEqual(commands, ["reset-command"])
  hook.destroyed()
})

test("destruction removes every listener and timer", t => {
  const {clock, document, hook, commands} = workspace(t)
  assert.ok(document.listenerCount > 0)
  hook.destroyed()
  assert.equal(document.listenerCount, 0)
  assert.equal(clock.listenerCount, 0)
  assert.equal(clock.timers.size, 0)
  clock.advance(300_000)
  document.emit("keydown", {key: "a"})
  assert.deepEqual(commands, [])
})

test("static stage handles cached loads/failure without a LiveView socket", () => {
  for (const width of [0, 200]) {
    const image = new FakeTarget()
    image.complete = true
    image.naturalWidth = width
    const stop = observeStageImage(image, value => image.setAttribute("data-loaded", value))
    assert.equal(image.getAttribute("data-loaded"), width > 0 ? "true" : "false")
    image.naturalWidth = 200
    image.emit("load")
    assert.equal(image.getAttribute("data-loaded"), "true")
    image.emit("error")
    assert.equal(image.getAttribute("data-loaded"), "false")
    stop()
    assert.equal(image.listenerCount, 0)
    image.emit("load")
    assert.equal(image.getAttribute("data-loaded"), "false")
  }
})

test("stage overlay remains hidden on failure and handles cached loads/teardown", () => {
  for (const cachedWidth of [undefined, 0, 100]) {
    const image = new FakeTarget()
    image.complete = cachedWidth !== undefined
    image.naturalWidth = cachedWidth ?? 0
    const hook = Object.assign({}, StageBackground, {
      el: image,
      js: () => ({setAttribute: (el, name, value) => el.setAttribute(name, value)}),
    })
    hook.mounted()
    assert.equal(image.getAttribute("data-loaded"), cachedWidth === undefined ? null : cachedWidth > 0 ? "true" : "false")
    image.naturalWidth = 200
    image.emit("load")
    assert.equal(image.getAttribute("data-loaded"), "true")
    image.emit("error")
    assert.equal(image.getAttribute("data-loaded"), "false")
    hook.destroyed()
    assert.equal(image.listenerCount, 0)
  }
})
