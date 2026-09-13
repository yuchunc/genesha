defmodule Ganesha.Assistant.Provider.Mock do
  @moduledoc """
  Test-only `Ganesha.Assistant.Provider`. `Ganesha.Assistant.Agent` calls
  `complete/3` synchronously in the calling process (Oban's `perform_job/2`
  runs a worker's `perform/1` directly in the test process, same as
  `Ganesha.Reporting.CloseMonthWorkerTest`), so a process-dictionary stub is
  enough — no cross-process mocking needed.
  """
  @behaviour Ganesha.Assistant.Provider

  def stub(fun) when is_function(fun, 3), do: Process.put(:assistant_provider_mock_stub, fun)

  @impl true
  def complete(messages, tools, opts) do
    case Process.get(:assistant_provider_mock_stub) do
      nil -> raise "Ganesha.Assistant.Provider.Mock.stub/1 was not called before complete/3"
      fun -> fun.(messages, tools, opts)
    end
  end
end
