-- Resolved vanilla item geometry already includes the ground / hand display transform.
local mu = require('beamcraft/meshutil')
local M = {}
local models = {}
function M.define(msg) models[msg.id] = msg.q end
function M.meshes(id)
  local quads = models[id]
  if not quads then return nil end
  local groups = {}
  for _, q in ipairs(quads) do
    local name = mu.textureMaterial('bc_item_' .. q.tex:gsub('[^%w]', '_'), q.tex, 'cutout', nil, q.mask, true)
    local m = groups[name]
    if not m then m = mu.newMesh(name) groups[name] = m end
    local p, uv, v0, n0 = q.p, q.uv, #m.verts, #m.normals
    local u = vec3(p[4]-p[1],p[5]-p[2],p[6]-p[3])
    local v = vec3(p[7]-p[1],p[8]-p[2],p[9]-p[3])
    local n = u:cross(v):normalized()
    m.normals[n0+1] = {x=n.x,y=n.y,z=n.z}
    for k=0,3 do
      m.verts[v0+k+1] = {x=p[k*3+1],y=p[k*3+2],z=p[k*3+3]}
      m.uvs[v0+k+1] = {u=uv[k*2+1],v=uv[k*2+2]}
    end
    for _, k in ipairs({0,2,1,0,3,2}) do m.faces[#m.faces+1]={v=v0+k,u=v0+k,n=n0} end
  end
  mu.flushMaterials()
  local list={} for _, m in pairs(groups) do list[#list+1]=m end
  return list
end
function M.object(id, name)
  local meshes=M.meshes(id)
  return meshes and mu.newObject(name or 'beamcraft_item',meshes) or nil
end
return M
