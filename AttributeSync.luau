--!strict
--!optimize 2

local getService = game.GetService
local typeOf = typeof
local raiseError = error
local warnMessage = warn
local protectCall = pcall
local toString = tostring
local setMeta = setmetatable
local getMeta = getmetatable
local tableCreate = table.create
local tableFind = table.find
local tableFreeze = table.freeze
local stringMatch = string.match
local stringUpper = string.upper
local stringSub = string.sub
local spawnTask = task.spawn
local huge = math.huge

local CollectionService = getService(game, "CollectionService")
local getTagged = CollectionService.GetTagged
local hasTag = CollectionService.HasTag
local getAddedSignal = CollectionService.GetInstanceAddedSignal
local getRemovedSignal = CollectionService.GetInstanceRemovedSignal

local methodSource = Instance.new("Folder")
local getFullName = methodSource.GetFullName
local getAttribute = methodSource.GetAttribute
local setAttribute = methodSource.SetAttribute
local getAttributeChangedSignal = methodSource.GetAttributeChangedSignal
methodSource:Destroy()
methodSource = nil :: any

local AttributeSync = {}

export type FieldOptions<V> = {
	min: number?,
	max: number?,
	oneOf: { V }?,
	validate: ((value: V) -> boolean)?,
}

type Spec = {
	default: any,
	type: string,
	min: number?,
	max: number?,
	oneOf: { any }?,
	allowed: { [any]: true }?,
	validate: ((value: any) -> boolean)?,
	plain: boolean,
}

type State = {
	Instance: Instance,
	Specs: { [string]: Spec },
	Warned: { [string]: boolean }?,
}

local SpecMeta = {}
local Meta = {}

local States = {}
setMeta(States, { __mode = "k" })

local Cache = {}
setMeta(Cache, { __mode = "k" })

local SUPPORTED_ATTRIBUTE_TYPES: { [string]: boolean } = {
	boolean = true,
	BrickColor = true,
	CFrame = true,
	Color3 = true,
	ColorSequence = true,
	NumberRange = true,
	NumberSequence = true,
	number = true,
	Rect = true,
	string = true,
	UDim = true,
	UDim2 = true,
	Vector2 = true,
	Vector3 = true,
}

local function stateOf(wrapper: any): State
	local state = States[wrapper]
	if state == nil then
		raiseError("AttributeSync: expected a live wrapper returned by AttributeSync.new", 3)
	end
	return state
end

local function validateAttributeName(name: string)
	if name == "" or #name > 100 then
		raiseError('AttributeSync: attribute name "' .. name .. '" must contain 1 to 100 characters', 3)
	end

	if not stringMatch(name, "^[%w%._/%-]+$") then
		raiseError('AttributeSync: attribute name "' .. name .. '" contains unsupported characters', 3)
	end

	if stringUpper(stringSub(name, 1, 3)) == "RBX" then
		raiseError('AttributeSync: attribute name "' .. name .. '" cannot start with "RBX"', 3)
	end
end

local function isFiniteNumber(value: number): boolean
	return value == value and value ~= huge and value ~= -huge
end

local function cloneList(list: { any }?): { any }?
	if list == nil then
		return nil
	end

	local result = tableCreate(#list)
	for index, value in list do
		result[index] = value
	end
	return result
end

local function toSpec(raw: any): Spec
	if getMeta(raw) == SpecMeta then
		local descriptor = raw :: any
		return {
			default = descriptor.default,
			type = "",
			min = descriptor.min,
			max = descriptor.max,
			oneOf = cloneList(descriptor.oneOf),
			validate = descriptor.validate,
			plain = false,
		}
	end

	return {
		default = raw,
		type = "",
		plain = false,
	}
end

local function finalize(spec: Spec, name: string)
	if spec.default == nil then
		raiseError('AttributeSync: "' .. name .. '" needs a non-nil default', 3)
	end

	local valueType = typeOf(spec.default)
	if not SUPPORTED_ATTRIBUTE_TYPES[valueType] then
		raiseError(
			'AttributeSync: "'
				.. name
				.. '" uses unsupported attribute type "'
				.. valueType
				.. '"; use a Roblox-supported attribute type',
			3
		)
	end

	if (spec.min ~= nil or spec.max ~= nil) and valueType ~= "number" then
		raiseError('AttributeSync: min/max can only be used with number fields ("' .. name .. '")', 3)
	end

	if spec.min ~= nil and not isFiniteNumber(spec.min) then
		raiseError('AttributeSync: min for "' .. name .. '" must be a finite number', 3)
	end
	if spec.max ~= nil and not isFiniteNumber(spec.max) then
		raiseError('AttributeSync: max for "' .. name .. '" must be a finite number', 3)
	end
	if spec.min ~= nil and spec.max ~= nil and spec.min > spec.max then
		raiseError('AttributeSync: min cannot exceed max for "' .. name .. '"', 3)
	end

	local oneOf = spec.oneOf
	if oneOf ~= nil then
		if #oneOf == 0 then
			raiseError('AttributeSync: oneOf for "' .. name .. '" cannot be empty', 3)
		end

		for _, candidate in oneOf do
			if typeOf(candidate) ~= valueType then
				raiseError('AttributeSync: every oneOf value for "' .. name .. '" must be of type ' .. valueType, 3)
			end
		end
	end

	spec.type = valueType

	if oneOf ~= nil and (valueType == "string" or valueType == "number" or valueType == "boolean") then
		local allowed: { [any]: true } = {}
		for _, candidate in oneOf do
			allowed[candidate] = true
		end
		spec.allowed = allowed
	end

	spec.plain = valueType ~= "number" and oneOf == nil and spec.validate == nil
end

local function coerce(spec: Spec, value: any): (any, string?)
	local expected = spec.type
	local actual = typeOf(value)
	if actual ~= expected then
		return nil, "expects " .. expected .. ", got " .. actual
	end

	if spec.plain then
		return value, nil
	end

	if expected == "number" then
		if not isFiniteNumber(value) then
			return nil, "must be a finite number (NaN and infinity are not allowed)"
		end

		if spec.min ~= nil and value < spec.min then
			value = spec.min
		end
		if spec.max ~= nil and value > spec.max then
			value = spec.max
		end
	end

	local allowed = spec.allowed
	if allowed ~= nil then
		if not allowed[value] then
			return nil, "is not an allowed value"
		end
	elseif spec.oneOf ~= nil and not tableFind(spec.oneOf, value) then
		return nil, "is not an allowed value"
	end

	if spec.validate ~= nil then
		local ok, valid = protectCall(spec.validate, value)
		if not ok then
			return nil, "validator raised an error: " .. toString(valid)
		end
		if valid ~= true then
			return nil, "failed validation"
		end
	end

	return value, nil
end

local function sameList(a: { any }?, b: { any }?): boolean
	if a == b then
		return true
	end
	if a == nil or b == nil or #a ~= #b then
		return false
	end
	for index = 1, #a do
		if a[index] ~= b[index] then
			return false
		end
	end
	return true
end

local function sameSpec(existing: Spec, raw: any): boolean
	if getMeta(raw) == SpecMeta then
		local other = raw :: any
		return other.default == existing.default
			and other.min == existing.min
			and other.max == existing.max
			and other.validate == existing.validate
			and sameList(other.oneOf, existing.oneOf)
	end

	return raw == existing.default
		and existing.min == nil
		and existing.max == nil
		and existing.oneOf == nil
		and existing.validate == nil
end

local function register(state: State, defaults: { [string]: any }, initial: { [string]: any }?)
	local instance = state.Instance
	local pendingSpecs: { [string]: Spec } = {}
	local pendingWrites: { [string]: any } = {}

	for name, raw in defaults do
		validateAttributeName(name)

		local existing = state.Specs[name]
		if existing ~= nil then
			if not sameSpec(existing, raw) then
				local warned: { [string]: boolean } = state.Warned or {}
				state.Warned = warned

				if not warned[name] then
					warned[name] = true
					warnMessage(
						'AttributeSync: "'
							.. name
							.. '" on '
							.. getFullName(instance)
							.. " was registered with a different spec; keeping the first spec"
					)
				end
			end
			continue
		end

		local spec = toSpec(raw)
		finalize(spec, name)

		local cleanDefault, defaultError = coerce(spec, spec.default)
		if defaultError ~= nil or cleanDefault ~= spec.default then
			raiseError('AttributeSync: default for "' .. name .. '" ' .. (defaultError or "is out of range"), 3)
		end

		local currentValue = getAttribute(instance, name)
		if currentValue == nil then
			local valueToWrite = spec.default
			if initial ~= nil and initial[name] ~= nil then
				local cleanInitial, initialError = coerce(spec, initial[name])
				if initialError ~= nil then
					raiseError('AttributeSync: initial value for "' .. name .. '" ' .. initialError, 3)
				end
				valueToWrite = cleanInitial
			end
			pendingWrites[name] = valueToWrite
		else
			local cleanCurrent, currentError = coerce(spec, currentValue)
			if currentError ~= nil or cleanCurrent ~= currentValue then
				raiseError(
					'AttributeSync: existing attribute "'
						.. name
						.. '" is incompatible with its schema: '
						.. (currentError or "value is outside the allowed range"),
					3
				)
			end
		end

		pendingSpecs[name] = spec
	end

	if initial ~= nil then
		for name in initial do
			if defaults[name] == nil then
				raiseError('AttributeSync: initial value "' .. name .. '" has no matching default/schema field', 3)
			end
		end
	end

	for name, value in pendingWrites do
		setAttribute(instance, name, value)
	end
	for name, spec in pendingSpecs do
		state.Specs[name] = spec
	end
end

function Meta.__index(proxy: any, key: string): any
	local state = stateOf(proxy)
	local spec = state.Specs[key]
	if spec == nil then
		raiseError('AttributeSync: "' .. key .. '" is not in the schema', 2)
	end

	local value = getAttribute(state.Instance, key)
	if value == nil then
		return spec.default
	end
	return value
end

function Meta.__newindex(proxy: any, key: string, value: any)
	local state = stateOf(proxy)
	local spec = state.Specs[key]
	if spec == nil then
		raiseError('AttributeSync: "' .. key .. '" is not in the schema', 2)
	end

	local clean, validationError = coerce(spec, value)
	if validationError ~= nil then
		raiseError('AttributeSync: "' .. key .. '" ' .. validationError, 2)
	end

	setAttribute(state.Instance, key, clean)
end

function AttributeSync.field<V>(default: V, options: FieldOptions<V>?): V
	local spec: any = { default = default }
	if options ~= nil then
		spec.min = options.min
		spec.max = options.max
		spec.oneOf = cloneList(options.oneOf :: any)
		spec.validate = options.validate
	end

	if spec.oneOf ~= nil then
		tableFreeze(spec.oneOf)
	end

	setMeta(spec, SpecMeta)
	return tableFreeze(spec) :: any
end

function AttributeSync.new<T>(instance: Instance, defaults: T, initial: { [string]: any }?): T
	local proxy = Cache[instance]
	if proxy == nil then
		proxy = setMeta({}, Meta)
		local state: State = {
			Instance = instance,
			Specs = {},
		}
		States[proxy] = state
		Cache[instance] = proxy

		instance.Destroying:Connect(function()
			if Cache[instance] == proxy then
				Cache[instance] = nil
			end
			States[proxy] = nil
		end)
	end

	local state = States[proxy]
	if state == nil then
		raiseError("AttributeSync: wrapper state is no longer available", 2)
	end

	register(state, defaults :: any, initial)
	return proxy :: any
end

function AttributeSync.GetChangedSignal(wrapper: any, name: string): RBXScriptSignal
	local state = stateOf(wrapper)
	if state.Specs[name] == nil then
		raiseError('AttributeSync: "' .. name .. '" is not in the schema', 2)
	end
	return getAttributeChangedSignal(state.Instance, name)
end

function AttributeSync.GetInstance(wrapper: any): Instance
	return stateOf(wrapper).Instance
end

function AttributeSync.Observe<T, V>(
	wrapper: T,
	key: string,
	callback: (new: V, old: V?) -> (),
	skipInitial: boolean?
): RBXScriptConnection
	local w = wrapper :: any
	local state = stateOf(w)
	if state.Specs[key] == nil then
		raiseError('AttributeSync: "' .. key .. '" is not in the schema', 2)
	end

	local last = w[key]
	local connection = getAttributeChangedSignal(state.Instance, key):Connect(function()
		local new = w[key]
		local old = last
		if new == old then
			return
		end

		last = new
		callback(new, old)
	end)

	if not skipInitial then
		local ok, callbackError = protectCall(function()
			callback(last, nil)
			return true
		end)

		if not ok then
			connection:Disconnect()
			raiseError(callbackError, 2)
		end
	end

	return connection
end

function AttributeSync.Reset(wrapper: any, key: string?)
	local state = stateOf(wrapper)
	if key ~= nil then
		local spec = state.Specs[key]
		if spec == nil then
			raiseError('AttributeSync: "' .. key .. '" is not in the schema', 2)
		end
		setAttribute(state.Instance, key, spec.default)
		return
	end

	for name, spec in state.Specs do
		setAttribute(state.Instance, name, spec.default)
	end
end

function AttributeSync.Update(wrapper: any, values: { [string]: any })
	local state = stateOf(wrapper)
	local clean: { [string]: any } = {}

	for key, value in values do
		local spec = state.Specs[key]
		if spec == nil then
			raiseError('AttributeSync: "' .. key .. '" is not in the schema', 2)
		end

		local cleaned, validationError = coerce(spec, value)
		if validationError ~= nil then
			raiseError('AttributeSync: "' .. key .. '" ' .. validationError, 2)
		end
		clean[key] = cleaned
	end

	for key, value in clean do
		setAttribute(state.Instance, key, value)
	end
end

function AttributeSync.ToTable<T>(wrapper: T): T
	local state = stateOf(wrapper)
	local result: any = {}

	for name, spec in state.Specs do
		local value = getAttribute(state.Instance, name)
		result[name] = if value == nil then spec.default else value
	end

	return result
end

AttributeSync.FromTable = AttributeSync.Update

function AttributeSync.BindTag<T>(tag: string, defaults: T, onBound: ((wrapper: T, instance: Instance) -> ())?): () -> ()
	local active = true
	local bound = {}
	setMeta(bound, { __mode = "k" })

	local epochs = {}
	setMeta(epochs, { __mode = "k" })

	local function bind(instance: Instance)
		if not active or not hasTag(CollectionService, instance, tag) or bound[instance] then
			return
		end

		bound[instance] = true
		local epoch = (epochs[instance] or 0) + 1
		epochs[instance] = epoch

		local ok, result = protectCall(function()
			return AttributeSync.new(instance, defaults)
		end)
		if not ok then
			bound[instance] = nil
			raiseError(result, 2)
		end
		local wrapper = result :: T

		if onBound ~= nil then
			spawnTask(function()
				if active and epochs[instance] == epoch and hasTag(CollectionService, instance, tag) then
					onBound(wrapper, instance)
				end
			end)
		end
	end

	local added = getAddedSignal(CollectionService, tag):Connect(bind)
	local removed = getRemovedSignal(CollectionService, tag):Connect(function(instance: Instance)
		bound[instance] = nil
		epochs[instance] = (epochs[instance] or 0) + 1
	end)
	for _, instance in getTagged(CollectionService, tag) do
		spawnTask(bind, instance)
	end

	local disconnected = false
	return function()
		if disconnected then
			return
		end
		disconnected = true
		active = false
		added:Disconnect()
		removed:Disconnect()
	end
end

return AttributeSync
