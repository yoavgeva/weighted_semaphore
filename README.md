# WeightedSemaphore

A weighted semaphore for Elixir — bound concurrent access to a shared resource where different operations can cost different amounts.

Ported from Go's [`x/sync/semaphore`](https://pkg.go.dev/golang.org/x/sync/semaphore) with an Elixir-idiomatic API that auto-releases permits (no manual release, no leaks).

## Installation

Add `weighted_semaphore` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:weighted_semaphore, "~> 0.1.0"}
  ]
end
```

## Quick start

```elixir
# 1. Add to your supervision tree
children = [
  {WeightedSemaphore, name: MyApp.Sem, max: 10}
]
Supervisor.start_link(children, strategy: :one_for_one)

# 2. Acquire permits, run work, auto-release
{:ok, user} = WeightedSemaphore.acquire(MyApp.Sem, fn ->
  Repo.get!(User, 123)
end)
```

## Usage

### Basic acquire (weight 1)

```elixir
{:ok, result} = WeightedSemaphore.acquire(MyApp.Sem, fn ->
  do_work()
end)
```

### Weighted acquire

Different operations can cost different amounts of permits:

```elixir
# Light operation — 1 permit
{:ok, user} = WeightedSemaphore.acquire(MyApp.Sem, 1, fn ->
  Repo.get(User, id)
end)

# Heavy operation — 5 permits
{:ok, count} = WeightedSemaphore.acquire(MyApp.Sem, 5, fn ->
  Repo.insert_all(Event, large_batch)
end)
```

### Timeout

Give up if permits aren't available within a deadline:

```elixir
case WeightedSemaphore.acquire(MyApp.Sem, 5, fn -> slow_work() end, 5_000) do
  {:ok, result} ->
    handle_result(result)

  {:error, :timeout} ->
    Logger.warning("Semaphore timeout — system under load")
    {:error, :overloaded}
end
```

### Non-blocking try

Skip work entirely if the system is busy — useful for best-effort operations:

```elixir
case WeightedSemaphore.try_acquire(MyApp.Sem, fn -> quick_check() end) do
  {:ok, result} -> use_result(result)
  :rejected -> serve_cached_response()
end

# With weight
case WeightedSemaphore.try_acquire(MyApp.Sem, 5, fn -> process_batch(items) end) do
  {:ok, result} -> {:processed, result}
  :rejected -> {:queued_for_later, items}
end
```

### Error handling

If your function raises, exits, or throws, the permits are still released and the error is returned to the caller — no permit leaks:

```elixir
# raise → {:error, {exception, stacktrace}}
{:error, {%RuntimeError{message: "boom"}, _stacktrace}} =
  WeightedSemaphore.acquire(MyApp.Sem, fn -> raise "boom" end)

# exit → {:error, reason}
{:error, :something_went_wrong} =
  WeightedSemaphore.acquire(MyApp.Sem, fn -> exit(:something_went_wrong) end)
```

The next queued caller proceeds immediately after the error — no permits are leaked.

## Return values

| Function | Success | No capacity | Timeout | fn crashes | Weight > max |
|---|---|---|---|---|---|
| `acquire/2,3` | `{:ok, result}` | blocks | — | `{:error, reason}` | `{:error, :weight_exceeds_max}` |
| `acquire/4` | `{:ok, result}` | blocks | `{:error, :timeout}` | `{:error, reason}` | `{:error, :weight_exceeds_max}` |
| `try_acquire/2,3` | `{:ok, result}` | `:rejected` | — | `{:error, reason}` | `{:error, :weight_exceeds_max}` |

## Real-world examples

### Database query throttling

Limit concurrent queries where heavier queries cost more:

```elixir
# In your application supervisor
{WeightedSemaphore, name: MyApp.DbSem, max: 20}

# Simple read — 1 permit
{:ok, user} = WeightedSemaphore.acquire(MyApp.DbSem, fn ->
  Repo.get(User, id)
end)

# Bulk insert — 5 permits (heavier on DB)
{:ok, {count, _}} = WeightedSemaphore.acquire(MyApp.DbSem, 5, fn ->
  Repo.insert_all(Event, large_batch)
end)

# Full table scan — 10 permits (very heavy)
{:ok, stats} = WeightedSemaphore.acquire(MyApp.DbSem, 10, fn ->
  Repo.aggregate(Event, :count)
end)
```

### External API rate limiting

Bound concurrent outgoing HTTP calls:

```elixir
{WeightedSemaphore, name: MyApp.ApiSem, max: 10}

# Each API call takes 1 permit — at most 10 concurrent
{:ok, response} = WeightedSemaphore.acquire(MyApp.ApiSem, fn ->
  Req.get!("https://api.example.com/users/#{id}")
end)

# Batch endpoint costs more — takes 3 permits
{:ok, response} = WeightedSemaphore.acquire(MyApp.ApiSem, 3, fn ->
  Req.post!("https://api.example.com/users/batch", json: user_ids)
end)
```

### Media processing pipeline

Limit concurrent processing by resource cost:

```elixir
{WeightedSemaphore, name: MyApp.MediaSem, max: 100}

# Thumbnail generation — lightweight (1 permit)
{:ok, thumb} = WeightedSemaphore.acquire(MyApp.MediaSem, 1, fn ->
  Image.thumbnail(upload.path, 200)
end)

# Image resize — moderate (5 permits)
{:ok, resized} = WeightedSemaphore.acquire(MyApp.MediaSem, 5, fn ->
  Image.resize(upload.path, 1920, 1080)
end)

# Video transcode — heavy (30 permits)
{:ok, output} = WeightedSemaphore.acquire(MyApp.MediaSem, 30, fn ->
  FFmpeg.transcode(video.path, format: :mp4, preset: :slow)
end)
```

### Graceful degradation with try_acquire

Serve degraded responses when the system is overloaded:

```elixir
{WeightedSemaphore, name: MyApp.RenderSem, max: 50}

def render_dashboard(user) do
  case WeightedSemaphore.try_acquire(MyApp.RenderSem, 10, fn ->
    build_full_dashboard(user)
  end) do
    {:ok, dashboard} ->
      {:ok, dashboard}

    :rejected ->
      # Fall back to a lightweight cached version
      {:ok, cached_dashboard(user)}
  end
end
```

## How it works

1. You call `acquire/2` — the GenServer checks if enough permits are free
2. **Capacity available**: your function runs in a spawned process, caller blocks until it returns
3. **No capacity**: your caller is queued (FIFO) and blocks until permits free up
4. When the function finishes (success or crash), permits are released and the next queued caller is woken up

The function runs in a separate monitored process (not linked). If it crashes, the GenServer catches the `:DOWN` message, releases permits, and returns the error to the caller. The GenServer itself never crashes due to user function errors.

## Fairness

Waiters are served in strict FIFO order. When a large waiter is at the front of the queue but not enough permits are available, smaller waiters behind it also block — even if they would fit. This prevents starvation of large requests.

**Example**: with `max: 10` and 5 permits free — if a weight-8 request is first in queue, a weight-1 request behind it will also wait. Once enough permits free up, the weight-8 request runs, then the weight-1 follows.

This is the same algorithm Go's `x/sync/semaphore` uses.

## License

MIT — see [LICENSE](LICENSE).
