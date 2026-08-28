# Execution, concurrency, and backpressure

## Current model

Every loaded plugin owns an independent Lua 5.4 state. A state is thread-affine:
all entrypoint execution, lifecycle functions, API calls, event handlers,
timers, and Flutter callback invocations for that state are serialized on the
Dart isolate that created it. Two callbacks never execute concurrently against
the same state.

In the current prototype that owning isolate is normally the Flutter host
isolate. Lua execution is therefore not yet offloaded to a dedicated plugin
isolate. Instruction and wall-clock hooks bound each protected Lua call, but a
call still occupies its owning isolate until it returns or a hook interrupts
it. Keep handlers short and never use Lua for blocking I/O.

The host API dispatcher is synchronous because a Lua C function must put its
results on the Lua stack before returning. A future asynchronous API must
return a serializable handle immediately and deliver completion later through
an event or callback; it must not retain the raw Lua stack across an `await`.

## Native FFI callback rule

The C wrapper invokes Dart only as a synchronous consequence of Dart entering
that same Lua state. It does not invoke Dart callbacks from a native worker
thread. A real CAN or vehicle provider must marshal an external-thread event
onto the state's owning Dart isolate, then enter Lua through the runtime's
serialized scheduler.

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

The next isolation step is a dedicated long-lived Dart isolate (or an isolate
pool) that owns all Lua FFI objects. Communication with Flutter should use only
sendable structured messages and generation IDs. This prevents Lua work from
occupying the UI isolate, but an isolate still shares the process and does not
contain a native crash.

For untrusted third-party plugins, the stronger target is a separate restricted
process with IPC, OS credentials, seccomp/namespace policy as available,
read-only plugin files, explicit resource limits, and a watchdog. The UI DSL,
structured-value codec, namespaced APIs, and callback IDs are deliberately
suited to either isolate messages or process IPC.

Before production deployment, add load and soak tests around execution-budget
interrupts, queue overflow, reload while events are arriving, callback teardown,
and provider-thread marshaling on the target embedder and CPU architecture.

