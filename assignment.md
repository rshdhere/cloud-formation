
# Take-Home Assignment: Pi Agent With Kubernetes-Leased Sandbox Execution

## Overview

Build a TypeScript backend service that runs a chat agent using the Pi TypeScript SDK. The agent can respond normally, but whenever it needs to execute a tool, that tool must run inside a Kubernetes sandbox pod.

The service owns a fixed pool of 8 warm sandbox pods. Pods are not permanently assigned to users or sessions. Instead, a pod is leased just in time for a tool call, locked while the tool runs, and released immediately after the tool finishes, fails, or times out.

This assignment is meant to evaluate your ability to design a small but correct distributed runtime: Kubernetes coordination, concurrency, queueing, failure cleanup, observability, and TypeScript code organization.

## Time Expectation

Spend roughly 8 to 12 focused hours. A correct, well-tested core implementation is more important than completing every optional extension.

## What To Build

Build a TypeScript service with:

- A `POST /chat` API.
- A real Pi TypeScript SDK chat or agent loop.
- Tool-call support.
- Tool execution inside Kubernetes sandbox pods.
- A fixed pool of exactly 8 warm sandbox pods.
- Kubernetes `Lease` objects as the source of truth for pod locking.
- FIFO queueing when all pods are busy, with a bounded max wait time.

Use local Kubernetes through `kind`, `minikube`, or Docker Desktop Kubernetes. Do not require a cloud cluster.

## Chat API

Expose:

```http
POST /chat
Content-Type: application/json

{
  "sessionId": "session-123",
  "message": "list the files in the sandbox"
}
```

The response can be non-streaming:

```json
{
  "sessionId": "session-123",
  "message": "The sandbox contains package.json and src/.",
  "toolCalls": [
    {
      "toolCallId": "tool-abc",
      "tool": "shell.run",
      "pod": "sandbox-runner-3",
      "status": "completed"
    }
  ]
}
```

Streaming is optional.

## Pi Integration

Use the real Pi TypeScript SDK for the chat or agent loop.

The submitted service must have a working Pi SDK integration path. Do not replace the app path with a mock client or fake agent loop.

Create a clean abstraction around the SDK so the rest of the code is not tightly coupled to the Pi client:

```ts
interface PiClient {
  runChat(input: ChatInput): Promise<ChatResult>;
}
```

Required:

- `RealPiClient` backed by the Pi TypeScript SDK.
- `.env.example` documenting required Pi credentials and configuration.
- clear startup failure if Pi credentials are missing.
- a README section explaining how to configure and run the Pi-backed path.

Pi credentials will be provided separately. If credentials are not available, ask for them rather than replacing the integration with a mock. A mock-only, offline-only, or fake agent implementation will not satisfy the assignment.

## Required Tools

Implement at least these 3 tools:

### `shell.run`

Runs an allowlisted shell command inside a leased sandbox pod.

Allowed commands can include:

- `pwd`
- `ls`
- `cat`
- `node --version`
- `whoami`

Do not allow arbitrary shell execution.

### `fs.read`

Reads a file from an allowed directory inside the sandbox pod.

Reject:

- path traversal
- absolute paths outside the allowed root
- disallowed file paths

### `env.inspect`

Returns basic runtime information from the pod, including:

- pod name
- namespace
- working directory
- user
- relevant runtime versions

## Kubernetes Requirements

Create exactly 8 warm sandbox pods. Prefer a `StatefulSet` so pod names are stable:

- `sandbox-runner-0`
- `sandbox-runner-1`
- `sandbox-runner-2`
- `sandbox-runner-3`
- `sandbox-runner-4`
- `sandbox-runner-5`
- `sandbox-runner-6`
- `sandbox-runner-7`

Each pod should run a minimal container that supports the required tools.

You may execute commands through Kubernetes `pods/exec`, or run a small HTTP tool-runner process inside each pod and call it from the API service. Either approach is acceptable, but explain the tradeoff in your README.

## Lease Model

Use Kubernetes `coordination.k8s.io/v1` `Lease` objects as the lock source of truth.

Create one Lease per sandbox pod:

- `sandbox-runner-0`
- `sandbox-runner-1`
- `sandbox-runner-2`
- `sandbox-runner-3`
- `sandbox-runner-4`
- `sandbox-runner-5`
- `sandbox-runner-6`
- `sandbox-runner-7`

Before executing a tool call, the service must acquire the Lease for one available pod.

Use Kubernetes optimistic concurrency. Your implementation should handle update conflicts by retrying or choosing another Lease. Do not rely on in-memory locks alone.

Each acquired Lease should record enough ownership information to debug it:

- service instance ID
- request ID
- session ID
- tool call ID

Suggested defaults:

- Max queue wait: `15s`
- Tool execution timeout: `30s`
- Lease TTL: `45s`

The Lease must be released on:

- success
- tool failure
- timeout
- cancellation
- unexpected execution error

If the API service crashes while holding a Lease, a future request must be able to recover the pod after the Lease expires.

Pod annotations may be used for observability, but they must not be the lock source of truth.

## Queueing Requirement

When all 8 sandbox pods are busy, tool calls must enter a bounded FIFO queue.

Required behavior:

1. The queue is process-local for this assignment.
2. The queue is FIFO.
3. Each queued tool call has a max wait time of `15s`.
4. If a pod becomes available before the max wait time, the queued tool call acquires a Lease and runs.
5. If no pod becomes available within `15s`, the tool call fails with a capacity timeout.

Use a clear error shape for capacity timeouts:

```json
{
  "error": {
    "code": "sandbox_capacity_timeout",
    "message": "No sandbox pod became available within 15 seconds."
  }
}
```

In your README, explain why a process-local queue is acceptable for this assignment and what would change for a multi-replica production service.

## Required Endpoints

### `POST /chat`

Runs a chat request and any required tool calls.

Requirements:

- Accept `sessionId` and `message`.
- Generate a request ID.
- Route tool calls through the sandbox lease manager.
- Return the final assistant message and tool-call metadata.

### `GET /pods`

Returns current sandbox pool state.

Example:

```json
{
  "pods": [
    {
      "name": "sandbox-runner-0",
      "ready": true,
      "lease": {
        "status": "free"
      }
    },
    {
      "name": "sandbox-runner-1",
      "ready": true,
      "lease": {
        "status": "leased",
        "holderIdentity": "api-1:req-123:session-abc:tool-xyz",
        "expiresAt": "2026-06-01T12:00:45.000Z"
      }
    }
  ]
}
```

### `GET /health`

Returns basic service health.

Example:

```json
{
  "ok": true,
  "kubernetes": "connected",
  "sandboxPodsReady": 8
}
```

## Kubernetes Manifests

Include manifests for:

- `Namespace`
- `ServiceAccount`
- `Role`
- `RoleBinding`
- `StatefulSet` with 8 sandbox pods
- API service `Deployment`
- API service `Service`

RBAC should be scoped to the namespace. Avoid cluster-wide permissions.

The API service should only request the permissions it needs, such as:

- get/list/watch pods
- create `pods/exec`, if using exec
- get/create/update/patch Lease objects
- optionally get pod logs

## Testing Requirements

Include automated tests for:

1. Acquiring a free pod.
2. Releasing a pod after successful tool execution.
3. Releasing a pod after tool failure.
4. Releasing a pod after timeout.
5. Two concurrent tool calls never acquiring the same pod.
6. More than 8 concurrent tool calls entering the queue.
7. A queued call running when a pod becomes free.
8. A queued call failing after the max wait time.
9. Expired Lease recovery.
10. `/pods` reflecting current Lease state.
11. Real Pi SDK chat path triggering the sandbox tool execution path.

At least one test should create real concurrency pressure, not only sequential acquire/release calls.

Integration tests against local Kubernetes are required. If they are too slow for every test run, split the commands:

```bash
npm test
npm run test:integration
```

The integration test suite must include a Pi-backed smoke test that runs with the provided Pi credentials and exercises the sandbox tool execution path.

## Observability

Use structured logs. Each log line should include useful fields.

Log at least:

- chat request started
- chat request completed
- tool call requested
- queue wait started
- queue wait completed
- queue wait timed out
- Lease acquire attempted
- Lease acquired
- Lease conflict
- Lease released
- tool execution started
- tool execution completed
- tool execution failed
- tool execution timed out

Example:

```json
{
  "level": "info",
  "event": "sandbox.lease.acquired",
  "requestId": "req-123",
  "sessionId": "session-abc",
  "toolCallId": "tool-xyz",
  "pod": "sandbox-runner-3",
  "leaseDurationSeconds": 45
}
```

## Security Requirements

This does not need production-grade security, but it should avoid obvious unsafe behavior.

Required:

- no arbitrary shell command execution
- command allowlist for `shell.run`
- path allowlist for `fs.read`
- namespace-scoped RBAC
- no cluster-admin permissions
- no hostPath mounts
- no privileged containers
- resource limits on sandbox pods
- documented network egress assumptions

## README Requirements

Your README should explain:

1. How to run locally.
2. How to create the local Kubernetes cluster.
3. How to apply manifests.
4. How to run the API service.
5. How to run tests.
6. How to call `/chat` with `curl`.
7. How the Lease model works.
8. How the FIFO queue and max wait time work.
9. How timeouts and cleanup work.
10. How to configure real Pi SDK credentials.
11. What would change in production.

Include at least one example where 9 concurrent tool calls are submitted and the 9th request waits for a pod or times out.

## Production Notes

Include a short section explaining how you would evolve this design for production.

Cover at least:

- why a process-local queue is insufficient for a multi-replica API service
- what distributed queue or scheduler you would use
- how Lease renewal should work for long-running tools
- how API process crashes are handled
- how execution history should be audited
- how pod images should be hardened
- how network isolation should work
- how per-user or per-tenant limits should work
- what metrics and alerts should exist

## Deliverables

Submit only:

- GitHub repository URL.
- Live web URL.

The GitHub repository should contain the source code, Kubernetes manifests, README, tests, `.env.example`, and any setup or production notes needed to review the work.