package main

import (
	"encoding/json"
	"fmt"

	"github.com/maargenton/go-cli"
	"github.com/maargenton/http-echo/pkg/buildinfo"
)

func main() {
	cli.Run(&cli.Command{
		Handler:     &httpEchoCmd{},
		Description: "Http request echo server",
	})
}

type httpEchoCmd struct {
	Port string `opts:"-p, --service-port, name:port, default:8080" desc:"port to listen on"`
	Env  bool   `opts:"-e, --env"                                   desc:"include process environment in response"`
}

func (options *httpEchoCmd) Version() string {
	return buildinfo.Version
}

func (options *httpEchoCmd) Run() error {
	d, err := json.Marshal(options)
	if err != nil {
		return err
	}
	fmt.Printf("%v\n", string(d))
	return nil
}
