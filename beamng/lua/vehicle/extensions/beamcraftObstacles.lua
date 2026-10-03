-- Minecraft construction adds a braking constraint to native AI input, while
-- preserving the AI's route, cruising speed and isDriving state.
local M={}
local distance=-1
local ttl=0
local nativeEvent,wrappedEvent
function M.setDistance(d) distance=d ttl=1.5 end
function M.updateGFX(dt) ttl=ttl-dt end
function M.onExtensionLoaded()
  nativeEvent=input.event
  wrappedEvent=function(name,value,filter,...)
    if ttl>0 and distance>=0 and filter=='FILTER_AI' and ai.mode~='disabled' then
      local speed=obj:getVelocity():length()
      local stop=3+speed*0.5+speed*speed/10
      if distance<stop then
        if name=='throttle' then value=0
        elseif name=='brake' then value=math.max(value,math.max(0.3,math.min(1,(stop-distance)/math.max(3,stop*0.5)))) end
      end
    end
    return nativeEvent(name,value,filter,...)
  end
  input.event=wrappedEvent
end
function M.onExtensionUnloaded() if input.event==wrappedEvent then input.event=nativeEvent end end
return M
