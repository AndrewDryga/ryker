package main

import (
	"fmt"
	"os"

	"github.com/AndrewDryga/ryker/internal/app"
	"github.com/AndrewDryga/ryker/internal/version"
)

func main() {
	if err := app.Run(os.Args[1:], os.Stdout, os.Stderr, version.Version); err != nil {
		fmt.Fprintf(os.Stderr, "ryker: %v\n", err)
		os.Exit(1)
	}
}
