// BeamCraft overlay: Minecraft's own GUI on top of BeamNG.
//
// The hidden Minecraft renders its HUD, first-person hand, screen effects and every
// screen (inventory, crafting, chests, chat, death screen) over a transparent
// background. BeamNG's Lua relays the changed part of each frame here (this page
// can't open network connections itself) as "fullW,fullH,x,y,w,h|<base64 RGBA>";
// we paint it on a full-screen canvas. While a Minecraft screen is open, mouse and
// keyboard go back the same way (page -> Lua -> Minecraft) as GLFW events.

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
    this.patches = 0
    this.canvas = document.createElement('canvas')
    this.canvas.id = 'beamcraft-overlay'
    Object.assign(this.canvas.style, {
      position: 'fixed', left: '0', top: '0', width: '100vw', height: '100vh',
      zIndex: '2147483646', pointerEvents: 'none', imageRendering: 'pixelated', display: 'none',
    })
    this.ctx = this.canvas.getContext('2d')
    const attach = () => document.body ? document.body.appendChild(this.canvas) : setTimeout(attach, 200)
    attach()
    this.bindInput()
  }

  onPatch(str) {
    if (typeof str !== 'string') return
    const bar = str.indexOf('|')
    if (bar < 0) return
    const [fullW, fullH, x, y, w, h] = str.substring(0, bar).split(',').map(Number)
    if (this.canvas.width !== fullW || this.canvas.height !== fullH) {
      this.canvas.width = fullW
      this.canvas.height = fullH
      if (x !== 0 || y !== 0 || w !== fullW || h !== fullH) {
        toLua({ t: 'full' }) // resized under a partial update: ask for a whole frame
        return
      }
    }
    if (!w || !h) return
    const bin = atob(str.substring(bar + 1))
    const n = bin.length
    const bytes = new Uint8ClampedArray(n)
    for (let i = 0; i < n; i++) bytes[i] = bin.charCodeAt(i)
    this.ctx.putImageData(new ImageData(bytes, w, h), x, y)
    this.patches++
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
  // frame patches relayed by Lua: guihooks.triggerRawJS('BeamCraftFrame', '"..."')
  $rootScope.$on('BeamCraftFrame', (ev, patch) => overlay.onPatch(patch))
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
