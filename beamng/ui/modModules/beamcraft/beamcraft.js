// BeamCraft overlay: Minecraft's own GUI on top of BeamNG.
//
// The hidden Minecraft renders its HUD, first-person hand, screen effects and every
// screen (inventory, crafting, chests, chat, death screen) over a transparent
// background; BeamNG's Lua draws it with imgui (see lua/.../beamcraft/overlay.lua).
// This page only forwards input: while a Minecraft screen is open, mouse and keyboard
// go page -> Lua -> Minecraft as GLFW events.

// DOM KeyboardEvent.code -> GLFW key code
const GLFW_KEYS = (() => {
  const k = {
    Space: 32, Quote: 39, Comma: 44, Minus: 45, Period: 46, Slash: 47, Semicolon: 59, Equal: 61,
    BracketLeft: 91, Backslash: 92, BracketRight: 93, Backquote: 96,
    Escape: 256, Enter: 257, Tab: 258, Backspace: 259, Insert: 260, Delete: 261,
    ArrowRight: 262, ArrowLeft: 263, ArrowDown: 264, ArrowUp: 265, PageUp: 266, PageDown: 267,
    Home: 268, End: 269, CapsLock: 280, ScrollLock: 281, NumLock: 282, PrintScreen: 283, Pause: 284,
    NumpadDecimal: 330, NumpadDivide: 331, NumpadMultiply: 332, NumpadSubtract: 333, NumpadAdd: 334,
    NumpadEnter: 335, NumpadEqual: 336,
    ShiftLeft: 340, ControlLeft: 341, AltLeft: 342, MetaLeft: 343,
    ShiftRight: 344, ControlRight: 345, AltRight: 346, MetaRight: 347, ContextMenu: 348,
  }
  for (let i = 0; i < 26; i++) k['Key' + String.fromCharCode(65 + i)] = 65 + i
  for (let i = 0; i < 10; i++) { k['Digit' + i] = 48 + i; k['Numpad' + i] = 320 + i }
  for (let i = 1; i <= 12; i++) k['F' + i] = 289 + i
  return k
})()

function mods(e) {
  return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0)
}

function toLua(obj) {
  if (window.bngApi && window.bngApi.engineLua) {
    window.bngApi.engineLua('beamcraft_main.overlayInput([[' + JSON.stringify(obj) + ']])')
  }
}

class BeamCraftOverlay {
  constructor() {
    this.visible = false
    this.interactive = false
    // An empty, transparent surface: BeamNG's Lua draws Minecraft's GUI with imgui
    // (Chromium can't keep up with the game's frame rate). This page only catches the
    // mouse and keyboard while a Minecraft screen is open; its size is Minecraft's
    // window size, so event coordinates map straight to Minecraft pixels.
    this.canvas = document.createElement('canvas')
    this.canvas.id = 'beamcraft-overlay'
    this.canvas.width = 1
    this.canvas.height = 1
    Object.assign(this.canvas.style, {
      position: 'fixed', left: '0', top: '0', width: '100%', height: '100%',
      zIndex: '2147483646', pointerEvents: 'none', display: 'none', background: 'transparent',
    })
    // BeamNG only stops its own keybindings (E = radial menu...) while a text field in
    // its UI has focus, so while a Minecraft screen is open this invisible one holds it.
    this.keys = document.createElement('input')
    this.keys.type = 'text'
    this.keys.id = 'beamcraft-keys'
    this.keys.setAttribute('autocomplete', 'off')
    Object.assign(this.keys.style, {
      position: 'fixed', left: '0', top: '0', width: '1px', height: '1px', opacity: '0',
      border: '0', padding: '0', zIndex: '2147483647', pointerEvents: 'none',
    })
    this.keys.addEventListener('input', () => { this.keys.value = '' })
    this.keys.addEventListener('blur', () => {
      // something else took focus (a click on the canvas does that): take it back
      if (this.interactive) setTimeout(() => this.grabKeys(), 0)
    })
    const attach = () => {
      if (!document.body) return setTimeout(attach, 200)
      document.body.appendChild(this.canvas)
      document.body.appendChild(this.keys)
    }
    attach()
    this.bindInput()
  }

  grabKeys() {
    if (!this.interactive) return
    if (document.activeElement !== this.keys) this.keys.focus({ preventScroll: true })
    if (window.bngApi && window.bngApi.engineLua) window.bngApi.engineLua('setCEFTyping(true)')
  }

  setState(state) {
    if (!state) return
    this.visible = !!state.visible
    this.interactive = this.visible && !!state.interactive
    if (state.w > 0 && state.h > 0 && (this.canvas.width !== state.w || this.canvas.height !== state.h)) {
      this.canvas.width = state.w
      this.canvas.height = state.h
    }
    const was = this.wasInteractive
    this.wasInteractive = this.interactive
    if (this.interactive) this.grabKeys()
    else if (was) {
      this.keys.blur()
      if (window.bngApi && window.bngApi.engineLua) window.bngApi.engineLua('setCEFTyping(false)')
    }
    this.canvas.style.display = this.interactive ? 'block' : 'none'
    // BeamNG hands the mouse to its UI only over pixels that aren't fully transparent:
    // a 2% tint (under Minecraft's own dimmed screen background) makes it clickable
    this.canvas.style.background = this.interactive ? 'rgba(0, 0, 0, 0.02)' : 'transparent'
    this.canvas.style.pointerEvents = this.interactive ? 'auto' : 'none'
    this.canvas.style.cursor = this.interactive ? 'default' : 'none'
  }

  // canvas pixel coordinates (= Minecraft window pixels)
  pos(e) {
    const r = this.canvas.getBoundingClientRect()
    return {
      x: (e.clientX - r.left) * this.canvas.width / Math.max(1, r.width),
      y: (e.clientY - r.top) * this.canvas.height / Math.max(1, r.height),
    }
  }

  bindInput() {
    const c = this.canvas
    const swallow = (e) => { e.preventDefault(); e.stopPropagation() }
    let lastMove = 0
    c.addEventListener('mousemove', (e) => {
      if (!this.interactive) return
      const now = performance.now()
      if (now - lastMove < 16) return
      lastMove = now
      const p = this.pos(e)
      toLua({ t: 'mm', x: p.x, y: p.y })
    })
    const button = (e, action) => {
      if (!this.interactive) return
      swallow(e)
      const p = this.pos(e)
      toLua({ t: 'mb', b: [0, 2, 1][e.button] ?? e.button, a: action, m: mods(e), x: p.x, y: p.y })
    }
    c.addEventListener('mousedown', (e) => button(e, 1))
    c.addEventListener('mouseup', (e) => button(e, 0))
    c.addEventListener('contextmenu', swallow)
    c.addEventListener('wheel', (e) => {
      if (!this.interactive) return
      swallow(e)
      toLua({ t: 'ms', dx: 0, dy: e.deltaY > 0 ? -1 : e.deltaY < 0 ? 1 : 0 })
    }, { passive: false })
    const onKey = (e, action) => {
      if (!this.interactive) return
      const key = GLFW_KEYS[e.code]
      if (key === undefined) return
      swallow(e)
      toLua({ t: 'key', k: key, sc: 0, a: e.repeat && action === 1 ? 2 : action, m: mods(e) })
      if (action === 1 && e.key && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
        toLua({ t: 'ch', c: e.key.codePointAt(0) })
      }
    }
    window.addEventListener('keydown', (e) => onKey(e, 1), true)
    window.addEventListener('keyup', (e) => onKey(e, 0), true)
  }
}

console.warn('[BeamCraft] overlay module loaded')
const overlay = new BeamCraftOverlay()
window.beamcraftOverlay = overlay

window.angular.module('beamcraft', []).run(['$rootScope', function ($rootScope) {
  // visibility/interactivity: guihooks.trigger('BeamCraftOverlay', {visible=, interactive=})
  $rootScope.$on('BeamCraftOverlay', (ev, data) => overlay.setState(data))
}])

// also poll Lua for the state, in case the page loaded after the last push
setInterval(() => {
  if (window.bngApi && window.bngApi.engineLua) {
    window.bngApi.engineLua('beamcraft_main and beamcraft_main.overlayState and beamcraft_main.overlayState()', (s) => overlay.setState(s))
  }
}, 500)

export default overlay
