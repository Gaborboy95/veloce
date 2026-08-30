# Execution, concurrency, and backpressure

## Current model

The demo uses `IsolatedNativeLuaRuntimeFactory`: every loaded generation owns a
dedicated Dart isolate and an independent Lua 5.4 state. All entrypoint,
lifecycle, event, timer, and Flutter callback execution for that state is
serialized by its runtime. Two callbacks never execute concurrently against
one Lua state, while different plugins can run independently.

```text
Flutter UI isolate
       │
       ├──── Plugin A isolate ─── Lua state A
       ├──── Plugin B isolate ─── Lua state B
       └──── Plugin C isolate ─── Lua state C
                │
                ▼
        structured messages
```

An infinite Lua loop therefore occupies only that plugin isolate until the
native instruction/deadline hook interrupts it; it does not occupy the Flutter
UI isolate. `NativeLuaRuntimeFactory` remains available as a direct-isolate
implementation for tests or tightly controlled hosts, but third-party plugins
should use the isolated factory.

The host API dispatcher is synchronous because a Lua C function must put its
results on the Lua stack before returning. The plugin isolate sends a structured
request to the host and blocks its own native thread on a small process-local C
rendezvous. The Flutter isolate performs capability/generation checks and
signals the serialized response. It never waits for the plugin isolate. A
genuinely asynchronous host API must still return a serializable handle and
deliver completion later through an event or callback; it must not retain the
raw Lua stack across an `await`.

## Native FFI callback rule

Each plugin isolate constructs its own `NativeCallable.isolateLocal`. The C
wrapper invokes that callback only as a synchronous consequence of the same
isolate/thread entering its Lua state. The callback is closed before the
isolate exits. No isolate calls another isolate's native callback, and no raw
Lua or rendezvous pointer is exposed to Lua or the public core API.

A CAN or vehicle provider delivers a Dart callback identity to the manager.
The manager sends callback invocation data to the owning plugin isolate; it
does not enter the Lua state from a provider/native thread.

Never share a raw Lua state pointer, native callback pointer, Dart object, or
callback closure between isolates. The public core abstraction intentionally
uses manifests, callback IDs, and structured values rather than C pointers.

## Queue policy

Different data classes have different loss semantics:

| Source | Queue behavior | Why |
| --- | --- | --- |
| General events | Bounded FIFO per subscription; configured overflow drops oldest or newest | Events may be ordered, but cannot grow memory without bound. |
| Vehicle values | One pending slot per subscriber; a newer value replaces the pending value | Vehicle signals represent current state. |
| In-memory CAN | Provider-side filter, then bounded FIFO per matching subscription | Nonmatching raw frames never schedule Lua. |
| Timers | Plugin-owned and bounded; one interval callback is not overlapped | Prevents timer fan-out and reentrant state access. |
| Logs | Bounded retained history plus a broadcast stream | Developer UI has predictable memory use. |
| UI | Registry emits only on extension changes | A raw CAN frame does not directly rebuild Flutter UI. |

Handlers are isolated: their exceptions are reported without escaping back
through the event publisher or CAN injector. Dropped/coalesced counts are
available from the relevant core APIs for observability.

## Safe shutdown order

For a runtime generation, stop accepting new work before releasing native
state:

1. Mark the generation inactive and stop routing new invocations to it.
2. Cancel timers and remove event, vehicle, and CAN subscriptions.
3. Remove UI/extension registrations so Flutter stops presenting callbacks.
4. Invalidate the callback registry and wait for in-flight callbacks.
5. Call lifecycle teardown within its execution budget where applicable.
6. Destroy the Lua state.

Generation-bearing callback references make stale Flutter elements fail closed
instead of entering a replacement or destroyed state.

## Hot reload concurrency

The candidate and current generations have different Lua states and callback
generations. Candidate resources stay staged until its entrypoint,
initialization, and UI values validate. Commit publishes the complete new
resource set as one owner replacement. Only then is the old generation drained
and destroyed. A failed candidate is disposed without changing the routing
target.

Events arriving during a commit are serialized with that commit. Hosts that
connect high-rate native sources should pause or buffer at the provider boundary
with an explicit finite policy; they must not call both generations.

## Hardening path

The dedicated-isolate step is implemented. Isolates protect Flutter scheduling
and separate plugin queues, but still share one address space and do not contain
a native crash or enforce an OS memory/CPU quota.

For untrusted third-party plugins, the stronger target is a separate restricted
process with IPC, OS credentials, seccomp/namespace policy as available,
read-only plugin files, explicit resource limits, and a watchdog. The UI DSL,
structured-value codec, namespaced APIs, and callback IDs are deliberately
suited to either isolate messages or process IPC.

Before production deployment, add load and soak tests around execution-budget
interrupts, queue overflow, reload while events are arriving, callback teardown,
and provider-thread marshaling on the target embedder and CPU architecture.
