# AttributeSync Guide

**Oct 12, 2026 · @Warzone**

## Overview

AttributeSync lets you read and write an Instance's attributes like normal properties (`boss.Health -= 25`), with typed schemas, defaults, and validation.

Roblox attributes do not enforce your schema, provide schema defaults, or prevent misspelled attribute names. AttributeSync adds those conveniences while keeping the actual data stored on the Instance.

- **Auto typing:** Define a schema using a defaults table. Luau infers the types of your wrapper's fields.
- **Validated writes:** Reject wrong types, `NaN`, invalid enum values, and unknown schema keys. Numbers can be clamped to a range.
- **Shared wrappers:** Calls to `new` for the same Instance reuse the wrapper and can merge additional schema keys.
- **Change notifications:** Subscribe to attribute changes using `Observe` or `GetChangedSignal`.
- **Bulk operations:** Update multiple attributes atomically with respect to validation, reset values, and serialize snapshots.
- **Tag binding:** Automatically wrap existing and newly tagged Instances.
- **Memory-conscious design:** Weak references allow unused wrappers to be collected when nothing else retains them. Actual attribute data remains on the Instance.
- **Compiler directives:** The module uses `--!native` and `--!optimize 2` to request native code generation and level-2 optimization where supported.

AttributeSync is intended to be lightweight, but actual performance and memory usage depend on the workload and Roblox runtime.

## Getting started

Place the module somewhere accessible to the scripts that need it, such as `ReplicatedStorage.Shared.Packages.AttributeSync`.

```luau
local AttributeSync = require(
    game:GetService("ReplicatedStorage")
        .Shared.Packages.AttributeSync
)

local boss = workspace.Boss

local data = AttributeSync.new(boss, {
    Name = "Boss",
    Health = AttributeSync.field(500, { min = 0, max = 500 }),
    State = AttributeSync.field("Idle", {
        oneOf = { "Idle", "Chasing", "Dead" },
    }),
    Enraged = false,
})

data.Health -= 25
data.State = "Chasing"

print(data.Name) -- "Boss"
```

The first call initializes missing attributes using their defaults. Existing attributes are retained, subject to the module's registration and initialization rules.

## Defining a schema

A schema is a table of `name = default`. Each default determines the corresponding field's type and must be non-`nil`.

```luau
local data = AttributeSync.new(part, {
    Coins = 0,
    Owner = "",
    Locked = false,
    Spawn = Vector3.new(0, 10, 0),
    Tint = Color3.new(1, 1, 1),
})
```

AttributeSync supports Roblox attribute-compatible values, including strings, numbers, booleans, `Vector3`, `Color3`, `CFrame`, `UDim2`, `BrickColor`, `NumberRange`, and other supported attribute types. Instance references, tables, and functions cannot be stored directly as attributes.

You can provide a third argument containing initial values. These values apply only when the corresponding attribute does not already exist, and they must match the schema's type.

```luau
local data = AttributeSync.new(
    part,
    { Owner = "" },
    { Owner = player.Name }
)
```

Attribute names must be alphanumeric or underscores, fewer than 100 characters, and must not start with `RBX`.

## Fields: constraints on a key

Use `AttributeSync.field(default, options)` to add validation rules while retaining the default's inferred type.

| Option | Applies to | Behavior |
| --- | --- | --- |
| `min` | Numbers | Clamps values below the minimum. |
| `max` | Numbers | Clamps values above the maximum. |
| `oneOf` | Any supported type | Accepts only values included in the allowed list. |
| `validate` | Any supported type | Calls a function that must return `true` to accept the value. |

```luau
local data = AttributeSync.new(npc, {
    Health = AttributeSync.field(100, { min = 0, max = 100 }),

    State = AttributeSync.field("Idle", {
        oneOf = { "Idle", "Chasing", "Dead" },
    }),

    Level = AttributeSync.field(1, {
        validate = function(level: number)
            return level % 1 == 0
        end,
    }),
})

data.Health = 150       -- Stored as 100.
data.Health = -20       -- Stored as 0.
data.State = "Flying"   -- Errors; value is unchanged.
data.Level = 1.5        -- Errors; validation fails.
```

The default must satisfy its own constraints. For example, a default of `500` with `max = 10` is invalid and causes registration to fail.

## Reading, writing, and sharing

Wrappers behave like tables:

```luau
print(data.Health)
data.Health += 10
data.Enraged = true
```

Reads access the underlying attribute. Writes pass through the wrapper's validation and constraint handling before being stored.

If an attribute is removed externally, a subsequent wrapper read returns the schema default instead of `nil`.

```luau
boss:SetAttribute("Health", nil)

print(data.Health) -- Schema default, if the attribute is missing.
```

**Important:** Values written directly through `Instance:SetAttribute()` are not validated by AttributeSync. An external script can write a value of the wrong type, and a wrapper read can return that invalid value. Use the wrapper consistently when validation is required.

### Shared wrapper behavior

Calls to `AttributeSync.new` for the same Instance reuse the registered wrapper while it remains available. Additional schema keys can be merged into it. Existing registered keys retain their original registration and are not overridden by later defaults.

```luau
-- Script A
local dataA = AttributeSync.new(workspace.Boss, {
    Health = 500,
    Enraged = false,
})

dataA.Health -= 25

-- Script B
local dataB = AttributeSync.new(workspace.Boss, {
    Health = 999,
    Phase = 1,
})

print(dataB.Health) -- 475; the registered Health schema is retained.
print(dataB.Phase)  -- 1
```

Keep a reference to the wrapper while you need it. If it becomes unreachable, it may be garbage-collected. A subsequent `new` call can construct another wrapper from the Instance's current attributes.

## Reacting to changes

### Observe

`Observe(wrapper, key, callback)` immediately invokes the callback with the current value and `nil` as the previous value. It then invokes the callback for subsequent observed changes with `(new, old)`.

```luau
local connection = AttributeSync.Observe(
    data,
    "Health",
    function(new, old)
        if old == nil then
            print("Starting health:", new)
        else
            print(`Health {old} -> {new}`)
        end

        if new <= 0 then
            data.State = "Dead"
        end
    end
)

-- Disconnect when no longer needed.
connection:Disconnect()
```

The callback should be a function. Validate callback arguments before registering observers if your code accepts untrusted inputs.

### GetChangedSignal

`GetChangedSignal(wrapper, key)` returns the Instance's attribute-changed signal for that schema key.

```luau
AttributeSync.GetChangedSignal(data, "Enraged"):Connect(function()
    print("Enraged is now", data.Enraged)
end)
```

Unlike `Observe`, this signal does not provide the old and new values as callback arguments. It can fire for changes made outside AttributeSync, including writes that bypass wrapper validation.

Connections are created only when requested. Disconnect connections when they are no longer needed.

## Bulk operations and tag binding

### Update

`Update` validates all supplied values before applying any writes. If validation fails, no fields from that update are applied.

```luau
AttributeSync.Update(data, {
    Health = 250,
    State = "Chasing",
})
```

### Reset

Restore one field or all registered fields to their defaults.

```luau
AttributeSync.Reset(data, "Health")
AttributeSync.Reset(data)
```

### ToTable and FromTable

`ToTable` produces a plain-table snapshot. `FromTable` restores values using validation equivalent to `Update`.

```luau
local snapshot = AttributeSync.ToTable(data)

-- Change state...

AttributeSync.FromTable(data, snapshot)
```

Use these functions when preparing data for a DataStore or another serialization mechanism. Ensure the values are supported by the destination and that any required serialization limits are respected.

**Snapshot behavior:** Diagnostic testing found that `ToTable` can include extra raw attributes beyond the registered schema. If your application requires strictly schema-only snapshots, verify or enforce that behavior before relying on the snapshot as a schema-filtered representation.

### BindTag

`BindTag` wraps Instances carrying a CollectionService tag, including existing Instances and Instances tagged later.

```luau
local unbind = AttributeSync.BindTag(
    "Enemy",
    {
        Health = AttributeSync.field(100, {
            min = 0,
            max = 100,
        }),
        State = "Idle",
    },
    function(wrapper, instance)
        print(instance.Name, "is ready with", wrapper.Health, "health")
    end
)

-- Stop binding newly discovered tagged Instances.
unbind()
```

The callback is optional and runs when an Instance is bound. Unbinding stops future binding; it does not automatically undo the attributes or schema already applied to existing wrappers.

## Errors, edge cases, and best practices

| Situation | Expected behavior or diagnostic finding |
| --- | --- |
| Read or write an unknown wrapper key | Errors because the key is not in the schema. |
| Write a value of the wrong type through the wrapper | Errors without changing the value. |
| Write `NaN` | Rejected. |
| Write a value outside `min` or `max` | Clamped to the allowed range. |
| Write an invalid `oneOf` value | Rejected. |
| Fail custom validation | Rejected; the stored value remains unchanged. |
| Use a `nil` default | Rejected. |
| Register an invalid default | Registration fails before invalid initialization is applied. |
| Submit a mixed valid/invalid `Update` | Validation fails before any supplied field is applied. |
| Remove an attribute externally | Wrapper reads return the schema default. |
| Write an invalid value directly with `SetAttribute` | The wrapper does not revalidate it on read. |
| Supply an invalid `Observe` callback | Diagnostic testing found that registration currently succeeds; callers should supply a valid function. |
| Change the schema table after registration | Diagnostic testing found that later registration can extend the schema; avoid mutating schema definitions unless this behavior is intentional. |

### Good habits

- Define schemas centrally and reuse them.
- Cache wrappers in local variables instead of repeatedly calling `new` in hot loops.
- Prefer wrapper writes wherever validation matters.
- Disconnect observer connections when finished.
- Use `pcall` around operations where failure is expected, such as handling untrusted input. Avoid hiding unexpected programming errors.
- Keep snapshots and saved data within the supported serialization format.
- Treat benchmark results as measurements of a particular runtime, not guaranteed production performance.

## Compiler directives

The module currently uses:

```luau
--!native
--!optimize 2
```

These directives request native code generation and level-2 optimization. They are intended to improve execution where supported, but their presence alone does not guarantee faster performance.

Benchmark the module with the directives enabled and disabled under the same conditions before attributing a speed difference to them. Roblox API calls, validation work, observer callbacks, runtime state, and garbage collection can all affect results.

## Benchmarks

The following measurements come from the latest diagnostic run. Times are median elapsed milliseconds for the indicated workload; lower is faster.

**Latest run**

| Operation | Workload | Median |
| --- | --- | ---: |
| Cached `new()` | 20,000 calls × 3 | 26.54 ms |
| Raw `SetAttribute` | 50,000 writes × 3 | 81.39 ms |
| Wrapper plain-number write | Benchmark workload | 100.73 ms |
| Wrapper clamped-number write | Benchmark workload | 82.20 ms |
| Wrapper `oneOf` string write | Benchmark workload | 99.47 ms |
| Wrapper boolean write | Benchmark workload | 86.43 ms |
| Wrapper write with validator callback | Benchmark workload | 97.93 ms |
| Wrapper read | 100,000 reads | 34.56 ms |
| Raw `GetAttribute` | 100,000 reads | 16.53 ms |
| Changed writes | 10,000 writes | 26.73 ms |
| Same-value writes | 10,000 writes | 7.83 ms |

The write benchmarks use different operation paths, so do not treat them as perfectly interchangeable comparisons. The wrapper adds schema and validation behavior that raw attribute operations do not provide.

### Previous run comparison

| Benchmark | Previous median | Latest median | Change |
| --- | ---: | ---: | ---: |
| Cached `new()` | 23.14 ms | 26.54 ms | +14.7% |
| Raw `SetAttribute` | 71.74 ms | 81.39 ms | +13.5% |
| Plain-number write | 87.11 ms | 100.73 ms | +15.6% |
| Clamped-number write | 69.69 ms | 82.20 ms | +18.0% |
| `oneOf` string write | 84.35 ms | 99.47 ms | +17.9% |
| Boolean write | 82.71 ms | 86.43 ms | +4.5% |
| Validator callback write | 92.36 ms | 97.93 ms | +6.0% |
| Wrapper read | 23.97 ms | 34.56 ms | +44.2% |
| Raw `GetAttribute` | 15.57 ms | 16.53 ms | +6.2% |

The latest measurements were slower across these listed operations. This does **not** establish that `--!native` or `--!optimize 2` caused the slowdown: the runs were not a controlled, repeated A/B experiment.

For meaningful comparisons:

1. Run both versions in the same Roblox environment.
2. Alternate the versions across multiple runs.
3. Keep the workload, iteration counts, and test data identical.
4. Compare medians rather than a single measurement.
5. Test each directive independently and then test both together.
6. Keep correctness assertions enabled while benchmarking.

### Same-value write optimization

The latest run measured 10,000 same-value writes at **7.83 ms**, compared with **26.73 ms** for changed writes. Same-value writes were approximately **3.42 times faster** in that workload.

This is consistent with avoiding unnecessary work when a value has not changed. Actual results depend on the workload and runtime.

## Memory diagnostics

The latest diagnostic run reported the following Lua heap measurements:

| Checkpoint | Lua heap |
| --- | ---: |
| Start | 433 KB |
| Before scale creation | 681 KB |
| After scale creation | 13,599 KB |
| After destroying 1,000 Instances and garbage collection | 5,439 KB |
| Final cleanup and garbage collection | 3,034 KB |

The heap dropped substantially after cleanup, but the remaining heap is not by itself proof of a memory leak. Garbage collection timing, other retained objects, and runtime activity can affect these measurements. Engine memory measurements were also variable during the run.

A separate churn probe reported 250/250 weak wrapper references remaining in each round. That result is inconclusive without verifying that the test itself does not retain strong references and allowing garbage collection to run under controlled conditions.

To investigate memory retention, use repeated creation/destruction cycles, remove all intentional references, force garbage collection where the test environment permits it, and inspect whether memory consistently grows across comparable cycles.

## Testing

The diagnostic harness exercises registration, reads and writes, validation, wrapper sharing, signals, clamping, snapshots, tag binding, serialization-compatible types, and cleanup behavior.

The latest reported run completed with:

- **19 sections**
- **180 assertions passed**
- **0 assertion failures**
- **0 section crashes**
- 23 exploratory probes
- 11 benchmarks
- 55.43 seconds total runtime

Passing assertions demonstrate that the tested expectations passed; they do not prove the absence of every bug or memory leak. Exploratory probes can also reveal behaviors that deserve separate decisions or additional tests.

### Running the tests

1. Place the module at `ReplicatedStorage.Shared.Packages.AttributeSync`.
2. Place the diagnostic script in `ServerScriptService` as a regular `Script`.
3. Run the experience in Studio.
4. Review the Output window for failures, diagnostic findings, benchmark results, and the final summary.

Use a consistent Studio setup for comparisons. Avoid running unrelated workloads during benchmark measurements.

## Things to know

- Server-side attribute changes replicate to clients. Client-side changes do not replicate back to the server.
- Static typing depends on Luau being able to infer the schema and wrapper type. Casting to `any` removes those compile-time guarantees.
- Runtime wrapper validation applies to writes made through AttributeSync, not arbitrary external `SetAttribute` calls.
- Attributes cannot directly store Instances, tables, or functions.
- Weak references make unused wrappers eligible for collection; they do not guarantee immediate collection or prove that the entire application is leak-free.
- Compiler directives can affect execution performance, but benchmark results must be measured on the target workload.

## API reference

| Function | Returns | Description |
| --- | --- | --- |
| `AttributeSync.new(instance, defaults, initial?)` | Typed wrapper | Creates or reuses a wrapper and merges additional schema keys. |
| `AttributeSync.field(default, options?)` | Default's type | Adds validation or clamping rules. |
| `AttributeSync.Observe(wrapper, key, callback)` | Connection | Calls the callback immediately, then on observed changes. |
| `AttributeSync.GetChangedSignal(wrapper, key)` | Signal | Returns the Instance's attribute-changed signal for a schema key. |
| `AttributeSync.Update(wrapper, values)` | Nothing | Validates a group of values before applying writes. |
| `AttributeSync.Reset(wrapper, key?)` | Nothing | Restores one key or all keys to their defaults. |
| `AttributeSync.ToTable(wrapper)` | Table | Creates a snapshot of attribute values. |
| `AttributeSync.FromTable(wrapper, snapshot)` | Nothing | Restores values through validation. |
| `AttributeSync.BindTag(tag, defaults, onBound?)` | Function | Binds tagged Instances and returns an unbind function. |
| `AttributeSync.GetInstance(wrapper)` | Instance | Returns the Instance associated with a wrapper. |

---

*Benchmark figures are from one diagnostic run and are provided for transparency, not as performance guarantees.*
