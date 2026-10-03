local mu=require('beamcraft/meshutil')
local coords=require('beamcraft/coords')
local M={}
local particles={}
local stamp=0
local function step(v,n) return math.floor(math.max(0,math.min(1,v))*n+0.5)/n end
function M.snapshot(msg,now)
  stamp=stamp+1
  local pending=false
  for _, p in ipairs(msg.l or {}) do
    local r,g,b,a=step(p.r,16),step(p.g,16),step(p.b,16),step(p.a,16)
    local key=p.tex..':'..r..':'..g..':'..b..':'..a..':'..table.concat(p.uv,',')
    local ent=particles[p.id]
    if not ent then ent={cur=p} particles[p.id]=ent end
    if ent.key~=key then
      mu.deleteObject(ent.obj)
      local mat=mu.material('bc_particle_'..key:gsub('[^%w]','_'), {
        Stages={{baseColorMap=p.tex,baseColorFactor={r,g,b,1},opacityMap=p.mask,opacityFactor=a,roughnessFactor=1,metallicFactor=0},{},{},{}},
        translucent=true,translucentBlendOp='LerpAlpha',translucentZWrite=false,doubleSided=true,castShadows=false, useAnisotropic=false,
      })
      local m=mu.newMesh(mat)
      mu.addQuad(m,{-1,0,1},{1,0,1},{1,0,-1},{-1,0,-1},p.uv[1],p.uv[2],p.uv[3],p.uv[4],0,-1,0)
      ent.obj=mu.newObject('beamcraft_particle', {m}) ent.key=key pending=true
    end
    ent.prev,ent.cur,ent.at,ent.seen=ent.cur,p,now,stamp
  end
  if pending then mu.flushMaterials() end
  for id,e in pairs(particles) do if e.seen~=stamp then mu.deleteObject(e.obj) particles[id]=nil end end
end
function M.update(now)
  local camera=getCameraPosition()
  for _,e in pairs(particles) do
    local t=math.min(1,(now-e.at)/0.05) local p,c=e.prev,e.cur
    local x,y,z=coords.mcToBng(p.x+(c.x-p.x)*t,p.y+(c.y-p.y)*t,p.z+(c.z-p.z)*t)
    local dir=(camera-vec3(x,y,z)):normalized()
    -- quad faces -Y; rotate this plane to face the camera, then apply vanilla roll.
    local yaw=math.atan2(dir.x,-dir.y)
    local pitch=math.asin(math.max(-1,math.min(1,dir.z)))
    local q=mu.qmul(mu.qaxis(0,0,1,yaw),mu.qmul(mu.qaxis(1,0,0,-pitch),mu.qaxis(0,1,0,c.roll or 0)))
    mu.setXform(e.obj,x,y,z,q) e.obj:setScale(vec3(c.s,c.s,c.s))
  end
end
function M.clear() for _,e in pairs(particles) do mu.deleteObject(e.obj) end particles={} end
return M
