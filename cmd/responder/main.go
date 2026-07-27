package main

import (
	"fmt"
	"os"

	"github.com/AndrewDryga/responder/internal/app"
	"github.com/AndrewDryga/responder/internal/version"
)

func main() {
	if err := app.Run(os.Args[1:], os.Stdout, os.Stderr, version.Version); err != nil {
		fmt.Fprintf(os.Stderr, "responder: %v\n", err)
		os.Exit(1)
	}
}
