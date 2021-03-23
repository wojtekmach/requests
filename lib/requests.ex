defmodule Requests.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Finch, name: Requests.Finch}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Requests do
  require Logger

  @vsn Mix.Project.config()[:version]

  @moduledoc """
  Yet another HTTP client.

  ## Features

    * Extensible via request, response, and error middleware

    * Automatic body encoding/decoding (via the `encode_request_body/2` and `decode_response_body/2`
      middleware)

    * Automatic compression/decompression (via the `compress/2` and `decompress/1` middleware)

    * Retries on errors (via the `retry/2` middleware)

    * Request streaming (by setting body as `{:stream, enumerable}`)

  ## Examples

      iex> Requests.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

      iex> Requests.post!("https://httpbin.org/post", {:form, comments: "hello!"}).body["form"]
      %{"comments" => "hello!"}

  ## Credits

    * [Requests](https://requests.readthedocs.io)
    * [Tesla](https://github.com/teamon/tesla)
    * [Finch](https://github.com/keathley/finch) (and [Mint](https://github.com/elixir-mint/mint) & [NimblePool](https://github.com/dashbitco/nimble_pool)!)

  """

  @doc """
  Makes a GET request.

  See `request/4` for possible options.
  """
  def get(url, opts \\ []) do
    request(:get, url, "", opts)
  end

  @doc """
  See `get/2`.
  """
  def get!(url, opts \\ []) do
    case get(url, opts) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes a POST request.

  See `request/4` for possible options.
  """
  def post(url, body, opts \\ []) do
    request(:post, url, body, opts)
  end

  @doc """
  See `post/3`.
  """
  def post!(url, body, opts \\ []) do
    case post(url, body, opts) do
      {:ok, response} -> response
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Makes a HTTP request.

  Returns `{:ok, response}` or `{:error, exception}`.

  Options:

    * `:headers` - list of request headers, defaults to `[]`.

    * `:request_middleware` - list of middleware to run the request through, defaults to using:

      * `normalize_request_headers/1`
      * `default_headers/1`
      * `encode_request_body/2` with `opts`
      * `compress/2` with `opts[:compress]` (if set)

    * `:response_middleware` - list of middleware to run the response through, defaults to using:

      * `retry/2` with `opts` (if `retry: true` or any of the `:retry_*` options are set)
      * `decompress/1`
      * `decode_response_body/2` with `opts`

    * `:error_middleware` - list of middleware to run the error through, defaults to using:

      * `retry/2` with `opts` (if `retry: true` or any of the `:retry_*` options are set)

    * `:finch` - name of the `Finch` pool to use, defaults to `Requests.Finch` that is started
      with the default options. See `Finch.start_link/1` for more information.

    * `:pool_timeout` - the maximum time to wait for a connection, defaults to `5000`. See
      `Finch.request/3` for more information.

    * `:receive_timeout` - the maximum time to wait for a response, defaults to `15000`. See
      `Finch.request/3` for more information.

  ## Middleware

  `Requests` supports request, response, and error middleware.

  A request middleware is any function that accepts and returns a possibly updated `Finch.Request`
  struct. An example is `default_headers/1`.

  A response middleware is any function that accepts and returns a possibly updated
  `Finch.Response` struct. An example is `decompress/1`.

  An error middleware is any function that accepts and returns a possibly updated exception struct.
  An example is `retry/2`.

  A response middleware may also return an `exception` in which case the final return value is
  switched to `{:error, exception}` however no further middleware is run on the exception.
  Similarly, an error middleware may return a `response` in which case the final return value is
  switched to `{:ok, response}` however no further middleware is run on the response.

  Notice that some of the built-in middleware functions take more than one argument. In order to
  use them, you have a couple options:

    - use [capture operator](`Kernel.SpecialForms.&`), for example: `&compress(&1, ["gzip"])`

    - use a `{module, function, args}` tuple, where the first argument (request or response)
      will be automatically prepended, for example: `{Requests, :compress, ["gzip"]}`

  ### Example

      opts = [
        request_middleware: [
          &Requests.default_headers/1,
          &IO.inspect(&1, label: :final_request),
        ],
        response_middleware: [
          {IO, :inspect, [[label: :initial_response]]},
          {Requests, :decode_response_body, []}
        ]
      ]

      Requests.get!("https://httpbin.org/json", opts)
      |> IO.inspect(label: :final_response)

  """
  def request(method, url, body, opts \\ []) when is_binary(url) and is_list(opts) do
    finch = Keyword.get(opts, :finch, Requests.Finch)
    finch_opts = Keyword.take(opts, [:pool_timeout, :receive_timeout])

    request_middleware =
      Keyword.get_lazy(opts, :request_middleware, fn ->
        compress = Keyword.get(opts, :compress, false)

        [
          &Requests.normalize_request_headers/1,
          &Requests.default_headers/1,
          {Requests, :encode_request_body, [opts]}
        ]
        |> append_if(compress, &Requests.compress(&1, compress))
      end)

    retry_opts = Keyword.take(opts, [:retry_max_count, :retry_delay])
    retry? = Keyword.get(opts, :retry, false) or retry_opts != []

    response_middleware =
      Keyword.get_lazy(opts, :response_middleware, fn ->
        [
          &Requests.decompress/1,
          {Requests, :decode_response_body, [opts]}
        ]
        |> prepend_if(retry?, &Requests.retry(&1, retry_opts))
      end)

    error_middleware =
      Keyword.get_lazy(opts, :error_middleware, fn ->
        if retry? do
          [&Requests.retry(&1, retry_opts)]
        else
          []
        end
      end)

    headers = Keyword.get(opts, :headers, [])

    Finch.build(method, url, headers, body)
    |> run_middleware(request_middleware)
    |> do_request(finch, response_middleware, error_middleware, finch_opts)
  end

  defp do_request(request, finch, response_middleware, error_middleware, opts, attempt \\ 0) do
    case Finch.request(request, finch, opts) do
      {:ok, response} ->
        Enum.reduce_while(response_middleware, {:ok, response}, fn item, acc ->
          {_, response_or_error} = acc

          case run(item, response_or_error) do
            %Finch.Response{} = response ->
              {:cont, {:ok, response}}

            exception when is_exception(exception) ->
              {:halt, {:error, exception}}
          end
        end)

      {:error, exception} ->
        Enum.reduce_while(error_middleware, {:error, exception}, fn item, acc ->
          {_, response_or_error} = acc

          case run(item, response_or_error) do
            exception when is_exception(exception) ->
              {:cont, {:error, exception}}

            %Finch.Response{} = response ->
              {:halt, {:ok, response}}
          end
        end)
    end
  catch
    {:__requests_retry__, result, max_count, delay} ->
      retry(
        request,
        finch,
        response_middleware,
        error_middleware,
        result,
        max_count,
        delay,
        opts,
        attempt
      )
  end

  defp run_middleware(struct, middleware) do
    Enum.reduce(middleware, struct, &run/2)
  end

  defp run({mod, fun, args}, acc) do
    apply(mod, fun, [acc | args])
  end

  defp run(fun, acc) do
    fun.(acc)
  end

  ## Request middleware

  @doc """
  Normalizes request headers.

  Turns atom header names into strings, e.g.: `:user_agent` becomes `"user-agent"`.
  Non-atom names are returned as is.
  """
  @doc middleware: :request
  def normalize_request_headers(request) do
    headers =
      for {name, value} <- request.headers do
        if is_atom(name) do
          {name |> Atom.to_string() |> String.replace("_", "-"), value}
        else
          {name, value}
        end
      end

    %{request | headers: headers}
  end

  @doc """
  Adds default request headers.

  Currently these headers are added:

    * `"user-agent"` - `"requests/#{@vsn}"`

    * `"accept-encoding"` - `"gzip"`

  """
  @doc middleware: :request
  def default_headers(request) do
    update_in(request.headers, fn headers ->
      headers
      |> put_new_header("user-agent", "requests/#{@vsn}")
      |> put_new_header("accept-encoding", "gzip")
    end)
  end

  @doc """
  Encodes the request body based on its shape.

  If body is of the following shape, it's encoded and its `content-type` set
  accordingly. Otherwise it's unchanged.

  | Shape                     | Encoder               | Content-Type                          |
  | ------------------------- | ---------------       | ------------------------------------- |
  | `{:form, data}`           | `:form_encoder`       | `"application/x-www-form-urlencoded"` |
  | `{:json, data}`           | `:json_encoder`       | `"application/json"`                  |
  | `{:csv, rows}`            | `:csv_encoder`        | `"text/csv"`                          |
  | `{:csv, {:stream, rows}}` | `:csv_stream_encoder` | `"text/csv"`                          |

  ## Options

    * `:form_encoder` - defaults to [`&URI.encode_query/1`](`URI.encode_query/1`).

    * `:json_encoder` - defaults to [`&Jason.encode_to_iodata!/1`](`Jason.encode_to_iodata!/1`).

    * `:csv_encoder` - defaults to [`&NimbleCSV.RFC4180.dump_to_iodata/1`](`NimbleCSV.RFC4180.dump_to_iodata/1`).

    * `:csv_stream_encoder` - defaults to [`&NimbleCSV.RFC4180.dump_to_stream/1`](`NimbleCSV.RFC4180.dump_to_stream/1`).

  ## Examples

      iex> Requests.post!("https://httpbin.org/post", {:form, comments: "hello!"}).body["form"]
      %{"comments" => "hello!"}

  """
  @doc middleware: :request
  def encode_request_body(request, opts \\ []) do
    case request.body do
      {:form, data} ->
        encode(request, URI.encode_query(data), "application/x-www-form-urlencoded")

      {:json, data} ->
        encoder =
          Keyword.get_lazy(opts, :json_encoder, fn ->
            unless Code.ensure_loaded?(Jason) do
              Logger.error("""
              Could not find jason dependency.

              Please add it to your dependencies:

                  {:jason, "~> 1.0"}

              Or set your own JSON encoder:

                  Requests.post!(url, {:json, data}, json_encoder: &MyEncoder.encode!/1)
              """)

              raise "missing jason dependency"
            end

            &Jason.encode_to_iodata!/1
          end)

        encode(request, encoder.(data), "application/json")

      {:csv, {:stream, data}} ->
        encoder =
          Keyword.get_lazy(opts, :csv_stream_encoder, fn ->
            unless Code.ensure_loaded?(NimbleCSV) do
              Logger.error("""
              Could not find nimble_csv dependency.

              Please add it to your dependencies:

                  {:nimble_csv, "~> 1.0"}

              Or set your own CSV encoder:

                  Requests.post!(url, {:csv, data}, csv_stream_encoder: &MyEncoder.encode!/1)
              """)

              raise "missing nimble_csv dependency"
            end

            &NimbleCSV.RFC4180.dump_to_stream/1
          end)

        encode(request, {:stream, encoder.(data)}, "text/csv")

      {:csv, data} ->
        encoder =
          Keyword.get_lazy(opts, :csv_encoder, fn ->
            unless Code.ensure_loaded?(NimbleCSV) do
              Logger.error("""
              Could not find nimble_csv dependency.

              Please add it to your dependencies:

                  {:nimble_csv, "~> 1.0"}

              Or set your own CSV encoder:

                  Requests.post!(url, {:csv, data}, csv_encoder: &MyEncoder.encode!/1)
              """)

              raise "missing nimble_csv dependency"
            end

            &NimbleCSV.RFC4180.dump_to_iodata/1
          end)

        encode(request, encoder.(data), "text/csv")

      _ ->
        request
    end
  end

  defp encode(request, body, content_type) do
    %{
      request
      | body: body,
        headers: put_new_header(request.headers, "content-type", content_type)
    }
  end

  @doc """
  Compresses the request body with the given `algorithms`.

  Supported algorithms: `:gzip`, `:deflate`, and `:identity`.

  This function also sets the appropriate `content-encoding` header (unless already set.)
  """
  @doc middleware: :request
  def compress(request, algorithms) when is_list(algorithms) do
    request
    |> Map.update!(:body, &compress_body(&1, algorithms))
    |> Map.update!(
      :headers,
      fn headers ->
        put_new_header(
          headers,
          "content-encoding",
          Enum.map_join(algorithms, ",", &Atom.to_string/1)
        )
      end
    )
  end

  defp compress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &compress_with_algorithm/2)
  end

  defp compress_with_algorithm(:gzip, {:stream, body}), do: {:stream, gzip_stream(body)}

  defp compress_with_algorithm(:gzip, body), do: :zlib.gzip(body)

  defp compress_with_algorithm(:deflate, body), do: :zlib.zip(body)

  defp compress_with_algorithm(:identity, body), do: body

  defp compress_with_algorithm(algorithm, _body),
    do: raise("unsupported compression algorithm: #{inspect(algorithm)}")

  ## Response middleware

  @doc """
  Decompresses the response body based on the `content-encoding` header.

  Supported values: `"gzip"`, `"x-gzip"`, `"deflate"`, and `"identity"`.
  """
  @doc middleware: :response
  def decompress(response) do
    compression_algorithms = get_content_encoding_header(response.headers)
    update_in(response.body, &decompress_body(&1, compression_algorithms))
  end

  defp decompress_body(body, algorithms) do
    Enum.reduce(algorithms, body, &decompress_with_algorithm/2)
  end

  defp decompress_with_algorithm(gzip, body) when gzip in ["gzip", "x-gzip"],
    do: :zlib.gunzip(body)

  defp decompress_with_algorithm("deflate", body),
    do: :zlib.unzip(body)

  defp decompress_with_algorithm("identity", body),
    do: body

  defp decompress_with_algorithm(algorithm, _body),
    do: raise("unsupported decompression algorithm: #{inspect(algorithm)}")

  @doc """
  Decodes the response body based on the `content-type` header.

  ## Options

    * `:json_decoder` - if set, used on the `"application/json*"` content type. Defaults to
      [`&Jason.decode/1`](`Jason.decode/1`)

    * `:csv_decoder` - if set, used on the `"text/csv*"` content type. Defaults to
      [`&NimbleCSV.RFC4180.parse_string(&1, skip_headers: false)`](`NimbleCSV.RFC4180.parse_string/2`)

  ## Examples

      iex> Requests.get!("https://httpbin.org/json").body
      %{...}

      iex> Requests.get!("https://httpbin.org/json", json_decoder: fn _ -> "fake" end).body
      "fake"

  """
  @doc middleware: :response
  def decode_response_body(response, opts \\ []) do
    json_decoder =
      Keyword.get_lazy(opts, :json_decoder, fn ->
        if Code.ensure_loaded?(Jason) do
          &Jason.decode!/1
        end
      end)

    csv_decoder =
      Keyword.get_lazy(opts, :csv_decoder, fn ->
        if Code.ensure_loaded?(NimbleCSV) do
          &NimbleCSV.RFC4180.parse_string(&1, skip_headers: false)
        end
      end)

    body =
      case get_header(response.headers, "content-type") do
        "application/json" <> _ when json_decoder != nil ->
          json_decoder.(response.body)

        "text/csv" <> _ when csv_decoder != nil ->
          csv_decoder.(response.body)

        _ ->
          response.body
      end

    %{response | body: body}
  end

  @doc """
  Retries a request on errors.

  This function can be used as either or both response and error middleware. It retries a
  request that resulted in:

    * response with status `5xx`

    * exception

  ## Options

    * `:retry_max_count` - maximum number of retries, defaults to: `2`

    * `:retry_delay` - sleep this number of milliseconds before making another attempt, defaults
      to `2000`

  If all attempts have failed, returns immediately without running any other middleware.

  ## Examples

  Server eventually became available:

      iex> Requests.get("http://localhost:4000", retry: true)
      # Logs:
      # 12:37:15.554 [error] Got exception
      # ** (Mint.TransportError) connection refused
      # Will retry in 2000ms, 2 attempts left
      # 12:37:17.557 [error] Got exception
      # ** (Mint.TransportError) connection refused
      # Will retry in 2000ms, 1 attempt left
      {:ok,
       %Finch.Response{
         body: "hello",
         headers: [
           {"cache-control", "max-age=0, private, must-revalidate"},
           {"content-length", "5"},
           {"date", "Mon, 22 Mar 2021 11:37:18 GMT"},
           {"server", "Cowboy"}
         ],
         status: 200
       }}

  Server keeps returning 500:

      iex> Requests.get("http://localhost:4000", retry: true)
      # Logs:
      # 12:40:09.186 [error] Got response with status 500
      # Headers: [...]
      # Will retry in 2000ms, 2 attempts left
      # 12:40:11.188 [error] Got response with status 500
      # Headers: [...]
      # Will retry in 2000ms, 1 attempt left
      {:ok,
       %Finch.Response{
         body: "oops",
         headers: [...],
         status: 500
       }}

  """
  @doc middleware: :error
  def retry(response_or_exception, opts \\ [])

  def retry(%Finch.Response{} = response, _opts) when response.status < 500 do
    response
  end

  def retry(response_or_exception, opts) do
    max_count = Keyword.get(opts, :retry_max_count, 2)
    delay = Keyword.get(opts, :retry_delay, 2000)
    throw({:__requests_retry__, response_or_exception, max_count, delay})
  end

  defp retry(
         request,
         finch,
         response_middleware,
         error_middleware,
         result,
         max_count,
         delay,
         opts,
         attempt
       ) do
    exception? = match?(%{__exception__: true}, result)

    if attempt < max_count do
      log_retry(result, exception?, attempt, max_count, delay)
      Process.sleep(delay)
      do_request(request, finch, response_middleware, error_middleware, opts, attempt + 1)
    else
      if exception? do
        {:error, result}
      else
        {:ok, result}
      end
    end
  end

  defp log_retry(result, exception?, attempt, max_count, delay) do
    attempts_left =
      case max_count - attempt do
        1 -> "1 attempt"
        n -> "#{n} attempts"
      end

    message = ["\nWill retry in #{delay}ms, ", attempts_left, " left"]

    if exception? do
      Logger.error([
        "Got exception\n",
        "** (#{inspect(result.__struct__)}) ",
        Exception.message(result),
        message
      ])
    else
      Logger.error([
        "Got response with status #{result.status}\n",
        "Headers: ",
        result.headers |> inspect(pretty: true) |> String.trim_trailing(),
        message
      ])
    end
  end

  ## Utilities

  defp get_header(headers, name) do
    Enum.find_value(headers, nil, fn {key, value} ->
      if String.downcase(key) == name do
        value
      else
        nil
      end
    end)
  end

  defp put_new_header(headers, name, value) do
    if Enum.any?(headers, fn {key, _} -> String.downcase(key) == name end) do
      headers
    else
      [{name, value} | headers]
    end
  end

  defp get_content_encoding_header(headers) do
    if value = get_header(headers, "content-encoding") do
      value
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Stream.map(&String.trim/1)
      |> Enum.reverse()
    else
      []
    end
  end

  defp prepend_if(middleware, prepend?, item) do
    if prepend?, do: [item | middleware], else: middleware
  end

  defp append_if(middleware, append?, item) do
    if append?, do: middleware ++ [item], else: middleware
  end

  defp gzip_stream(stream) do
    stream
    |> Stream.concat([:eof])
    |> Stream.transform(
      fn ->
        z = :zlib.open()
        :ok = :zlib.deflateInit(z, :default, :deflated, 16 + 15, 8, :default)
        z
      end,
      fn
        :eof, z ->
          buf = :zlib.deflate(z, [], :finish)
          {buf, z}

        data, z ->
          buf = :zlib.deflate(z, data)
          {buf, z}
      end,
      fn z ->
        :ok = :zlib.deflateEnd(z)
        :ok = :zlib.close(z)
      end
    )
  end
end
