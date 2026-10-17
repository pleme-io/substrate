package main

import (
	"fmt"
	"os"

	"golang.org/x/crypto/chacha20poly1305"
)

func main() {
	aead, err := chacha20poly1305.New(make([]byte, chacha20poly1305.KeySize))
	if err != nil {
		os.Exit(1)
	}
	fmt.Println(len(aead.Seal(nil, make([]byte, aead.NonceSize()), []byte(os.Args[0]), nil)))
}
