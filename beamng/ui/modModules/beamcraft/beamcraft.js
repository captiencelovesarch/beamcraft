// BeamCraft overlay: Minecraft's own GUI on top of BeamNG.
//
// The hidden Minecraft renders its HUD, first-person hand, screen effects and every
// screen (inventory, crafting, chests, chat, death screen) over a transparent
// background. BeamNG's Lua relays the changed part of each frame here
// as "fullW,fullH,x,y,w,h|<base64 RGBA>";
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
      position: 'fixed', left: '0', top: '0', width: '100%', height: '100%',
      zIndex: '2147483646', pointerEvents: 'none', imageRendering: 'pixelated', display: 'none',
      willChange: 'transform', transform: 'translateZ(0)', contain: 'strict',
    })
    this.ctx = this.canvas.getContext('2d', { alpha: true, desynchronized: true })
    this.ctx.imageSmoothingEnabled = false
    this.frames = []
    this.presented = 0
    this.decodeMs = 0
    this.maxQueue = 0
    this.rafCount = 0
    this.measureStart = performance.now()
    const present = (now) => {
      this.rafCount++
      let acknowledgements = 0
      while (this.frames.length && this.frames[0].ready) {
        const frame = this.frames.shift()
        if (frame.error) toLua({ t: 'full' })
        else for (const apply of frame.patches) apply()
        acknowledgements++
        this.presented++
      }
      if (acknowledgements && window.bngApi?.engineLua) window.bngApi.engineLua('beamcraft_main.overlayAck(' + acknowledgements + ')')
      if (now - this.measureStart > 2000) {
        const fps = this.rafCount * 1000 / (now - this.measureStart)
        if (window.bngApi?.engineLua) window.bngApi.engineLua('beamcraft_main.overlayMetrics(' + fps.toFixed(1) + ',' + this.decodeMs.toFixed(1) + ',' + this.maxQueue + ')')
        this.rafCount = 0; this.measureStart = now; this.maxQueue = this.frames.length
      }
      requestAnimationFrame(present)
    }
    requestAnimationFrame(present)
    const attach = () => document.body ? document.body.appendChild(this.canvas) : setTimeout(attach, 200)
    attach()
    this.bindInput()
  }

  resize(w, h) {
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w; this.canvas.height = h
      this.ctx.imageSmoothingEnabled = false
    }
  }

  async decodePatch(str) {
    if (typeof str !== 'string') return () => {}
    if (str.startsWith('C|')) {
      const [w, h] = str.substring(2).split(',').map(Number)
      return () => { this.resize(w, h); this.ctx.clearRect(0, 0, w, h) }
    }
    const png = str.startsWith('P|'), raw = str.startsWith('R|')
    const start = png || raw ? 2 : 0, bar = str.indexOf('|', start)
    const [fw, fh, x, y, w, h] = str.substring(start, bar).split(',').map(Number)
    if (![fw, fh, x, y, w, h].every(Number.isFinite) || !w || !h) return () => {}
    const binary = atob(str.substring(bar + 1))
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    if (png) {
      const blob = new Blob([bytes], { type: 'image/png' })
      let image
      if (typeof createImageBitmap === 'function') image = await createImageBitmap(blob, { premultiplyAlpha: 'premultiply' })
      else image = await new Promise((resolve, reject) => {
        const img = new Image(), url = URL.createObjectURL(blob)
        img.onload = () => { URL.revokeObjectURL(url); resolve(img) }
        img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('PNG decode failed')) }
        img.src = url
      })
      return () => {
        this.resize(fw, fh)
        this.ctx.clearRect(x, y, w, h); this.ctx.drawImage(image, x, y)
        if (image.close) image.close()
        this.patches++
      }
    }
    const pixels = new ImageData(new Uint8ClampedArray(bytes.buffer), w, h)
    return () => { this.resize(fw, fh); this.ctx.putImageData(pixels, x, y); this.patches++ }
  }

  frame(patches) {
    const frame = { ready: false, patches: [] }, started = performance.now()
    this.frames.push(frame)
    this.maxQueue = Math.max(this.maxQueue, this.frames.length)
    Promise.all((Array.isArray(patches) ? patches : [patches]).map(p => this.decodePatch(p)))
      .then(result => { frame.patches = result })
      .catch(error => { console.error('[BeamCraft] overlay decode failed', error); frame.error = true })
      .finally(() => { this.decodeMs = performance.now() - started; frame.ready = true })
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
  $rootScope.$on('BeamCraftFrame', (ev, patches) => overlay.frame(patches))
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
