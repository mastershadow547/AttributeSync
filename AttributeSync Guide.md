# AttributeSync Guide

Oct 12, 2026 · @Warzone

## Overview

AttributeSync lets you read and write an Instance's attributes like normal properties (`boss.Health -= 25`), with types, defaults and validation checked for you.

Roblox attributes are untyped, have no defaults, and a typo in a name fails silently. AttributeSync fixes that with a small schema you write once.

- **Auto typing:** the schema is just your defaults table, so Luau knows `data.Health` is a number when reading and writing.
- **Validated writes:** wrong types, bad enum values, `NaN` and unknown keys all error instead of corrupting data. Numbers can be clamped to a range.
- **Shared wrappers:** every script that wraps the same Instance gets the same wrapper, and new schema keys merge in.
- **Lightweight:** one small table per wrapped Instance, one shared metatable, no polling and no connections unless you ask for them.
- **No leaks:** weak tables mean a wrapper is collected once nothing references it. The real data always lives in the attributes themselves.

## Getting started

Put the module in `ReplicatedStorage` (for example `ReplicatedStorage.Shared.Packages.AttributeSync`) and require it from any script.

```luau
local AttributeSync = require(game:GetService("ReplicatedStorage").Shared.Packages.AttributeSync)

local boss = workspace.Boss

local data = AttributeSync.new(boss, {
	Name = "Boss",
	Health = AttributeSync.field(500, { min = 0, max = 500 }),
	State = AttributeSync.field("Idle", { oneOf = { "Idle", "Chasing", "Dead" } }),
	Enraged = false,
})

data.Health -= 25          -- number, clamped to 0..500
data.State = "Chasing"     -- must be an allowed value
print(data.Name)           -- "Boss"
```

The first call creates any attribute that doesn't exist yet, using its default. Attributes that already exist keep their current value.

Place the module where every script that needs it can reach it. Server-only code can keep it in `ServerScriptService`.

## Defining a schema

A schema is a table of `name = default`. The default decides the key's type, so every default must be non-nil.

```luau
local data = AttributeSync.new(part, {
	Coins = 0,                       -- number
	Owner = "",                      -- string
	Locked = false,                  -- boolean
	Spawn = Vector3.new(0, 10, 0),   -- Vector3
	Tint = Color3.new(1, 1, 1),      -- Color3
})
```

The return type is the same as the table you pass in, which is why `data.Coins` is typed as a number and `data.Locked = "yes"` is flagged by the type checker.

Any type Roblox allows as an attribute works, including `string`, `number`, `boolean`, `Vector3`, `Color3`, `CFrame`, `UDim2`, `BrickColor` and `NumberRange`. Instance references are not supported by attributes. Store an `ObjectValue` or an id instead.

You can pass a third argument of starting values. They apply only to attributes that don't exist yet, and they must match the key's type.

```luau
local data = AttributeSync.new(part, { Owner = "" }, { Owner = player.Name })
```

Attribute names must be alphanumeric or underscores, under 100 characters, and must not start with `RBX`.

## Fields: constraints on a key

Wrap a default in `AttributeSync.field(default, options)` to add rules. The result is still typed as the default's type, so auto typing keeps working.

| Option | Applies to | What it does |
| --- | --- | --- |
| `min` | numbers | Values below it are raised to `min` (clamped) |
| `max` | numbers | Values above it are lowered to `max` (clamped) |
| `oneOf` | any type | Only values in the list are accepted, otherwise an error |
| `validate` | any type | A function returning `true` to accept, otherwise an error |

```luau
local data = AttributeSync.new(npc, {
	Health = AttributeSync.field(100, { min = 0, max = 100 }),
	State = AttributeSync.field("Idle", { oneOf = { "Idle", "Chasing", "Dead" } }),
	Level = AttributeSync.field(1, {
		validate = function(level: number)
			return level % 1 == 0 -- whole numbers only
		end,
	}),
})

data.Health = 150   -- stored as 100
data.Health = -20   -- stored as 0
data.State = "Flying"  -- error: not an allowed value
data.Level = 1.5       -- error: failed validation
```

The default itself must pass its own rules. A default of `500` with `max = 10` errors when you call `new`, and nothing is written.

## Reading, writing and sharing across scripts

Use the wrapper like a table. Reads return the live attribute, and writes go straight to the Instance after validation.

```luau
print(data.Health)       -- reads the attribute
data.Health += 10        -- validates, clamps, then writes it
data.Enraged = true
```

If something else clears an attribute (for example `instance:SetAttribute("Health", nil)`), reading it returns the schema default instead of `nil`.

Every call to `AttributeSync.new` for the same Instance returns the same wrapper, from any script. If a later call includes extra keys, they are merged in. Keys that are already registered are never changed, so a second script can't override the first script's defaults.

```luau
-- Script A
local data = AttributeSync.new(workspace.Boss, { Health = 500, Enraged = false })
data.Health -= 25

-- Script B: same wrapper, same attributes, plus a new key
local data = AttributeSync.new(workspace.Boss, { Health = 999, Phase = 1 })
print(data.Health)  -- 475 (the 999 is ignored, Health is already registered)
print(data.Phase)   -- 1
```

Keep a reference to the wrapper while you use it. If nothing holds it, it can be garbage collected, but calling `new` again simply rebuilds it from the attributes.

## Reacting to changes

Use `Observe` when you want the current value plus every future change. Use `GetChangedSignal` when you only want a plain signal.

`Observe(wrapper, key, callback)` calls your function right away with `(current, nil)`, then with `(new, old)` each time the value changes. It returns a connection, so disconnect it when you're done.

```luau
local connection = AttributeSync.Observe(data, "Health", function(new, old)
	if old == nil then
		print("starting health:", new)
	else
		print(`health {old} -> {new}`)
	end

	if new <= 0 then
		data.State = "Dead"
	end
end)

-- later
connection:Disconnect()
```

`GetChangedSignal(wrapper, key)` returns Roblox's `GetAttributeChangedSignal` for that key. It fires for changes made by any script, including ones that bypass the wrapper.

```luau
AttributeSync.GetChangedSignal(data, "Enraged"):Connect(function()
	print("enraged is now", data.Enraged)
end)
```

Both work for any key in the schema and error on unknown keys. They add one connection each, and only when you call them.

## Bulk operations and tag binding

`Update` sets several keys at once, and it is all or nothing: every value is validated first, so one bad value changes nothing.

```luau
AttributeSync.Update(data, { Health = 250, State = "Chasing" })
```

`Reset` puts one key, or every key, back to its default.

```luau
AttributeSync.Reset(data, "Health")  -- one key
AttributeSync.Reset(data)            -- every key
```

`ToTable` takes a plain-table snapshot of every schema key, and `FromTable` restores it with the same validation as `Update`. This works well for saving to a DataStore or sending state to another server.

```luau
local snapshot = AttributeSync.ToTable(data)
-- ...state changes...
AttributeSync.FromTable(data, snapshot)
```

`BindTag` wraps every Instance that has a CollectionService tag, including ones that already exist and ones that appear later (for example streamed in). It returns a function that stops binding new Instances.

```luau
local unbind = AttributeSync.BindTag("Enemy", {
	Health = AttributeSync.field(100, { min = 0, max = 100 }),
	State = "Idle",
}, function(wrapper, instance)
	print(instance.Name, "is ready with", wrapper.Health, "health")
end)

-- later, to stop wrapping new tagged Instances
unbind()
```

The optional third argument runs once per Instance as it is bound. Attributes on Instances that were already bound are left as they are when you call `unbind`.

## Errors, gotchas and best practices

Most mistakes raise a clear error that points at the line that caused it.

| What you did | What happens |
| --- | --- |
| Read or write a key that isn't in the schema | Error: not in the schema |
| Write the wrong type | Error: expects `number`, got `string` |
| Write `NaN` | Error: can't be `NaN` |
| Write a value that fails `oneOf` or `validate` | Error, value unchanged |
| Write a number outside `min` / `max` | Clamped, no error |
| Use a `nil` default | Error: needs a non-nil default |
| Bad default or starting value in `new` | Error, nothing is written or registered |

**Good habits**

- Define the full schema once in a shared module or at the top of your script, and reuse it.
- Keep the wrapper in a local variable while you use it instead of calling `new` in a hot loop.
- Disconnect `Observe` connections you no longer need. Connections to an Instance are cleaned up automatically when it is destroyed.
- Use `pcall` only where you expect bad input, such as values coming from players. Errors elsewhere usually mean a bug you want to see.

**Things to know**

- Attributes changed on the server replicate to clients. Changes made on a client do not replicate back to the server, so treat client writes as local only.
- The type checker catches wrong-type writes only when it can see the schema. If you cast the wrapper to `any`, only the runtime check remains.
- Values set outside the module are not re-validated when read. They are checked only when written through the wrapper.
- Attributes can't hold Instance references, tables or functions.

## API reference

| Function | Returns | Description |
| --- | --- | --- |
| `AttributeSync.new(instance, defaults, initial?)` | typed wrapper | Wraps an Instance with a schema. Returns the shared wrapper and merges in new keys. |
| `AttributeSync.field(default, options?)` | the default's type | Adds `min`, `max`, `oneOf` or `validate` rules to a key. |
| `AttributeSync.Observe(wrapper, key, callback)` | connection | Calls `callback(current, nil)` now, then `callback(new, old)` on each change. |
| `AttributeSync.GetChangedSignal(wrapper, key)` | signal | Roblox's attribute-changed signal for a schema key. |
| `AttributeSync.Update(wrapper, values)` | nothing | Sets several keys, all or nothing. |
| `AttributeSync.Reset(wrapper, key?)` | nothing | Restores one key, or all keys, to their defaults. |
| `AttributeSync.ToTable(wrapper)` | table | Plain snapshot of every schema key. |
| `AttributeSync.FromTable(wrapper, snapshot)` | nothing | Restores a snapshot, validated like `Update`. |
| `AttributeSync.BindTag(tag, defaults, onBound?)` | function | Wraps every Instance with the tag. Call the returned function to stop binding new ones. |
| `AttributeSync.GetInstance(wrapper)` | Instance | The Instance a wrapper belongs to. |

## Testing

The included test script runs every feature against `workspace` and prints a pass or fail line for each check.

1. Put the module at `ReplicatedStorage.Shared.Packages.AttributeSync`.
2. Add `AttributeSyncTests` as a regular `Script` in `ServerScriptService`.
3. Press Play or Run and watch the Output window.

A passing run ends with a summary line such as `AttributeSync tests finished: 50 passed, 0 failed`. Failed checks print with a warning and a short detail message.

The tests cover defaults and starting values, reads and writes, validation errors, sharing between scripts, change signals, clamping, `oneOf`, `validate`, failed registration, `Observe`, `Reset`, `Update`, snapshots and `BindTag`. All test attributes start with `Test_` and are removed when the run finishes.
