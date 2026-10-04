-- Small shared toolkit: quaternions, object transforms, ProceduralMesh builders
-- (Minecraft-style UV boxes, flat quads, block models) and a material registry.

local M = {}

------------------------------------------------------------------------------
-- quaternions as {x, y, z, w} (Hamilton product, v' = q v q*)
------------------------------------------------------------------------------

function M.qaxis(ax, ay, az, angle)
  local s = math.sin(angle * 0.5)
  return { ax * s, ay * s, az * s, math.cos(angle * 0.5) }
end

function M.qmul(a, b)
  return {
    a[4] * b[1] + a[1] * b[4] + a[2] * b[3] - a[3] * b[2],
    a[4] * b[2] - a[1] * b[3] + a[2] * b[4] + a[3] * b[1],
    a[4] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[4],
    a[4] * b[4] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  }
end

function M.qrot(q, x, y, z)
  local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
  -- t = 2 * cross(q.xyz, v); v' = v + w * t + cross(q.xyz, t)
  local tx = 2 * (qy * z - qz * y)
  local ty = 2 * (qz * x - qx * z)
  local tz = 2 * (qx * y - qy * x)
  return x + qw * tx + (qy * tz - qz * ty),
         y + qw * ty + (qz * tx - qx * tz),
         z + qw * tz + (qx * ty - qy * tx)
end

M.IDENTITY = { 0, 0, 0, 1 }

-- Torque's QuatF is the conjugate of the Hamilton convention used here (measured:
-- a +90 deg turn about Z came out as -90), so conjugate on the way in.
M.conjugate = true

function M.setXform(obj, px, py, pz, q)
  local x, y, z, w = q[1], q[2], q[3], q[4]
  if M.conjugate then x, y, z = -x, -y, -z end
  local m = QuatF(x, y, z, w):getMatrix()
  m:setColumn(3, vec3(px, py, pz))
  obj:setTransform(m)
end

------------------------------------------------------------------------------
-- ProceduralMesh helpers. All meshes are built in object-local BeamNG axes and
-- triangles wound clockwise as seen from outside (Torque convention).
------------------------------------------------------------------------------

local function newMesh(material)
  return { verts = {}, uvs = {}, normals = {}, faces = {}, material = material }
end
M.newMesh = newMesh

-- corners tl, tr, br, bl as seen from outside; uv rect u0,v0,u1,v1 (0..1); normal
function M.addQuad(m, tl, tr, br, bl, u0, v0, u1, v1, nx, ny, nz)
  local verts, uvs, normals, faces = m.verts, m.uvs, m.normals, m.faces
  local b = #verts
  verts[b + 1] = { x = tl[1], y = tl[2], z = tl[3] }
  verts[b + 2] = { x = tr[1], y = tr[2], z = tr[3] }
  verts[b + 3] = { x = br[1], y = br[2], z = br[3] }
  verts[b + 4] = { x = bl[1], y = bl[2], z = bl[3] }
  uvs[b + 1] = { u = u0, v = v0 }
  uvs[b + 2] = { u = u1, v = v0 }
  uvs[b + 3] = { u = u1, v = v1 }
  uvs[b + 4] = { u = u0, v = v1 }
  local n = #normals
  normals[n + 1] = { x = nx, y = ny, z = nz }
  local f = #faces
  faces[f + 1] = { v = b, n = n, u = b }
  faces[f + 2] = { v = b + 1, n = n, u = b + 1 }
  faces[f + 3] = { v = b + 2, n = n, u = b + 2 }
  faces[f + 4] = { v = b, n = n, u = b }
  faces[f + 5] = { v = b + 2, n = n, u = b + 2 }
  faces[f + 6] = { v = b + 3, n = n, u = b + 3 }
end

-- A Minecraft model box. Local axes: +X = character's right, +Y = forward, +Z = up.
-- x0..x1 etc. in metres; u, v, w, h, d in texture pixels (Minecraft's box UV layout);
-- texW/texH = texture size in pixels.
function M.addUvBox(m, x0, y0, z0, x1, y1, z1, u, v, w, h, d, texW, texH, pixelated)
  local function U(px) return px / texW end
  local function V(py) return py / texH end
  local function face(tl, tr, br, bl, fu, fv, cols, rows, nx, ny, nz)
    if not pixelated then
      M.addQuad(m, tl, tr, br, bl, U(fu), V(fv), U(fu + cols), V(fv + rows), nx, ny, nz)
      return
    end
    -- A constant UV at each source pixel's centre makes each little quad sample
    -- one colour. BeamNG can use bilinear filtering without blurring pixel edges.
    local function point(s, t)
      return {
        tl[1] * (1 - s) * (1 - t) + tr[1] * s * (1 - t) + br[1] * s * t + bl[1] * (1 - s) * t,
        tl[2] * (1 - s) * (1 - t) + tr[2] * s * (1 - t) + br[2] * s * t + bl[2] * (1 - s) * t,
        tl[3] * (1 - s) * (1 - t) + tr[3] * s * (1 - t) + br[3] * s * t + bl[3] * (1 - s) * t,
      }
    end
    for row = 0, rows - 1 do
      local t0, t1 = row / rows, (row + 1) / rows
      for col = 0, cols - 1 do
        local s0, s1 = col / cols, (col + 1) / cols
        local uu, vv = U(fu + col + 0.5), V(fv + row + 0.5)
        M.addQuad(m, point(s0, t0), point(s1, t0), point(s1, t1), point(s0, t1),
          uu, vv, uu, vv, nx, ny, nz)
      end
    end
  end
  -- front (+Y): viewer's left is the character's right (+X)
  face({ x1, y1, z1 }, { x0, y1, z1 }, { x0, y1, z0 }, { x1, y1, z0 },
    u + d, v + d, w, h, 0, 1, 0)
  -- back (-Y)
  face({ x0, y0, z1 }, { x1, y0, z1 }, { x1, y0, z0 }, { x0, y0, z0 },
    u + 2 * d + w, v + d, w, h, 0, -1, 0)
  -- character's right side (+X)
  face({ x1, y0, z1 }, { x1, y1, z1 }, { x1, y1, z0 }, { x1, y0, z0 },
    u, v + d, d, h, 1, 0, 0)
  -- character's left side (-X)
  face({ x0, y1, z1 }, { x0, y0, z1 }, { x0, y0, z0 }, { x0, y1, z0 },
    u + d + w, v + d, d, h, -1, 0, 0)
  -- top (+Z): front edge at the bottom of the texture rect
  face({ x1, y0, z1 }, { x0, y0, z1 }, { x0, y1, z1 }, { x1, y1, z1 },
    u + d, v, w, d, 0, 0, 1)
  -- bottom (-Z)
  face({ x1, y1, z0 }, { x0, y1, z0 }, { x0, y0, z0 }, { x1, y0, z0 },
    u + d + w, v, w, d, 0, 0, -1)
end

-- A flat, double-sided quad facing +Y, centred on the origin, size s.
function M.addFlatQuad(m, s)
  local h = s / 2
  M.addQuad(m, { -h, 0, h }, { h, 0, h }, { h, 0, -h }, { -h, 0, -h }, 0, 0, 1, 1, 0, -1, 0)
  M.addQuad(m, { h, 0, h }, { -h, 0, h }, { -h, 0, -h }, { h, 0, -h }, 0, 0, 1, 1, 0, 1, 0)
end

-- Build meshes (one per material) for a block state's quads, scaled by s and centred
-- on the origin. quads = the flat array world.lua keeps; matFor(page, layer) -> name.
local DIRV = {
  [0] = { 0, -1, 0 }, [1] = { 0, 1, 0 }, [2] = { 0, 0, -1 },
  [3] = { 0, 0, 1 },  [4] = { -1, 0, 0 }, [5] = { 1, 0, 0 },
}
function M.blockMeshes(quads, s, matFor)
  local byMat = {}
  for base = 1, #quads, 24 do
    local dir, layer, page = quads[base + 1], quads[base + 2], quads[base + 3]
    local name = matFor(page, layer)
    local m = byMat[name]
    if not m then m = newMesh(name) byMat[name] = m end
    local c = {}
    for k = 0, 3 do
      local px = quads[base + 4 + k * 3] - 0.5
      local py = quads[base + 5 + k * 3] - 0.5
      local pz = quads[base + 6 + k * 3] - 0.5
      c[k + 1] = { px * s, -pz * s, py * s }   -- MC -> BeamNG axes
    end
    local u = {}
    for k = 0, 3 do u[k + 1] = { quads[base + 16 + k * 2], quads[base + 17 + k * 2] } end
    local d = DIRV[dir] or DIRV[1]
    -- MC quads are CCW from outside: emit as (0,3,2,1) to get clockwise
    local verts, uvs, normals, faces = m.verts, m.uvs, m.normals, m.faces
    local b = #verts
    for k = 1, 4 do
      verts[b + k] = { x = c[k][1], y = c[k][2], z = c[k][3] }
      uvs[b + k] = { u = u[k][1], v = u[k][2] }
    end
    local n = #normals
    normals[n + 1] = { x = d[1], y = -d[3], z = d[2] }
    local f = #faces
    faces[f + 1] = { v = b, n = n, u = b }
    faces[f + 2] = { v = b + 2, n = n, u = b + 2 }
    faces[f + 3] = { v = b + 1, n = n, u = b + 1 }
    faces[f + 4] = { v = b, n = n, u = b }
    faces[f + 5] = { v = b + 3, n = n, u = b + 3 }
    faces[f + 6] = { v = b + 2, n = n, u = b + 2 }
  end
  local list = {}
  for _, m in pairs(byMat) do list[#list + 1] = m end
  return list
end

-- Every object made here is a visual (Steve, mobs, items, particles): never part of
-- BeamNG's static collision. A collision rebuild bakes whatever has collision into
-- solid walls where it stood - a dropped feather stopped a car dead - and scene
-- raycasts would hit them. World code switches their collision off around rebuilds
-- and its own raycasts (M.eachVisual). It can't stay off: a ProceduralMesh with
-- collision disabled isn't drawn either.
-- Parked objects (pooled particles, spare mob parts, all far below the map) are
-- skipped: toggling every pooled object cost over a millisecond per raycast batch.
M.visuals = setmetatable({}, { __mode = 'k' })
M.parked = setmetatable({}, { __mode = 'k' })
function M.park(obj) M.parked[obj] = true end
function M.unpark(obj) M.parked[obj] = nil end
function M.eachVisual(fn)
  local parked = M.parked
  for obj in pairs(M.visuals) do
    if not parked[obj] then
      local ok = pcall(fn, obj)
      if not ok then M.visuals[obj] = nil end
    end
  end
end

local counter = 0
function M.newObject(prefix, meshes)
  counter = counter + 1
  local obj = createObject('ProceduralMesh')
  obj:setPosition(vec3(0, 0, -10000))
  obj.canSave = false
  obj:registerObject(string.format('%s_%d', prefix, counter))
  scenetree.MissionGroup:add(obj.obj)
  -- one mesh group only: an empty extra group ({ meshes, {} }) makes createMesh fail
  -- ("verts must be a table"), and a group holding an empty mesh crashes BeamNG
  if meshes and #meshes > 0 then obj:createMesh({ meshes }) end
  M.visuals[obj] = true
  return obj
end

function M.deleteObject(obj)
  if obj then
    M.visuals[obj] = nil
    M.parked[obj] = nil
    pcall(function() obj:delete() end)
  end
end

------------------------------------------------------------------------------
-- materials: definitions are batched into one json file and loaded together
------------------------------------------------------------------------------

local known, pending = {}, {}

-- bumped whenever material definitions change shape, so a running game gets fresh
-- objects instead of keeping the old ones
M.suffix = '_r7'

function M.material(name, def)
  name = name .. M.suffix
  if known[name] or pending[name] then return name end
  def.name, def.mapTo, def.class = name, name, 'Material'
  def.version = def.version or 1.5
  pending[name] = def
  return name
end

-- a material showing one texture; kind = 'solid' | 'cutout' | 'translucent'
function M.textureMaterial(name, texture, kind, ground, opacityTexture, matte)
  local def = {
    Stages = { { baseColorMap = texture, roughnessFactor = matte and 1 or 0.92, metallicFactor = 0 }, {}, {}, {} },
    groundType = ground or 'ROCK', materialTag0 = 'beamcraft', castShadows = true,
  }
  if matte then def.dynamicCubemap = false end
  -- v1.5 materials take alpha from opacityMap, not from the colour map's alpha
  if kind == 'cutout' then
    def.Stages[1].opacityMap = opacityTexture or texture
    def.alphaTest, def.alphaRef, def.doubleSided = true, 110, true
  elseif kind == 'translucent' then
    def.Stages[1].opacityMap = opacityTexture or texture
    def.translucent, def.translucentBlendOp, def.translucentZWrite, def.doubleSided = true, 'LerpAlpha', false, true
  end
  return M.material(name, def)
end

-- Only the new definitions go to a fresh file each time: rewriting and reloading
-- every material ever made (hundreds, with particle tints) cost up to 60 ms per new
-- material, and fights spawn lots of them.
local flushCount = 0
local GEN = '/beamcraft/generated/'
function M.flushMaterials()
  if next(pending) == nil then return end
  local batch = {}
  for n, d in pairs(pending) do batch[n] = d known[n] = d end
  pending = {}
  flushCount = flushCount + 1
  local path = string.format('%sm_%d.materials.json', GEN, flushCount)
  jsonWriteFile(path, batch, false)
  loadJsonMaterialsFile(path)
end

-- material batches from an earlier run (BeamNG keeps what it loaded in memory)
function M.cleanGenerated()
  for _, f in ipairs(FS:findFiles(GEN, 'm_*.materials.json', 0, false, false) or {}) do FS:removeFile(f) end
end

function M.reloadMaterials(prefix)
  for name in pairs(known) do
    if not prefix or name:find(prefix, 1, true) == 1 then
      local mat = scenetree.findObject(name)
      if mat then pcall(function() mat:reload() end) end
    end
  end
end

function M.forgetMaterials(prefix)
  for name in pairs(known) do
    if name:find(prefix, 1, true) == 1 then known[name] = nil end
  end
end

return M
