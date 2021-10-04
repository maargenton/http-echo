# http-echo

Simple http debug server that responds with a full dump of the incoming request
to help setup and debug reverse proxies and ingress configurations.

## Usage

To start a local server
```
go run ./cmd/http-echo --port 8080 --env
```

To run from a prebuilt docker image
```
docker run ...
```

To deploy to a kubernetes cluster
```
kubectl apply -f deployments/k8s
```

To access the running server:
```
curl -v http://localhost:8080/foo/bar?payload=1KB&delay=1s
```

The server responds to any sub-path and support a few query parameters:

- `delay=<duration>` : delay the response by the specified duration
- `payload=<size><unit>` : add random payload with the requested size to the
  response.
- `status=<code>` : Specify status code to respond with, instead of 200
- `ws` : promote the connection t oa websocket echo server.
