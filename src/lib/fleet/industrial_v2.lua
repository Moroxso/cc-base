local Industrial=require("lib.fleet.industrial_base")
local basePlan=Industrial.plan
local baseSelfTest=Industrial.selfTest

Industrial.VERSION="0.23.0-alpha.6.2"

-- alpha6.2 Box/Quarry executors use an exact reverse of the excavated prefix for
-- safe return. The worst-case return path is therefore the full work volume.
Industrial.plan=function(spec)
    local plan,err=basePlan(spec)
    if not plan then return nil,err end
    if plan.type==Industrial.TYPE_EXCAVATE or plan.type==Industrial.TYPE_QUARRY then
        plan.returnMoves=plan.volume
        plan.estimatedMoves=plan.workMoves+plan.returnMoves
        plan.fuelRequired=plan.estimatedMoves+plan.fuelReserve
    end
    return plan
end

Industrial.selfTest=function()
    local ok,failures=baseSelfTest()
    failures=type(failures)=="table" and failures or {}
    local box=Industrial.plan({type="excavate_box",width=2,length=3,height=2,stepDelay=0.15})
    if not box or box.returnMoves~=12 or box.fuelRequired~=88 then
        failures[#failures+1]="box_exact_retrace_fuel"
    end
    return ok and #failures==0,failures
end

return Industrial
