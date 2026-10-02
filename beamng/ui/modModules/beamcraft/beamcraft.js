// BeamCraft overlay: Minecraft's own GUI on top of BeamNG.
//
// The hidden Minecraft renders its HUD, first-person hand, screen effects and every
// screen (inventory, crafting, chests, chat, death screen) over a transparent
// background and streams the changed part of each frame to ws://127.0.0.1:47802.
// This module paints those frames on a full-screen canvas, and while a Minecraft
// screen is open it sends the mouse and keyboard back, as GLFW events.

const PORT = 47802
const MAGIC = 0x31464342 // "BCF1" little-endian

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

class BeamCraftOverlay {
  constructor() {
    this.visible = false
    this.interactive = false
    this.ws = null
    this.canvas = document.createElement('canvas')
    this.canvas.id = 'beamcraft-overlay'
    Object.assign(this.canvas.style, {
      position: 'fixed', left: '0', top: '0', width: '100vw', height: '100vh',
      zIndex: '2147483646', pointerEvents: 'none', imageRendering: 'pixelated', display: 'none',
    })
    this.ctx = this.canvas.getContext('2d')
    const attach = () => document.body ? document.body.appendChild(this.canvas) : setTimeout(attach, 200)
    attach()
    this.connect()
    this.bindInput()
  }

  connect() {
    let ws
    try {
      ws = new WebSocket(`ws://127.0.0.1:${PORT}`)
    } catch (e) {
      setTimeout(() => this.connect(), 2000)
      return
    }
    ws.binaryType = 'arraybuffer'
    ws.onopen = () => { this.ws = ws }
    ws.onmessage = (msg) => this.onFrame(msg.data)
    ws.onclose = () => {
      this.ws = null
      setTimeout(() => this.connect(), 2000)
    }
    ws.onerror = () => {}
  }

  send(obj) {
    if (this.ws && this.ws.readyState === 1) this.ws.send(JSON.stringify(obj))
  }

  onFrame(buf) {
    if (!(buf instanceof ArrayBuffer) || buf.byteLength < 20) return
    const dv = new DataView(buf)
    if (dv.getUint32(0, true) !== MAGIC) return
    const fullW = dv.getUint16(4, true), fullH = dv.getUint16(6, true)
    const x = dv.getUint16(8, true), y = dv.getUint16(10, true)
    const w = dv.getUint16(12, true), h = dv.getUint16(14, true)
    if (this.canvas.width !== fullW || this.canvas.height !== fullH) {
      this.canvas.width = fullW
      this.canvas.height = fullH
      if (x !== 0 || y !== 0 || w !== fullW || h !== fullH) {
        this.send({ t: 'full' }) // resized under a partial update: ask for a whole frame
        return
      }
    }
    if (w === 0 || h === 0) return
    const img = new ImageData(new Uint8ClampedArray(buf, 20, w * h * 4), w, h)
    this.ctx.putImageData(img, x, y)
  }

  setState(state) {
    if (!state) return
    this.visible = !!state.visible
    this.interactive = this.visible && !!state.interactive
    this.canvas.style.display = this.visible ? 'block' : 'none'
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
    c.addEventListener('mousemove', (e) => {
      if (!this.interactive) return
      const p = this.pos(e)
      this.send({ t: 'mm', x: p.x, y: p.y })
    })
    c.addEventListener('mousedown', (e) => {
      if (!this.interactive) return
      swallow(e)
      const p = this.pos(e)
      this.send({ t: 'mb', b: [0, 2, 1][e.button] ?? e.button, a: 1, m: mods(e), x: p.x, y: p.y })
    })
    c.addEventListener('mouseup', (e) => {
      if (!this.interactive) return
      swallow(e)
      const p = this.pos(e)
      this.send({ t: 'mb', b: [0, 2, 1][e.button] ?? e.button, a: 0, m: mods(e), x: p.x, y: p.y })
    })
    c.addEventListener('contextmenu', swallow)
    c.addEventListener('wheel', (e) => {
      if (!this.interactive) return
      swallow(e)
      this.send({ t: 'ms', dx: 0, dy: e.deltaY > 0 ? -1 : e.deltaY < 0 ? 1 : 0 })
    }, { passive: false })
    const onKey = (e, action) => {
      if (!this.interactive) return
      const key = GLFW_KEYS[e.code]
      if (key === undefined) return
      swallow(e)
      this.send({ t: 'key', k: key, sc: 0, a: e.repeat && action === 1 ? 2 : action, m: mods(e) })
      if (action === 1 && e.key && e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
        this.send({ t: 'ch', c: e.key.codePointAt(0) })
      }
    }
    window.addEventListener('keydown', (e) => onKey(e, 1), true)
    window.addEventListener('keyup', (e) => onKey(e, 0), true)
  }
}

const overlay = new BeamCraftOverlay()
window.beamcraftOverlay = overlay

// state from Lua: guihooks.trigger('BeamCraftOverlay', {visible=, interactive=})
window.angular.module('beamcraft', []).run(['$rootScope', function ($rootScope) {
  $rootScope.$on('BeamCraftOverlay', (ev, data) => overlay.setState(data))
}])

// belt and braces: also poll Lua, in case the event bridge isn't up yet
setInterval(() => {
  if (window.bngApi && window.bngApi.engineLua) {
    window.bngApi.engineLua('beamcraft_main and beamcraft_main.overlayState and beamcraft_main.overlayState()', (s) => overlay.setState(s))
  }
}, 500)

export default overlay
