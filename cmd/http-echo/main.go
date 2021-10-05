package main

import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"os"
	"path/filepath"
	"sort"

	"github.com/maargenton/go-cli"
	"github.com/maargenton/http-echo/pkg/buildinfo"
)

func main() {
	cli.Run(&cli.Command{
		Handler:     &httpEchoServer{},
		Description: "Http request echo server",
	})
}

type httpEchoServer struct {
	ServicePort string `opts:"-p, --service-port, name:port, default::8080" desc:"port to listen on"`
	MetricsPort string `opts:"-m, --metrics-port, name:port, default::8081" desc:"port to listen and serve metrics on"`
	Env         bool   `opts:"-e, --env"                                    desc:"include process environment in response"`
}

func (s *httpEchoServer) Version() string {
	return buildinfo.Version
}

func (s *httpEchoServer) Run() error {

	name := filepath.Base(os.Args[0])
	fmt.Printf("%v %v\n", name, buildinfo.Version)
	fmt.Printf("Starting service on %v ...\n", s.ServicePort)

	h := &http.Server{
		Addr:    s.ServicePort,
		Handler: http.HandlerFunc(s.handler()),
	}
	return h.ListenAndServe()
}

func (s *httpEchoServer) handler() func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		dump, err := httputil.DumpRequest(r, false)
		if err != nil {
			http.Error(w, fmt.Sprint(err), http.StatusInternalServerError)
			return
		}
		fmt.Fprintf(w, "\nRequest:\n")
		fmt.Fprintf(w, "--------------------\n")
		fmt.Fprintf(w, "%s", dump)
		fmt.Fprintf(w, "--------------------\n")

		fmt.Fprintf(w, "\nClient:\n")
		fmt.Fprintf(w, "--------------------\n")
		fmt.Fprintf(w, "RemoteAddr: %v\n", r.RemoteAddr)
		fmt.Fprintf(w, "--------------------\n")

		if s.Env {
			fmt.Fprintf(w, "\nEnvironment:\n")
			fmt.Fprintf(w, "--------------------\n")
			env := os.Environ()
			sort.Strings(env)
			for _, e := range env {
				fmt.Fprintf(w, "%v\n", e)
			}
			fmt.Fprintf(w, "--------------------\n")
		}
	}
}
