-- Minecraft's particles in BeamNG. Vanilla runs them (emission, physics, colour,
-- sprite animation, size, lifetime); the hidden client sends every visible quad
-- particle each tick and we draw them as camera-facing quads, interpolated between
-- ticks.
--
-- All particles sharing a sprite texture and (quantized) tint go into one mesh that is
-- rebuilt every frame around the camera - a few meshes in total, instead of one scene
-- object per particle that had to be deleted and recreated whenever its sprite
-- animated or its colour changed.

local mu = require('beamcraft/meshutil')
local coords = require('beamcraft/coords')

local M = {}

local particles = {}  -- id -> { prev, cur, at, seen }
local groups = {}     -- material key -> { obj, mat, used }
local stamp = 0
local HIDE = -100000

local function step(v, n) return math.floor(math.max(0, math.min(1, v)) * n + 0.5) / n end
-- rebuild the meshes at most this often (Minecraft moves particles 20 times a second;
-- rebuilding every frame cost several ms with a fight's worth of particles)
M.rebuildInterval = 1 / 30
local lastBuild = -1

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

local function groupFor(p)
  -- coarse tint steps: each distinct tint is its own material
  local r, g, b, a = step(p.r, 8), step(p.g, 8), step(p.b, 8), step(p.a, 4)
  local key = p.tex .. ':' .. r .. ':' .. g .. ':' .. b .. ':' .. a
  local grp = groups[key]
  if not grp then
    local mat = mu.material('bc_particle_' .. key:gsub('[^%w]', '_'), {
      Stages = { { baseColorMap = p.tex, baseColorFactor = { r, g, b, 1 }, opacityMap = p.mask, opacityFactor = a,
        roughnessFactor = 1, metallicFactor = 0, }, {}, {}, {} },
      translucent = true, translucentBlendOp = 'LerpAlpha', translucentZWrite = false, doubleSided = true,
      castShadows = false, useAnisotropic = false, dynamicCubemap = false,
    })
    grp = { mat = mat }
    groups[key] = grp
  end
  return grp
end

function M.update(now)
  if next(particles) ~= nil and now - lastBuild < M.rebuildInterval then return end
  lastBuild = now
  for _, grp in pairs(groups) do grp.mesh = nil end
  if next(particles) == nil then
    for _, grp in pairs(groups) do
      if grp.obj and grp.shown then mu.setXform(grp.obj, 0, 0, HIDE, mu.IDENTITY) grp.shown = false end
    end
    return
  end
  local cam = getCameraPosition()
  local fwd = core_camera.getForward()
  local right = fwd:cross(vec3(0, 0, 1))
  if right:length() < 1e-4 then right = vec3(1, 0, 0) end
  right:normalize()
  local up = right:cross(fwd)
  up:normalize()
  local pending = false
  for _, e in pairs(particles) do
    local c, p = e.cur, e.prev or e.cur
    local t = math.min(1, (now - e.at) / 0.05)
    local x, y, z = coords.mcToBng(p.x + (c.x - p.x) * t, p.y + (c.y - p.y) * t, p.z + (c.z - p.z) * t)
    local grp = groupFor(c)
    if not grp.obj then pending = true end
    local m = grp.mesh
    if not m then
      m = mu.newMesh(grp.mat)
      grp.mesh = m
    end
    -- camera-facing quad, half size s, rolled like vanilla
    local s = c.s or 0.1
    local roll = c.roll or 0
    local cr, sr = math.cos(roll) * s, math.sin(roll) * s
    local ax, ay, az = right.x * cr + up.x * sr, right.y * cr + up.y * sr, right.z * cr + up.z * sr
    local bx, by, bz = up.x * cr - right.x * sr, up.y * cr - right.y * sr, up.z * cr - right.z * sr
    local ox, oy, oz = x - cam.x, y - cam.y, z - cam.z
    local uv = c.uv
    mu.addQuad(m,
      { ox - ax + bx, oy - ay + by, oz - az + bz }, { ox + ax + bx, oy + ay + by, oz + az + bz },
      { ox + ax - bx, oy + ay - by, oz + az - bz }, { ox - ax - bx, oy - ay - by, oz - az - bz },
      uv[1], uv[2], uv[3], uv[4], -fwd.x, -fwd.y, -fwd.z)
  end
  if pending then mu.flushMaterials() end
  for _, grp in pairs(groups) do
    if grp.mesh then
      if not grp.obj then
        grp.obj = mu.newObject('beamcraft_particles', { grp.mesh })
      else
        grp.obj:createMesh({ { grp.mesh } })
      end
      mu.setXform(grp.obj, cam.x, cam.y, cam.z, mu.IDENTITY)
      grp.shown = true
    elseif grp.obj and grp.shown then
      mu.setXform(grp.obj, 0, 0, HIDE, mu.IDENTITY)
      grp.shown = false
    end
  end
end

function M.clear()
  for _, grp in pairs(groups) do mu.deleteObject(grp.obj) end
  groups, particles = {}, {}
end

return M
