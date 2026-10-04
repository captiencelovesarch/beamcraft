-- Minecraft's particles in BeamNG. Vanilla runs them (emission, physics, colour,
-- sprite animation, size, lifetime); the hidden client sends every visible quad
-- particle each tick and we draw them as camera-facing quads, interpolated between
-- ticks.
--
-- Every particle is its own little scene object, taken each frame from a pool of
-- ready-made unit quads per look (sprite texture + quantized tint + uv rect) and only
-- moved: setTransform costs ~0.002 ms, while ProceduralMesh:createMesh costs ~0.3 ms
-- however small the mesh (it rebuilds the object's physics triangle mesh too).
-- Rebuilding a mesh per look 30 times a second cost 15+ ms a frame in a wither fight.
-- New pool objects are made on a per-frame budget; spare ones are trimmed when a look
-- hasn't needed them for a while.

local mu = require('beamcraft/meshutil')
local coords = require('beamcraft/coords')

local M = {}

local particles = {}  -- id -> { prev, cur, at, seen }
local pools = {}      -- look key -> { mat, uv, objs = {}, used, shown, peak, lastUsed }
local stamp = 0
local HIDE = -100000

-- new pool objects per frame (each ~0.7 ms); particles over budget wait a frame
M.createBudgetMs = 2.0
-- every trimInterval, a pool keeps only as many objects as it needed since the last trim
M.trimInterval = 5.0
local lastTrim = 0

local function step(v, n) return math.floor(math.max(0, math.min(1, v)) * n + 0.5) / n end

function M.snapshot(msg, now)
  stamp = stamp + 1
  for _, p in ipairs(msg.l or {}) do
    local e = particles[p.id]
    if not e then
      e = { cur = p }
      particles[p.id] = e
    end
    e.prev, e.cur, e.at, e.seen = e.cur, p, now, stamp
  end
  for id, e in pairs(particles) do
    if e.seen ~= stamp then particles[id] = nil end
  end
end

-- the look of a particle: texture, coarse tint (each tint is its own material) and the
-- part of the sprite it shows (block/item crumbs show a random corner of a texture)
local function poolFor(p)
  local r, g, b, a = step(p.r, 8), step(p.g, 8), step(p.b, 8), step(p.a, 4)
  local uv = p.uv
  local u0, v0, u1, v1 = step(uv[1], 64), step(uv[2], 64), step(uv[3], 64), step(uv[4], 64)
  local key = p.tex .. ':' .. r .. ':' .. g .. ':' .. b .. ':' .. a .. ':' .. u0 .. ':' .. v0 .. ':' .. u1 .. ':' .. v1
  local pool = pools[key]
  if not pool then
    local mkey = p.tex .. ':' .. r .. ':' .. g .. ':' .. b .. ':' .. a
    local mat = mu.material('bc_particle_' .. mkey:gsub('[^%w]', '_'), {
      Stages = { { baseColorMap = p.tex, baseColorFactor = { r, g, b, 1 }, opacityMap = p.mask, opacityFactor = a,
        roughnessFactor = 1, metallicFactor = 0, }, {}, {}, {} },
      translucent = true, translucentBlendOp = 'LerpAlpha', translucentZWrite = false, doubleSided = true,
      castShadows = false, useAnisotropic = false, dynamicCubemap = false,
    })
    pool = { mat = mat, uv = { u0, v0, u1, v1 }, objs = {}, used = 0, shown = 0, peak = 0, lastUsed = 0 }
    pools[key] = pool
  end
  return pool
end

-- a unit quad in the local XZ plane facing -Y, centred on the origin
local function newQuad(pool)
  local m = mu.newMesh(pool.mat)
  local uv = pool.uv
  mu.addQuad(m, { -0.5, 0, 0.5 }, { 0.5, 0, 0.5 }, { 0.5, 0, -0.5 }, { -0.5, 0, -0.5 },
    uv[1], uv[2], uv[3], uv[4], 0, -1, 0)
  local obj = mu.newObject('beamcraft_particle', { m })
  mu.park(obj) -- counted as shown (unparked) once used
  return obj
end

local mat = MatrixF(true)
local cx, cy, cz, cp = vec3(), vec3(), vec3(), vec3()
local scl = vec3(1, 1, 1)
local timer = hptimer()

local function hideRest(pool)
  for i = pool.used + 1, pool.shown do
    cp:set(0, 0, HIDE)
    mat:setColumn(3, cp)
    pool.objs[i]:setTransform(mat)
    mu.park(pool.objs[i])
  end
  pool.shown = pool.used
end

local function trim(now)
  for key, pool in pairs(pools) do
    local keep = pool.peak
    for i = #pool.objs, keep + 1, -1 do
      mu.deleteObject(pool.objs[i])
      pool.objs[i] = nil
    end
    if pool.shown > #pool.objs then pool.shown = #pool.objs end
    pool.peak = pool.used
    if #pool.objs == 0 and now - pool.lastUsed > 30 then pools[key] = nil end
  end
end

function M.update(now)
  for _, pool in pairs(pools) do pool.used = 0 end
  if next(particles) ~= nil then
    local cam = getCameraPosition()
    local fwd = core_camera.getForward()
    local right = fwd:cross(vec3(0, 0, 1))
    if right:length() < 1e-4 then right = vec3(1, 0, 0) end
    right:normalize()
    local up = right:cross(fwd)
    up:normalize()
    local start = timer:stop()
    mat:setColumn(1, fwd)
    for _, e in pairs(particles) do
      local c, p = e.cur, e.prev or e.cur
      local pool = poolFor(c)
      local i = pool.used + 1
      local obj = pool.objs[i]
      if not obj and timer:stop() - start < M.createBudgetMs then
        mu.flushMaterials() -- a new look's material, if any
        obj = newQuad(pool)
        pool.objs[i] = obj
      end
      if obj then
        pool.used = i
        if i > pool.shown then mu.unpark(obj) end
        local t = math.min(1, (now - e.at) / 0.05)
        local x, y, z = coords.mcToBng(p.x + (c.x - p.x) * t, p.y + (c.y - p.y) * t, p.z + (c.z - p.z) * t)
        -- camera-facing, rolled like vanilla: local X/Z = the rolled right/up axes
        local roll = c.roll or 0
        local cr, sr = math.cos(roll), math.sin(roll)
        cx:set(right.x * cr + up.x * sr, right.y * cr + up.y * sr, right.z * cr + up.z * sr)
        cz:set(up.x * cr - right.x * sr, up.y * cr - right.y * sr, up.z * cr - right.z * sr)
        cp:set(x, y, z)
        mat:setColumn(0, cx)
        mat:setColumn(2, cz)
        mat:setColumn(3, cp)
        obj:setTransform(mat)
        local s = 2 * (c.s or 0.1)
        scl:set(s, s, s)
        obj:setScale(scl)
      end
    end
  end
  -- upright basis for hiding the spare objects
  mat:setColumn(0, vec3(1, 0, 0))
  mat:setColumn(1, vec3(0, 1, 0))
  mat:setColumn(2, vec3(0, 0, 1))
  for _, pool in pairs(pools) do
    if pool.used > 0 then pool.lastUsed = now end
    if pool.used > pool.peak then pool.peak = pool.used end
    if pool.shown > pool.used then hideRest(pool) else pool.shown = pool.used end
  end
  if now - lastTrim > M.trimInterval then
    lastTrim = now
    trim(now)
  end
end

function M.stats()
  local n, objs, used = 0, 0, 0
  for _, pool in pairs(pools) do n = n + 1 objs = objs + #pool.objs used = used + pool.used end
  local live = 0
  for _ in pairs(particles) do live = live + 1 end
  return { looks = n, objects = objs, drawn = used, particles = live }
end

function M.clear()
  for _, pool in pairs(pools) do
    for _, o in ipairs(pool.objs) do mu.deleteObject(o) end
  end
  pools, particles = {}, {}
end

return M
