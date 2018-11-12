defmodule Firenest.ReplicatedState.Remote do
  defstruct pending: %{}, clocks: %{}, clock: 0, tag: nil, deltas: %{}

  # TODO: some protocol for requesting more of a state, even from other nodes
  # on first up, so we don't need to go to each node separately.

  def new(:ignore) do
    %__MODULE__{tag: :ignore}
  end

  def clock(%__MODULE__{clock: clock}), do: clock

  # Reconnections are dead until we have permdown
  def up(%__MODULE__{clocks: clocks} = state, ref, clock) do
    case clocks do
      # Reconnection, try to catch up
      %{^ref => old_clock} when clock > old_clock ->
        {:catch_up, {clock, old_clock}, state}

      # Reconnection, no remote changes
      %{^ref => old_clock} ->
        # Assert for sanity
        true = old_clock == clock
        {:ok, state}

      # New node, no state
      %{} when clock == 0 ->
        {:ok, %{state | clocks: Map.put(clocks, ref, clock)}}

      # New node, catch up
      %{} ->
        {:catch_up, {clock, 0}, state}
    end
  end

  # TODO: Right now down means permdown
  def down(state, ref) do
    permdown(state, ref)
  end

  def permdown(%__MODULE__{clocks: clocks} = state, ref) do
    true = Map.has_key?(clocks, ref)
    clocks = Map.delete(clocks, ref)
    {:delete, ref, %{state | clocks: clocks}}
  end

  def catch_up(%__MODULE__{clock: current} = state, {clock, old_clock}, state_getter)
      when old_clock < clock and clock <= current do
    %{deltas: deltas, tag: tag} = state

    if Map.has_key?(deltas, old_clock) do
      {:deltas, tag, current, Enum.flat_map(old_clock..current, &Map.fetch!(deltas, &1))}
    else
      {:state_transfer, tag, current, state_getter.()}
    end
  end

  def broadcast(%__MODULE__{pending: pending, clock: clock, tag: tag} = state, prepare_delta) do
    deltas = prepare_deltas(tag, pending, prepare_delta)
    new_state = %{state | pending: %{}, clock: clock + 1}
    {{tag, clock, deltas}, new_state}
  end

  def handle_catch_up(%__MODULE__{tag: tag} = state, ref, {:deltas, tag, clock, deltas}) do
    %{clocks: clocks} = state

    state = %{state | clocks: %{clocks | ref => clock}}
    {puts, updates, deletes} = handle_deltas(tag, deltas)
    {:diff, puts, updates, deletes, state}
  end

  def handle_catch_up(%__MODULE__{tag: tag} = state, from, {:state_transfer, tag, clock, data}) do
    %{clocks: clocks} = state

    case tag do
      :ignore -> {:insert, data, %{state | clocks: %{clocks | from => clock}}}
    end
  end

  # TODO: should we store somewhere we're catching up with the server?
  # if so, then we should accumulate the broadcasts we can't handle, until we can.
  def handle_broadcast(%__MODULE__{clocks: clocks, tag: tag} = state, ref, {tag, clock, delta}) do
    case clocks do
      %{^ref => old_clock} when old_clock + 1 == clock ->
        state = %{state | clocks: %{clocks | ref => clock}}
        {puts, updates, deletes} = handle_deltas(tag, [delta])
        {:diff, puts, updates, deletes, state}

      # We missed some broadcast, catch up with the node
      %{^ref => old_clock} when clock > old_clock ->
        {:catch_up, {clock, old_clock}, state}

      # We were caught up with a newer clock than the current, ignore
      # TODO: is that even possible?
      %{^ref => old_clock} when clock < old_clock ->
        {:ok, state}
    end
  end

  def handle_broadcast(%__MODULE__{tag: local_tag}, ref, {remote_tag, _, _}) do
    {:error, {:different_tag, ref, local_tag, remote_tag}}
  end

  defp handle_deltas(:ignore, deltas) do
    handler = &handle_ignore_delta/4
    handle_deltas(deltas, [], [], [], handler)
  end

  defp handle_deltas([delta], inserts, updates, deletes, handler) do
    handler.(delta, inserts, updates, deletes)
  end

  defp handle_deltas([delta | rest], inserts, updates, deletes, handler) do
    {inserts, updates, deletes} = handler.(delta, inserts, updates, deletes)
    handle_deltas(rest, inserts, updates, deletes, handler)
  end

  def local_put(state, key, pid, value) do
    event(state, key, pid, {:put, value})
  end

  def local_delete(state, key, pid) do
    event(state, key, pid, :delete)
  end

  def local_update(state, key, pid, value, delta) do
    event(state, key, pid, {:update, value, delta})
  end

  defp event(%__MODULE__{pending: pending, tag: tag} = state, key, pid, event) do
    pending =
      case tag do
        :ignore -> event_ignore(pending, key, pid, event)
      end

    %{state | pending: pending}
  end

  defp event_ignore(pending, key, pid, {:put, value}) do
    Map.put(pending, {key, pid}, {:put, value})
  end

  defp event_ignore(pending, key, pid, :delete) do
    pending_key = {key, pid}

    case pending do
      %{^pending_key => {:put, _}} -> Map.delete(pending, pending_key)
      %{} -> Map.put(pending, pending_key, :delete)
    end
  end

  defp event_ignore(pending, key, pid, {:update, value, delta}) do
    pending_key = {key, pid}

    case pending do
      %{^pending_key => {:put, _}} -> %{pending | pending_key => {:put, value}}
      %{} -> Map.put(pending, pending_key, {:update, delta})
    end
  end

  defp prepare_deltas(:ignore, pending, prepare) do
    prepare_ignore_deltas(pending, [], [], [], prepare)
  end

  defp prepare_ignore_deltas([], puts, updates, deletes, _prepare) do
    {puts, updates, deletes}
  end

  defp prepare_ignore_deltas([{key, {:put, value}} | rest], puts, updates, deletes, prepare) do
    prepare_ignore_deltas(rest, [{key, value} | puts], updates, deletes, prepare)
  end

  defp prepare_ignore_deltas([{key, {:update, delta}} | rest], puts, deletes, updates, prepare) do
    delta = prepare.(delta)
    prepare_ignore_deltas(rest, puts, [{key, delta} | updates], deletes, prepare)
  end

  defp prepare_ignore_deltas([{key, :delete} | rest], puts, deletes, updates, prepare) do
    prepare_ignore_deltas(rest, puts, updates, [key | deletes], prepare)
  end

  defp handle_ignore_delta({delta_puts, delta_updates, delta_deletes}, puts, updates, deletes) do
    {delta_puts ++ puts, delta_updates ++ updates, delta_deletes ++ deletes}
  end
end