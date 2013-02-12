(function(S)
S.MAX_ITERATIONS = 1000

-- ****************************************************************************

local function documentOrder(a,b) return a._order < b._order end
local function exitOrder(a,b)     return b._order < a._order end
local function isAtomicState(s)   return s.isAtomic          end
local function findLCPA(first,rest) -- least common parallel ancestor
	for _,anc in ipairs(first.ancestors) do
		if anc.kind=='parallel' then
			if rest:every(function(s) return s:descendantOf(anc) end) then
				return anc
			end
		end
	end
end

local function findLCCA(first,rest) -- least common compound ancestor
	for _,anc in ipairs(first.ancestors) do
		if anc.isCompound then
			if rest:every(function(s) return s:descendantOf(anc) end) then
				return anc
			end
		end
	end
end

-- ****************************************************************************

function S:interpret()
	-- if not self:validate() then self:failWithError() end
	self:expandScxmlSource()
	self.configuration  = OrderedSet()
	-- self.statesToInvoke = OrderedSet()
	self.datamodel      = LXSC.Datamodel()
	self.historyValue   = {}

	-- self:executeGlobalScriptElements()
	self.internalQueue = Queue()
	self.externalQueue = Queue()
	self.running = true
	if self.binding == "early" then self.datamodel:initAll(self) end
	self:executeTransitionContent(self.initial.transitions)
	self:enterStates(self.initial.transitions)
	self:mainEventLoop()
end

function S:mainEventLoop()
	local anyChange, enabledTransitions, stable, iterations
	while self.running do
		anyChange = false
		stable = false
		iterations = 0
		while self.running and not stable and iterations<self.MAX_ITERATIONS do
			enabledTransitions = self:selectEventlessTransitions()
			if enabledTransitions:isEmpty() then
				if self.internalQueue:isEmpty() then
					stable = true
				else
					local internalEvent = internalQueue:dequeue()
					self.datamodel:set("_event",internalEvent)
					enabledTransitions = self:selectTransitions(internalEvent)
				end
			end
			if not enabledTransitions:isEmpty() then
				anyChange = true
				self:microstep(enabledTransitions:toList()) -- TODO: (optimization) can remove toList() call
			end
			iterations = iterations + 1
		end

		if iterations>=S.MAX_ITERATIONS then print(string.format("Warning: stopped unstable system after %d internal iterations",S.MAX_ITERATIONS)) end

		-- for _,state in ipairs(self.statesToInvoke) do
		-- 	for _,inv in ipairs(state.invokes) do
		-- 		self:invoke(inv)
		-- 	end
		-- end
		-- self.statesToInvoke:clear()

		if self.internalQueue:isEmpty() then
			local externalEvent = self.externalQueue:dequeue()
			if externalEvent then
				if externalEvent.name=='quit.lxsc' then
					self.running = false
				else
					self.datamodel:set("_event",externalEvent)
					-- for _,state in ipairs(self.configuration) do
					-- 	for _,inv in ipairs(state.invokes) do
					-- 		if inv.invokeid == externalEvent.invokeid then
					-- 			self:applyFinalize(inv, externalEvent)
					-- 		end
					-- 		if inv.autoforward then
					-- 			self:send(inv.id, externalEvent)
					-- 		end
					-- 	end
					-- end
					enabledTransitions = self:selectTransitions(externalEvent)
					if not enabledTransitions:isEmpty() then
						anyChange = true
						self:microstep(enabledTransitions:toList()) -- TODO: (optimization) can remove toList() call
					end
				end
			end
		end

		if not anyChange then break end
	end

	if not self.running then self:exitInterpreter() end
end

function S:exitInterpreter()
	local statesToExit = self.configuration:toList():sort(documentOrder)
	for _,s in ipairs(statesToExit) do
		for _,content in ipairs(s.onexits) do self:executeContent(content) end
		-- for _,inv     in ipairs(s.invokes) do self:cancelInvoke(inv)       end
		-- self.configuration:delete(s)
		-- if self:isFinalState(s) and s.parent.kind=='scxml' then
		-- 	self:returnDoneEvent(s:donedata())
		-- end
	end
end

function S:selectEventlessTransitions()
	local enabledTransitions = OrderedSet()
	local atomicStates = self.configuration:toList():filter(isAtomicState):sort(documentOrder)
	for _,state in ipairs(atomicStates) do
		self:addEventlessTransition(state,enabledTransitions)
	end
	return self:filterPreempted(enabledTransitions)
end
-- TODO: store sets of evented vs. eventless transitions
function S:addEventlessTransition(state,enabledTransitions)
	for _,s in ipairs(state.selfAndAncestors) do
		for _,t in ipairs(s.transitions) do
			if not t.events and t:conditionMatched(self.datamodel) then
				enabledTransitions:add(t)
				return
			end
		end
	end
end

function S:selectTransitions(event)
	local enabledTransitions = OrderedSet()
	local atomicStates = self.configuration:toList():filter(isAtomicState):sort(documentOrder)
	for _,state in ipairs(atomicStates) do
		self:addTransitionForEvent(state,event,enabledTransitions)
	end
	return self:filterPreempted(enabledTransitions)
end
-- TODO: store sets of evented vs. eventless transitions
function S:addTransitionForEvent(state,event,enabledTransitions)
	for _,s in ipairs(state.selfAndAncestors) do
		for _,t in ipairs(s.transitions) do
			if t.events and t:matchesEvent(event) and t:conditionMatched(self.datamodel) then
				enabledTransitions:add(t)
				return
			end
		end
	end
end

function S:filterPreempted(enabledTransitions)
	local filteredTransitions = OrderedSet()
	for _,t1 in ipairs(enabledTransitions) do
		local anyPreemption = false
		for _,t2 in ipairs(filteredTransitions) do
			local t2Cat = self:preemptionCategory(t2)
			if t2Cat==3 or (t2Cat==2 and self:preemptionCategory(t1)==3) then
				anyPreemption = true
				break
			end
		end
		if not anyPreemption then filteredTransitions:add(t1) end
	end
	return filteredTransitions
end
function S:preemptionCategory(t)
	if not t.preemptionCategory then
		if not t.targets then
			t.preemptionCategory = 1
		elseif findLCPA( t.type=="internal" and t.parent or t.parent.parent, t.targets ) then
			t.preemptionCategory = 2
		else
			t.preemptionCategory = 3
		end
	end
	return t.preemptionCategory
end

function S:microstep(enabledTransitions)
	self:exitStates(enabledTransitions)
	self:executeTransitionContent(enabledTransitions)
	self:enterStates(enabledTransitions)
end

function S:executeTransitionContent(transitions)
	for _,t in ipairs(transitions) do
		for _,executable in ipairs(t.exec) do
			self:executeContent(executable)
		end
	end
end

function S:exitStates(enabledTransitions)
	local statesToExit = OrderedSet()
	for _,t in ipairs(enabledTransitions) do
		if t.targets then
			local ancestor
			if t.type == "internal" and t.source.isCompound and t.targets:every(function(s) return s:descendantOf(t.source) end) then
				ancestor = t.source
			else
				ancestor = findLCCA(t.source, t.targets)
			end
			for _,s in ipairs(self.configuration) do
				if s:descendantOf(ancestor) then statesToExit:add(s) end
			end
		end
	end

	-- for _,s in ipairs(statesToExit) do self.statesToInvoke:delete(s) end

	statesToExit = statesToExit:toList():sort(exitOrder)

	for _,s in ipairs(statesToExit) do
		-- TODO: create special history collection for speed
		for _,h in ipairs(s.states) do
			if h.kind=='history' then
				if self.historyValue[h.id] then
					self.historyValue[h.id]:clear()
				else
					self.historyValue[h.id] = OrderedSet()
				end
				for _,s0 in ipairs(self.configuration) do
					if h.type=='deep' then
						if s0.isAtomic and s0:descendantOf(s) then self.historyValue[h.id]:add(s0) end
					else
						if s0.parent==s then self.historyValue[h.id]:add(s0) end
					end
				end
			end
		end
	end

	for _,s in ipairs(statesToExit) do
		for _,content in ipairs(s.onexits) do self:executeContent(content) end
		-- for _,inv in ipairs(s.invokes)     do self:cancelInvoke(inv) end
		self.configuration:delete(s)
	end
end

function S:enterStates(enabledTransitions)
	local statesToEnter = OrderedSet()
	local statesForDefaultEntry = OrderedSet()

	local function addStatesToEnter(state)		
		if state.kind=='history' then
			if self.historyValue[state.id] then
				for _,s in ipairs(self.historyValue[state.id]) do
					addStatesToEnter(s)
					for anc in s:ancestorsUntil(state) do statesToEnter:add(anc) end
				end
			else
				for _,t in ipairs(state.transitions) do
					for _,s in ipairs(t.targets) do addStatesToEnter(s) end
				end
			end
		else
			statesToEnter:add(state)
			if state.isCompound then
				statesForDefaultEntry:add(state)
				for _,s in ipairs(state.initial.transitions[1].targets) do addStatesToEnter(s) end
			elseif state.kind=='parallel' then
				for _,s in ipairs(state.reals) do addStatesToEnter(s) end
			end
		end
	end

	for _,t in ipairs(enabledTransitions) do		
		if t.targets then
			local ancestor
			if t.type=="internal" and t.source.isCompound and t.targets:every(function(s) return s:descendantOf(t.source) end) then
				ancestor = t.source
			else
				ancestor = findLCCA(t.source, t.targets)
			end
			for _,s in ipairs(t.targets) do addStatesToEnter(s) end
			for _,s in ipairs(t.targets) do
				for anc in s:ancestorsUntil(ancestor) do
					statesToEnter:add(anc)
					if anc.kind=='parallel' then
						for _,child in ipairs(anc.reals) do
							if not statesToEnter:some(function(s) return s:descendantOf(child) end) then
								addStatesToEnter(child)
							end
						end
					end
				end
			end
		end
	end

	statesToEnter = statesToEnter:toList():sort(documentOrder)
	for _,s in ipairs(statesToEnter) do
		self.configuration:add(s)
		-- self.statesToInvoke:add(s)
		if self.binding=="late" then self.datamodel:initState(s) end -- The datamodel ensures this happens only once per state
		for _,content in ipairs(s.onentrys) do self:executeContent(content) end
		if statesForDefaultEntry:member(s) then self:executeTransitionContent(s.initial.transitions) end
		if s.kind=='final' then
			local parent = s.parent
			local grandparent = parent.parent
			self:fireEvent( "done.state."..parent.id, s:donedata(), true )
			if grandparent and grandparent.kind=='parallel' then
				local allAreInFinal = true
				for _,child in ipairs(grandparent.reals) do
					if not isInFinalState(child) then
						allAreInFinal = false
						break
					end
				end
				if allAreInFinal then self:fireEvent( "done.state."..grandparent.id ) end
			end
		end
	end

	for _,s in ipairs(self.configuration) do
		if s.kind=='final' and s.parent.kind=='scxml' then self.running = false end
	end
end

function S:fireEvent(name,data,internalFlag)
	self[internalFlag and "internalQueue" or "externalQueue"]:enqueue(LXSC.Event(name,data))
end

-- Sensible aliases
S.start = S.interpret
S.step  = S.mainEventLoop	

end)(LXSC.SCXML)