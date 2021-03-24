defmodule RequestsTest do
  use ExUnit.Case, async: true
  import Plug.Conn

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "simple requests", c do
    Bypass.expect(c.bypass, "GET", "/200", fn conn ->
      send_resp(conn, 200, "ok")
    end)

    assert Requests.get!(c.url <> "/200").status == 200

    Bypass.expect(c.bypass, "GET", "/404", fn conn ->
      send_resp(conn, 404, "not found")
    end)

    assert Requests.get!(c.url <> "/404").status == 404
  end

  test "user agent", c do
    Bypass.expect(c.bypass, "GET", "/user-agent", fn conn ->
      [user_agent | _] = get_req_header(conn, "user-agent")
      send_resp(conn, 200, user_agent)
    end)

    assert "requests/" <> _ = Requests.get!(c.url <> "/user-agent").body

    assert "custom" = Requests.get!(c.url <> "/user-agent", headers: [user_agent: "custom"]).body

    assert "mint/" <> _ = Requests.get!(c.url <> "/user-agent", request_middleware: []).body
  end

  test "form-encoding", c do
    Bypass.expect(c.bypass, "POST", "/form", fn conn ->
      ["application/x-www-form-urlencoded"] = get_req_header(conn, "content-type")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:urlencoded]))

      assert conn.params == %{"x" => "y"}

      send_resp(conn, 200, "ok")
    end)

    body = %{"x" => "y"}
    assert Requests.post!(c.url <> "/form", {:form, body}).status == 200
  end

  test "encoding/decoding json", c do
    Bypass.expect(c.bypass, "POST", "/json", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = body |> Jason.decode!() |> Jason.encode_to_iodata!()

      conn
      |> put_resp_content_type("application/json; charset=utf-8")
      |> send_resp(200, body)
    end)

    body = %{"x" => 1}
    assert Requests.post!(c.url <> "/json", {:json, body}).body == body

    opts = [json_decoder: fn _ -> "fake" end]
    assert Requests.post!(c.url <> "/json", {:json, body}, opts).body == "fake"
  end

  test "encoding/decoding csv", c do
    Bypass.expect(c.bypass, "POST", "/csv", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        body
        |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
        |> NimbleCSV.RFC4180.dump_to_iodata()

      conn
      |> put_resp_content_type("text/csv; charset=utf-8")
      |> send_resp(200, body)
    end)

    body = [
      ~w(x y),
      ~w(1 1),
      ~w(2 2)
    ]

    assert Requests.post!(c.url <> "/csv", {:csv, body}).body == body
  end

  test "compress/decompress", c do
    Bypass.expect(c.bypass, "POST", "/deflate+gzip", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        body
        |> :zlib.gunzip()
        |> :zlib.unzip()
        |> :zlib.gzip()
        |> :zlib.zip()

      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip,deflate")
      |> Plug.Conn.send_resp(200, body)
    end)

    body = "foo"
    opts = [compress: [:deflate, :gzip]]
    assert Requests.post!(c.url <> "/deflate+gzip", body, opts).body == body
  end

  test "compress stream", c do
    Bypass.expect(c.bypass, "POST", "/gzip", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = :zlib.gunzip(body)
      Plug.Conn.send_resp(conn, 200, body)
    end)

    body = ["foo", "bar", "baz"]
    opts = [compress: [:gzip]]
    assert Requests.post!(c.url <> "/gzip", {:stream, body}, opts).body == "foobarbaz"
  end

  test "stream request", c do
    Bypass.expect(c.bypass, "POST", "/stream-request", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        body
        |> NimbleCSV.RFC4180.parse_string(skip_headers: false)
        |> NimbleCSV.RFC4180.dump_to_iodata()

      conn
      |> put_resp_content_type("text/csv; charset=utf-8")
      |> send_resp(200, body)
    end)

    body = [
      ~w(x y),
      ~w(1 1),
      ~w(2 2)
    ]

    assert Requests.post!(c.url <> "/stream-request", {:csv, {:stream, body}}).body == body
  end

  @tag :capture_log
  test "retry: response", c do
    pid = self()

    Bypass.expect(c.bypass, "GET", "/retry", fn conn ->
      Plug.Conn.send_resp(conn, 500, "oops")
    end)

    opts = [
      response_middleware: [
        fn error ->
          send(pid, :ping)
          error
        end,
        {Requests, :retry, [[retry_max_count: 3, retry_delay: 10]]}
      ],
      error_middleware: []
    ]

    assert {:ok, %{status: 500, body: "oops"}} = Requests.get(c.url <> "/retry", opts)
    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "retry: error", c do
    pid = self()
    Bypass.down(c.bypass)

    opts = [
      response_middleware: [],
      error_middleware: [
        fn error ->
          send(pid, :ping)
          error
        end,
        {Requests, :retry, [[retry_max_count: 3, retry_delay: 10]]}
      ]
    ]

    assert {:error, %{reason: :econnrefused}} = Requests.get(c.url <> "/retry", opts)
    assert_received :ping
    assert_received :ping
    assert_received :ping
    assert_received :ping
    refute_received _
  end

  @tag :capture_log
  test "retry: when eventually successful", c do
    {:ok, _} = Agent.start_link(fn -> 0 end, name: :counter)

    Bypass.expect(c.bypass, "GET", "/retry", fn conn ->
      if Agent.get_and_update(:counter, &{&1, &1 + 1}) < 2 do
        Plug.Conn.send_resp(conn, 500, "oops")
      else
        Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    opts = [
      retry_max_count: 3,
      retry_delay: 10
    ]

    assert {:ok, %{status: 200, body: "ok"}} = Requests.get(c.url <> "/retry", opts)
    assert Agent.get(:counter, & &1) == 3
  end

  @tag :capture_log
  test "response middleware returning error", c do
    Bypass.expect(c.bypass, "GET", "/error", fn conn ->
      Plug.Conn.send_resp(conn, 500, "oops")
    end)

    opts = [
      response_middleware: [
        fn response ->
          RuntimeError.exception(response.body)
        end
      ],
      error_middleware: []
    ]

    assert {:error, %{message: "oops"}} = Requests.get(c.url <> "/error", opts)
  end

  test "error middleware returning response", c do
    :ok = Bypass.down(c.bypass)

    opts = [
      response_middleware: [],
      error_middleware: [
        fn exception ->
          body = Exception.message(exception)
          %Finch.Response{status: 200, body: body}
        end
      ]
    ]

    assert {:ok, %Finch.Response{status: 200}} = Requests.get(c.url <> "/error", opts)
  end

  test "errors", c do
    :ok = Bypass.down(c.bypass)
    opts = [response_middleware: [], error_middleware: []]
    assert {:error, exception} = Requests.get(c.url <> "/200", opts)
    assert exception == %Mint.TransportError{reason: :econnrefused}
  end

  @tag :skip
  test "httpbin" do
    opts = [
      request_middleware: [
        &Requests.default_headers/1,
        &IO.inspect(&1, label: :final_request)
      ],
      response_middleware: [
        {IO, :inspect, [[label: :initial_response]]},
        {Requests, :decode, []}
      ]
    ]

    Requests.get!("https://httpbin.org/json", opts)
    |> IO.inspect(label: :final_response)
  end
end
