defmodule Requests.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [{Finch, name: Requests.Finch}]
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end

defmodule Requests.Conn do
  @moduledoc """
  The connection struct.

  Fields:

    * `:request`
    * `:response`
    * `:exception`
    * `:private`

  """

  defstruct [
    :request,
    :response,
    :exception,
    :finch,
    :finch_opts,
    :response_middleware,
    :error_middleware,
    private: %{}
  ]

  @derive {Inspect, only: [:request, :response, :exception, :private]}

  def put_new_req_header(conn, name, value) do
    if Enum.any?(conn.request.headers, fn {key, _} -> String.downcase(key) == name end) do
      conn
    else
      update_in(conn.request.headers, &[{name, value} | &1])
    end
  end

  def put_resp(conn, %Finch.Response{} = response) do
    %{conn | exception: nil, response: response}
  end

  def put_exception(conn, %{__exception__: true} = exception) do
    %{conn | exception: exception, response: nil}
  end
end

defmodule Requests do
  require Logger

  alias Requests.Conn

  @vsn Mix.Project.config()[:version]

  @moduledoc """
  Yet another HTTP client.

  ## Features

    * Extensible via request, response, and error middleware

    * Automatic body encoding/decoding (via the `encode/2` and `decode/2` middleware)

    * Automatic compression/decompression (via the `compress/2` and `decompress/1` middleware)

    * Basic authentication (via the `auth/2` middleware)

    * Retries on errors (via the `retry/2` middleware)

    * Request streaming (by setting body as `{:stream, enumerable}`)

  ## Examples

      iex> Requests.get!("https://api.github.com/repos/elixir-lang/elixir").body["description"]
      "Elixir is a dynamic, functional language designed for building scalable and maintainable applications"

      iex> Requests.post!("https://httpbin.org/post", {:form, comments: "hello!"}).body["form"]
      %{"comments" => "hello!"}

  ## `Requests.Conn` and middleware

  Requests is built around a connection, the `Requests.Conn` struct, and a series of operations
  the connection can go through, the middleware.

  There are three types of middleware:

    * request middleware - executed before making the actual HTTP request to the server.
      An example is `default_headers/1`.

    * response middleware - executed after getting an HTTP response from the server. An example
      is `decompress/2`.

    * error middleware - executed after getting an error. An example is `retry/2`.

  A response middleware may call `Requests.Conn.put_exception/2` to signal that an exception
  should be returned instead of a response. In that case, no further response middleware will be
  executed and the conn will go through all error middleware instead. Similarly, an error
  middleware may call `Requests.Conn.put_resp/2` to signal that a response should be returned
  instead of an exception. In that case, no further error middleware will be executed and the
  conn will go through all response middleware instead.

  Notice that some of the built-in middleware functions take more than one argument. In order to
  use them, you have a couple options:

    * use [capture operator](`Kernel.SpecialForms.&/1`), for example:
      `&Requests.compress(&1, ["gzip"])`

    * use a `{module, function, args}` tuple, where the first argument, the `conn`, will be
      automatically prepended, for example: `{Requests, :compress, ["gzip"]}`

  ### Examples

      opts = [
        request_middleware: [
          &Requests.default_headers/1,
          fn conn -> IO.inspect(conn.request, label: :final_request) ; conn end
        ],
        response_middleware: [
          fn conn -> IO.inspect(conn.response, label: :initial_response) ; conn end,
          {Requests, :decode, []}
        ]
      ]

      Requests.get!("https://httpbin.org/json", opts)
      |> IO.inspect(label: :final_response)

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

  ## Options

    * `:headers` - list of request headers, defaults to `[]`.

    * `:request_middleware` - list of middleware to run the request through, defaults to using:

      * `normalize_request_headers/1`
      * `default_headers/1`
      * `encode/2` with `opts`
      * `auth/2` with `opts[:auth]` (if set)
      * `compress/2` with `opts[:compress]` (if set)

    * `:response_middleware` - list of middleware to run the response through, defaults to using:

      * `retry/2` with `opts` (if `retry: true` or any of the `:retry_*` options are set)
      * `decompress/2` with `opts`
      * `decode/2` with `opts`

    * `:error_middleware` - list of middleware to run the error through, defaults to using:

      * `retry/2` with `opts` (if `retry: true` or any of the `:retry_*` options are set)

    * `:finch` - name of the `Finch` pool to use, defaults to `Requests.Finch` that is started
      with the default options. See `Finch.start_link/1` for more information.

    * `:pool_timeout` - the maximum time to wait for a connection, defaults to `5000`. See
      `Finch.request/3` for more information.

    * `:receive_timeout` - the maximum time to wait for a response, defaults to `15000`. See
      `Finch.request/3` for more information.

  ## Examples

      iex> {:ok, response} = Requests.request(:get, "https://httpbin.org/json", "")
      iex> response.status
      200

      iex> {:ok, response} = Requests.request(:get, "https://httpstat.us/500", "")
      iex> response.status
      500

      iex> {:error, exception} = Requests.request(:get, "http://localhost:9999", "")
      iex> exception.reason
      :econnrefused

  """
  def request(method, url, body, opts \\ []) when is_binary(url) and is_list(opts) do
    finch = Keyword.get(opts, :finch, Requests.Finch)
    finch_opts = Keyword.take(opts, [:pool_timeout, :receive_timeout])

    request_middleware =
      Keyword.get_lazy(opts, :request_middleware, fn ->
        compress = Keyword.get(opts, :compress, false)
        auth = Keyword.get(opts, :auth, false)

        [
          &Requests.normalize_request_headers/1,
          &Requests.default_headers/1,
          {Requests, :encode, [opts]}
        ]
        |> append_if(auth, {Requests, :auth, [auth]})
        |> append_if(compress, {Requests, :compress, [compress]})
      end)

    retry_opts = Keyword.take(opts, [:retry_max_count, :retry_delay])
    retry? = Keyword.get(opts, :retry, false) or retry_opts != []

    response_middleware =
      Keyword.get_lazy(opts, :response_middleware, fn ->
        [
          {Requests, :decompress, [opts]},
          {Requests, :decode, [opts]}
        ]
        |> prepend_if(retry?, &Requests.retry(&1, retry_opts))
      end)

    error_middleware =
      Keyword.get_lazy(opts, :error_middleware, fn ->
        if retry? do
          [{Requests, :retry, [retry_opts]}]
        else
          []
        end
      end)

    headers = Keyword.get(opts, :headers, [])

    request = Finch.build(method, url, headers, body)

    conn = %Requests.Conn{
      request: request,
      finch: finch,
      finch_opts: finch_opts,
      response_middleware: response_middleware,
      error_middleware: error_middleware
    }

    conn = Enum.reduce(request_middleware, conn, &run/2)
    do_request(conn)
  end

  defp do_request(conn) do
    conn =
      case Finch.request(conn.request, conn.finch, conn.finch_opts) do
        {:ok, response} ->
          conn
          |> Conn.put_resp(response)
          |> run_response_middleware()

        {:error, exception} ->
          conn
          |> Conn.put_exception(exception)
          |> run_error_middleware()
      end

    if conn.exception do
      {:error, conn.exception}
    else
      {:ok, conn.response}
    end
  end

  defp run_response_middleware(conn) do
    Enum.reduce_while(conn.response_middleware, conn, fn runnable, acc ->
      acc = run(runnable, acc)

      if acc.exception do
        acc = run_error_middleware(acc)
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end

  defp run_error_middleware(conn) do
    Enum.reduce_while(conn.error_middleware, conn, fn runnable, acc ->
      acc = run(runnable, acc)

      if acc.exception do
        {:cont, acc}
      else
        acc = run_response_middleware(acc)
        {:halt, acc}
      end
    end)
  end

  defp run({mod, fun, args}, acc) do
    apply(mod, fun, [acc | args])
  end

  defp run(fun, acc) do
    fun.(acc)
  end

  ## Request middleware

  @doc """
  Sets request authentication.

  `auth` can be one of:

    * `{username, password}` - same as `{:basic, username, password}`

    * `{:basic, username, password}` - uses Basic HTTP authentication

  ## Examples

      iex> Requests.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"bad", "bad"}).status
      401
      iex> Requests.get!("https://httpbin.org/basic-auth/foo/bar", auth: {"foo", "bar"}).status
      200

  """
  def auth(conn, auth)

  def auth(conn, {username, password}) when is_binary(username) and is_binary(password) do
    auth(conn, {:basic, username, password})
  end

  def auth(conn, {:basic, username, password}) do
    value = Base.encode64("#{username}:#{password}")
    Conn.put_new_req_header(conn, "authorization", "Basic #{value}")
  end

  @doc """
  Normalizes request headers.

  Turns atom header names into strings, e.g.: `:user_agent` becomes `"user-agent"`.
  Non-atom names are returned as is.
  """
  @doc middleware: :request
  def normalize_request_headers(conn) do
    headers =
      for {name, value} <- conn.request.headers do
        if is_atom(name) do
          {name |> Atom.to_string() |> String.replace("_", "-"), value}
        else
          {name, value}
        end
      end

    put_in(conn.request.headers, headers)
  end

  @doc """
  Adds default request headers.

  Currently these headers are added:

    * `"user-agent"` - `"requests/#{@vsn}"`

    * `"accept-encoding"` - `"gzip"`

  """
  @doc middleware: :request
  def default_headers(conn) do
    conn
    |> Conn.put_new_req_header("user-agent", "requests/#{@vsn}")
    |> Conn.put_new_req_header("accept-encoding", "gzip")
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
  def encode(conn, opts \\ []) do
    case conn.request.body do
      {:form, data} ->
        encode(conn, URI.encode_query(data), "application/x-www-form-urlencoded")

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

        encode(conn, encoder.(data), "application/json")

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

        encode(conn, {:stream, encoder.(data)}, "text/csv")

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

        encode(conn, encoder.(data), "text/csv")

      _ ->
        conn
    end
  end

  defp encode(conn, body, content_type) do
    put_in(conn.request.body, body)
    |> Conn.put_new_req_header("content-type", content_type)
  end

  @doc """
  Compresses the request body with the given `algorithms`.

  Supported algorithms: `:gzip`, `:deflate`, and `:identity`.

  This function also sets the appropriate `content-encoding` header (unless already set.)
  """
  @doc middleware: :request
  def compress(conn, algorithms) when is_list(algorithms) do
    update_in(conn.request.body, &compress_body(&1, algorithms))
    |> Conn.put_new_req_header(
      "content-encoding",
      Enum.map_join(algorithms, ",", &Atom.to_string/1)
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

  ## Options

    * `:gzip_decoder` - used for the `"gzip"` and `"x-gzip"` values. Defaults to
      [`&:zlib.gunzip/1`](`:zlib.gunzip/1`)

    * `:deflate_decoder` - used for the `"deflate"` value. Defaults to
      [`&:zlib.unzip/1`](`:zlib.unzip/1`)

  """
  @doc middleware: :response
  def decompress(conn, opts \\ []) do
    compression_algorithms = get_content_encoding_header(conn.response.headers)
    update_in(conn.response.body, &decompress_body(&1, compression_algorithms, opts))
  end

  defp decompress_body(body, algorithms, opts) do
    Enum.reduce(algorithms, body, &decompress_with_algorithm(&1, &2, opts))
  end

  defp decompress_with_algorithm(gzip, body, opts) when gzip in ["gzip", "x-gzip"] do
    decoder =
      Keyword.get_lazy(opts, :gzip_decoder, fn ->
        &:zlib.gunzip/1
      end)

    decoder.(body)
  end

  defp decompress_with_algorithm("deflate", body, opts) do
    decoder =
      Keyword.get_lazy(opts, :deflate_decoder, fn ->
        &:zlib.unzip/1
      end)

    decoder.(body)
  end

  defp decompress_with_algorithm("identity", body, _opts) do
    body
  end

  defp decompress_with_algorithm(algorithm, _body, _opts),
    do: raise("unsupported decompression algorithm: #{inspect(algorithm)}")

  @doc """
  Decodes the response body based on the `content-type` header.

  ## Options

    * `:json_decoder` - if set, used for JSON. Defaults to [`&Jason.decode/1`](`Jason.decode/1`)

    * `:csv_decoder` - if set, used for CSV. Defaults to
      [`&NimbleCSV.RFC4180.parse_string(&1, skip_headers: false)`](`NimbleCSV.RFC4180.parse_string/2`)

    * `:gzip_decoder` - used for gzip. Defaults to [`&:zlib.gunzip/1`](`:zlib.gunzip/1`)

    * `:zip_decoder` - used for ZIP. Defaults to using `:zip.unzip/2`

  ## Examples

      iex> Requests.get!("https://httpbin.org/json").body
      %{...}

      iex> Requests.get!("https://httpbin.org/json", json_decoder: fn _ -> "fake" end).body
      "fake"

  """
  @doc middleware: :response
  def decode(conn, opts \\ []) do
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

    gzip_decoder =
      Keyword.get_lazy(opts, :gzip_decoder, fn ->
        &:zlib.gunzip/1
      end)

    zip_decoder =
      Keyword.get_lazy(opts, :zip_decoder, fn ->
        fn body ->
          {:ok, files} = :zip.unzip(body, [:memory])
          files
        end
      end)

    map = conn.response.headers |> get_header("content-type") |> parse_content_type()
    body = conn.response.body

    body =
      case map.suffix || map.subtype do
        "json" <> _ when json_decoder != nil ->
          json_decoder.(body)

        "csv" <> _ when csv_decoder != nil ->
          csv_decoder.(body)

        "gzip" ->
          gzip_decoder.(body)

        "x-gzip" ->
          gzip_decoder.(body)

        "zip" ->
          zip_decoder.(body)

        _ ->
          body
      end

    put_in(conn.response.body, body)
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

      iex> Requests.get("https://httpstat.us/500", retry: true)
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

  def retry(conn, opts)

  def retry(%{response: %{status: status}} = conn, _opts) when status < 500 do
    conn
  end

  def retry(conn, opts) do
    max_count = Keyword.get(opts, :retry_max_count, 2)
    delay = Keyword.get(opts, :retry_delay, 2000)

    conn =
      case Map.fetch(conn.private, :retry_attempt) do
        {:ok, _} ->
          conn

        :error ->
          update_in(conn.private, &Map.put(&1, :retry_attempt, 0))
      end

    retry(conn, max_count, delay)
  end

  defp retry(conn, max_count, delay) do
    attempt = conn.private.retry_attempt

    if attempt < max_count do
      log_retry(conn, attempt, max_count, delay)
      conn = update_in(conn.private.retry_attempt, &(&1 + 1))
      Process.sleep(delay)

      case Finch.request(conn.request, conn.finch, conn.finch_opts) do
        {:ok, %{status: status} = response} when status < 500 ->
          Conn.put_resp(conn, response)

        {:ok, response} ->
          conn = Conn.put_resp(conn, response)
          retry(conn, max_count, delay)

        {:error, exception} ->
          conn = Conn.put_exception(conn, exception)
          retry(conn, max_count, delay)
      end
    else
      conn
    end
  end

  defp log_retry(conn, attempt, max_count, delay) do
    attempts_left =
      case max_count - attempt do
        1 -> "1 attempt"
        n -> "#{n} attempts"
      end

    message = ["\nWill retry in #{delay}ms, ", attempts_left, " left"]

    if conn.exception do
      Logger.error([
        "Got exception\n",
        "** (#{inspect(conn.exception.__struct__)}) ",
        Exception.message(conn.exception),
        message
      ])
    else
      Logger.error([
        "Got response with status #{conn.response.status}\n",
        "Headers: ",
        conn.response.headers |> inspect(pretty: true) |> String.trim_trailing(),
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

  # https://tools.ietf.org/html/rfc6838#section-4.2
  defp parse_content_type(term) do
    with true <- is_binary(term),
         [left | _params] <- String.split(term, ";"),
         [type, subtype] = String.split(left, "/") do
      suffix =
        case String.split(subtype, "+") do
          [_] -> nil
          parts -> Enum.at(parts, -1)
        end

      %{type: type, subtype: subtype, suffix: suffix}
    else
      _ ->
        %{type: nil, subtype: nil, suffix: nil}
    end
  end
end
